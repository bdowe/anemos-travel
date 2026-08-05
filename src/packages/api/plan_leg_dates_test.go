package main

// set_leg_dates (specs/set-leg-dates): one city leg's dates move, the rest of
// the trip doesn't — except the PREVIOUS leg's end, which extends to meet a
// later start (the trip screen draws a leg from its neighbor's end, so an
// unmoved boundary makes the change invisible). Unit tables cover the pure
// run-splitting and endpoint-anchored delta math; the DB tests assert the
// headline dogfood scenario (Panama City -> LA -> EWR, "change LA to Sep
// 24-27"), the placeholder end-carrier shape, honest zero-change results
// (no commit, no trip_updated), the shrink clamp, the auto-draft skip,
// overlap narrate-only, validation atomicity, collaborator authz, and
// lineage resolution on a later turn.

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

func TestComputeLegDateChange(t *testing.T) {
	newEnd := func(s string) *time.Time { d := civilDate(s); return &d }
	cases := []struct {
		name           string
		tripStart      string
		oldStart       string
		oldEnd         string
		newStart       string
		newEnd         *time.Time
		wantStartDelta int
		wantEndDelta   int
		wantStartIdx   int
		wantEndIdx     int
		wantErr        error
	}{
		// The dogfood case: leg length changes, so the deltas differ (+4/+3).
		{"grow-shift differing deltas", "2026-09-15", "2026-09-20", "2026-09-24", "2026-09-24", newEnd("2026-09-27"), 4, 3, 10, 13, nil},
		{"omitted end preserves length", "2026-09-15", "2026-09-20", "2026-09-24", "2026-09-24", nil, 4, 4, 10, 14, nil},
		{"shift earlier is negative", "2026-09-15", "2026-09-20", "2026-09-24", "2026-09-18", nil, -2, -2, 4, 8, nil},
		{"leg to trip's first day", "2026-09-15", "2026-09-20", "2026-09-24", "2026-09-15", newEnd("2026-09-18"), -5, -6, 1, 4, nil},
		{"end before start errors", "2026-09-15", "2026-09-20", "2026-09-24", "2026-09-24", newEnd("2026-09-23"), 0, 0, 0, 0, errLegEndBeforeStart},
		{"start before trip errors", "2026-09-15", "2026-09-20", "2026-09-24", "2026-09-14", nil, 0, 0, 0, 0, errLegBeforeTripStart},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ch, err := computeLegDateChange(civilDate(tc.tripStart), civilDate(tc.oldStart), civilDate(tc.oldEnd), civilDate(tc.newStart), tc.newEnd)
			if tc.wantErr != nil {
				if err != tc.wantErr {
					t.Fatalf("err = %v, want %v", err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if ch.startDelta != tc.wantStartDelta || ch.endDelta != tc.wantEndDelta {
				t.Fatalf("deltas = %d/%d, want %d/%d", ch.startDelta, ch.endDelta, tc.wantStartDelta, tc.wantEndDelta)
			}
			if ch.newStartIdx != tc.wantStartIdx || ch.newEndIdx != tc.wantEndIdx {
				t.Fatalf("indices = %d/%d, want %d/%d", ch.newStartIdx, ch.newEndIdx, tc.wantStartIdx, tc.wantEndIdx)
			}
		})
	}
}

// legItem builds an in-memory item for the pure run-splitting tests.
func legItem(pos int, city, dayTripFrom string, day int) store.ItineraryItem {
	it := store.ItineraryItem{Position: int32(pos), Name: fmt.Sprintf("p%d", pos)}
	if city != "" {
		it.City = &city
	}
	if dayTripFrom != "" {
		it.DayTripFrom = &dayTripFrom
	}
	if day > 0 {
		d := int32(day)
		it.Day = &d
	}
	return it
}

func TestLegRunsAndMatching(t *testing.T) {
	items := []store.ItineraryItem{
		legItem(0, "", "", 1), // hubless start adopts the first named hub
		legItem(1, "Panama City", "", 1),
		legItem(2, "Panama City", "", 2),
		legItem(3, "Taboga Island", "Panama City", 3), // day trip rides its hub
		legItem(4, "Los Angeles", "", 4),
		legItem(5, "", "", 0), // hubless, undated: adopts current run
		legItem(6, "Los Angeles", "", 5),
		legItem(7, "Panama City", "", 6), // revisit: a separate third run
	}
	runs := legRuns(items)
	if len(runs) != 3 {
		t.Fatalf("runs = %d (%+v), want 3", len(runs), runs)
	}
	if runs[0].hub != "Panama City" || runs[0].minDay != 1 || runs[0].maxDay != 3 || len(runs[0].items) != 4 {
		t.Fatalf("run 0 = %s days %d-%d (%d items), want Panama City 1-3 (4 items)", runs[0].hub, runs[0].minDay, runs[0].maxDay, len(runs[0].items))
	}
	if runs[1].hub != "Los Angeles" || runs[1].minDay != 4 || runs[1].maxDay != 5 || len(runs[1].items) != 3 {
		t.Fatalf("run 1 = %s days %d-%d (%d items), want Los Angeles 4-5 (3 items)", runs[1].hub, runs[1].minDay, runs[1].maxDay, len(runs[1].items))
	}
	if runs[2].hub != "Panama City" || runs[2].minDay != 6 {
		t.Fatalf("run 2 = %s day %d, want the Panama City revisit on 6", runs[2].hub, runs[2].minDay)
	}

	if got := matchLegRuns(runs, "los angeles"); len(got) != 1 || got[0] != 1 {
		t.Fatalf("matchLegRuns(los angeles) = %v, want [1]", got)
	}
	// A revisited city matches both of its runs — the handler errors on that.
	if got := matchLegRuns(runs, "Panama City"); len(got) != 2 {
		t.Fatalf("matchLegRuns(Panama City) = %v, want two runs", got)
	}
	// Fuzzy fallback only when nothing matches exactly.
	if got := matchLegRuns(runs, "Angeles"); len(got) != 1 || got[0] != 1 {
		t.Fatalf("matchLegRuns(Angeles) = %v, want fuzzy [1]", got)
	}
	if got := matchLegRuns(runs, "Tokyo"); len(got) != 0 {
		t.Fatalf("matchLegRuns(Tokyo) = %v, want none", got)
	}

	// An all-undated run has no calendar footprint and is unmatchable.
	undated := legRuns([]store.ItineraryItem{legItem(0, "Lima", "", 0)})
	if got := matchLegRuns(undated, "Lima"); len(got) != 0 {
		t.Fatalf("matchLegRuns on undated run = %v, want none", got)
	}
}

// seedMultiCityTrip builds the dogfood trip: Sep 15-24, Panama City days 1-6
// then Los Angeles days 6-9, confirmed stays for both (PC by address, LA by
// name), the two boundary flights, and one auto draft stay for LA that must
// never move or confirm.
func seedMultiCityTrip(t *testing.T, trip store.Trip, owner uuid.UUID) {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	if _, err := q.UpdateTrip(ctx, store.UpdateTripParams{
		ID: trip.ID, UserID: owner,
		StartDate: validDate("2026-09-15"), EndDate: validDate("2026-09-24"),
	}); err != nil {
		t.Fatalf("seed trip dates: %v", err)
	}
	seed := func(pos int, name, city string, day int) {
		t.Helper()
		d := int32(day)
		if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
			TripID: trip.ID, Position: int32(pos), Name: name, City: &city, Day: &d,
			Latitude: 8.98 + float64(pos)*0.01, Longitude: -79.52,
		}); err != nil {
			t.Fatalf("seed item %s: %v", name, err)
		}
	}
	for i := 0; i < 6; i++ {
		seed(i, fmt.Sprintf("PC Spot %d", i+1), "Panama City", i+1)
	}
	for i := 0; i < 4; i++ {
		seed(6+i, fmt.Sprintf("LA Spot %d", i+1), "Los Angeles", 6+i)
	}
	pcAddr := "Casco Viejo, Panama City, Panama"
	if _, err := q.CreateAccommodation(ctx, store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Hotel Casco Viejo", Address: &pcAddr,
		CheckIn: validDate("2026-09-15"), CheckOut: validDate("2026-09-20"),
	}); err != nil {
		t.Fatalf("seed PC stay: %v", err)
	}
	if _, err := q.CreateAccommodation(ctx, store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Stay in Los Angeles",
		CheckIn: validDate("2026-09-20"), CheckOut: validDate("2026-09-24"),
	}); err != nil {
		t.Fatalf("seed LA stay: %v", err)
	}
	draftKey := "stay:los angeles"
	if _, err := q.UpsertDraftAccommodation(ctx, store.UpsertDraftAccommodationParams{
		TripID: trip.ID, Name: "Suggested stay in Los Angeles", AutoKey: &draftKey,
		CheckIn: validDate("2026-09-20"), CheckOut: validDate("2026-09-24"),
	}); err != nil {
		t.Fatalf("seed LA draft: %v", err)
	}
	pc, la, ewr := "Panama City", "Los Angeles", "Newark"
	if _, err := q.CreateSegment(ctx, store.CreateSegmentParams{
		TripID: trip.ID, Mode: "flight", Origin: &pc, Destination: &la,
		DepartDate: validDate("2026-09-20"), ArriveDate: validDate("2026-09-20"),
	}); err != nil {
		t.Fatalf("seed arrival segment: %v", err)
	}
	if _, err := q.CreateSegment(ctx, store.CreateSegmentParams{
		TripID: trip.ID, Mode: "flight", Origin: &la, Destination: &ewr,
		DepartDate: validDate("2026-09-24"),
	}); err != nil {
		t.Fatalf("seed departure segment: %v", err)
	}
}

func legDays(t *testing.T, tripID uuid.UUID, city string) []int {
	t.Helper()
	rows, err := dbPool.Query(context.Background(),
		`SELECT day FROM itinerary_items WHERE trip_id = $1 AND city = $2 ORDER BY position`, tripID, city)
	if err != nil {
		t.Fatalf("legDays query: %v", err)
	}
	defer rows.Close()
	var days []int
	for rows.Next() {
		var d int
		if err := rows.Scan(&d); err != nil {
			t.Fatalf("legDays scan: %v", err)
		}
		days = append(days, d)
	}
	return days
}

func daysEqual(a []int, b ...int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// The headline dogfood scenario: "change LA to Sep 24-27" moves the LA items,
// stay, and boundary flights (by DIFFERENT deltas), extends the trip end,
// drags Panama City's stay check-out to the new arrival (boundary extension),
// and leaves PC's items and the auto draft untouched.
func TestPlanSetLegDatesMovesOneLeg(t *testing.T) {
	resetDB(t)
	fa := newFakeAnthropic(t,
		toolTurn("set_leg_dates", `{"city":"Los Angeles","start_date":"2026-09-24","end_date":"2026-09-27"}`),
		textTurn("LA is now Sep 24-27; that opens a gap after Panama City — want me to extend that stay?"))

	user, token := createTestUser(t, "legmover@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedMultiCityTrip(t, trip, user.ID)

	rec := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		TripID:   trip.ID.String(),
		Messages: []PlanChatMessage{{Role: "user", Content: "change the dates for LA to sep 24-27"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}
	updated := eventsOfType(events, "trip_updated")
	if len(updated) != 1 || eventData(updated[0])["trip_id"] != trip.ID.String() {
		t.Fatalf("trip_updated events = %v, want exactly one for trip %s", updated, trip.ID)
	}

	// SSE tool_result events carry only the tool name; the result text rides
	// the follow-up model request. The gap narration must be deterministic.
	reqs := fa.requestBodies()
	if len(reqs) < 2 {
		t.Fatalf("model requests = %d, want >= 2 (tool round-trip)", len(reqs))
	}
	followUp := string(reqs[1])
	for _, want := range []string{
		"Los Angeles is now 2026-09-24 to 2026-09-27",
		"Trip end extended to 2026-09-27",
		"Panama City now ends 2026-09-24 (was 2026-09-20)",
		"check-out moved to match this leg's start",
		"ORIGINAL dates",
	} {
		if !strings.Contains(followUp, want) {
			t.Fatalf("tool_result round-trip missing %q:\n%s", want, followUp)
		}
	}
	// The boundary extension closed the gap, so no uncovered-nights NOTE.
	if strings.Contains(followUp, "uncovered night(s)") {
		t.Fatalf("gap NOTE should be suppressed after the boundary extension:\n%s", followUp)
	}

	if got := legDays(t, trip.ID, "Los Angeles"); !daysEqual(got, 10, 11, 12, 13) {
		t.Fatalf("LA days = %v, want [10 11 12 13]", got)
	}
	if got := legDays(t, trip.ID, "Panama City"); !daysEqual(got, 1, 2, 3, 4, 5, 6) {
		t.Fatalf("PC days = %v, want [1 2 3 4 5 6] untouched", got)
	}
	if start, end := tripDates(t, trip.ID); start != "2026-09-15" || end != "2026-09-27" {
		t.Fatalf("trip dates = %s/%s, want 2026-09-15/2026-09-27", start, end)
	}
	if in, out := scanDates(t, `SELECT check_in, check_out FROM accommodations WHERE trip_id = $1 AND name = $2`, trip.ID, "Stay in Los Angeles"); in != "2026-09-24" || out != "2026-09-27" {
		t.Fatalf("LA stay = %s/%s, want 2026-09-24/2026-09-27", in, out)
	}
	// Boundary extension: PC's check-out follows the new LA arrival; the
	// check-in stays put.
	if in, out := scanDates(t, `SELECT check_in, check_out FROM accommodations WHERE trip_id = $1 AND name = $2`, trip.ID, "Hotel Casco Viejo"); in != "2026-09-15" || out != "2026-09-24" {
		t.Fatalf("PC stay = %s/%s, want 2026-09-15/2026-09-24 (check-out extended)", in, out)
	}
	// The auto draft neither moved nor got confirmed.
	var draftIn *time.Time
	var draftAuto bool
	if err := dbPool.QueryRow(context.Background(),
		`SELECT check_in, auto FROM accommodations WHERE trip_id = $1 AND name = $2`,
		trip.ID, "Suggested stay in Los Angeles").Scan(&draftIn, &draftAuto); err != nil {
		t.Fatalf("draft query: %v", err)
	}
	if !draftAuto || draftIn == nil || draftIn.Format(dateLayout) != "2026-09-20" {
		t.Fatalf("draft = check_in %v auto %v, want untouched 2026-09-20/true", draftIn, draftAuto)
	}
	// Arrival rides the leg start (+4), departure rides the leg end (+3).
	if dep, _ := scanDates(t, `SELECT depart_date, arrive_date FROM trip_segments WHERE trip_id = $1 AND destination = $2`, trip.ID, "Los Angeles"); dep != "2026-09-24" {
		t.Fatalf("arrival segment departs %s, want 2026-09-24", dep)
	}
	if dep, _ := scanDates(t, `SELECT depart_date, arrive_date FROM trip_segments WHERE trip_id = $1 AND origin = $2`, trip.ID, "Los Angeles"); dep != "2026-09-27" {
		t.Fatalf("departure segment departs %s, want 2026-09-27", dep)
	}

	waitForEventCount(t, user.ID, "agent_leg_dates_set", 1)
}

// seedPlaceholderTwoCityTrip is the shape import + placeholder itineraries
// produce (and the real dogfood trip that exposed the invisible-move bug):
// one city-filler item per city whose single day encodes the leg's DEPARTURE,
// no stays or segments at all.
func seedPlaceholderTwoCityTrip(t *testing.T, trip store.Trip, owner uuid.UUID) {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	if _, err := q.UpdateTrip(ctx, store.UpdateTripParams{
		ID: trip.ID, UserID: owner,
		StartDate: validDate("2026-09-15"), EndDate: validDate("2026-09-27"),
	}); err != nil {
		t.Fatalf("seed trip dates: %v", err)
	}
	for i, leg := range []struct {
		city string
		day  int
	}{{"Panama City", 6}, {"Los Angeles", 10}} {
		d := int32(leg.day)
		city := leg.city
		if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
			TripID: trip.ID, Position: int32(i), Name: leg.city,
			City: &city, Day: &d, Latitude: 8.98, Longitude: -79.52,
		}); err != nil {
			t.Fatalf("seed item %s: %v", leg.city, err)
		}
	}
}

// A single-item placeholder leg is an END-carrier: its one day is the
// departure day the screen renders, so "LA Sep 24-27" must land that item on
// Sep 27 and drag Panama City's departure day to Sep 24 — the exact ask that
// used to "succeed" while the page never changed.
func TestPlanSetLegDatesPlaceholderEndCarrier(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "placeholder@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedPlaceholderTwoCityTrip(t, trip, user.ID)

	s, rec := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"Los Angeles","start_date":"2026-09-24","end_date":"2026-09-27"}`))
	if isErr {
		t.Fatalf("placeholder move errored: %s", msg)
	}
	for _, want := range []string{
		"Los Angeles is now 2026-09-24 to 2026-09-27",
		"Panama City now ends 2026-09-24 (was 2026-09-20)",
		"last itinerary day moved to match this leg's start",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("result missing %q: %s", want, msg)
		}
	}
	if !strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("placeholder move did not emit trip_updated")
	}
	if got := legDays(t, trip.ID, "Los Angeles"); !daysEqual(got, 13) {
		t.Fatalf("LA day = %v, want [13] (Sep 27, the departure day)", got)
	}
	if got := legDays(t, trip.ID, "Panama City"); !daysEqual(got, 10) {
		t.Fatalf("PC day = %v, want [10] (Sep 24, the new boundary)", got)
	}
	if start, end := tripDates(t, trip.ID); start != "2026-09-15" || end != "2026-09-27" {
		t.Fatalf("trip dates = %s/%s, want unchanged 2026-09-15/2026-09-27", start, end)
	}
}

// Re-asking for a state the trip already holds must commit nothing, emit NO
// trip_updated (no phantom "Trip updated" chip), and report the ACTUAL saved
// state — never echo the requested range as if it were achieved.
func TestPlanSetLegDatesNoOpIsHonest(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "noophonest@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedPlaceholderTwoCityTrip(t, trip, user.ID)

	s1, _ := testPlanSession(true, user.ID)
	s1.boundTripID = &trip.ID
	if msg, isErr := runSetLegDatesTool(s1, []byte(`{"city":"Los Angeles","start_date":"2026-09-24","end_date":"2026-09-27"}`)); isErr {
		t.Fatalf("first move errored: %s", msg)
	}
	var touchedAt time.Time
	if err := dbPool.QueryRow(context.Background(),
		`SELECT updated_at FROM trips WHERE id = $1`, trip.ID).Scan(&touchedAt); err != nil {
		t.Fatalf("updated_at query: %v", err)
	}

	s2, rec2 := testPlanSession(true, user.ID)
	s2.boundTripID = &trip.ID
	msg, isErr := runSetLegDatesTool(s2, []byte(`{"city":"Los Angeles","start_date":"2026-09-24","end_date":"2026-09-27"}`))
	if isErr {
		t.Fatalf("no-op errored: %s", msg)
	}
	for _, want := range []string{
		"No saved rows changed",
		"itinerary items sit on 2026-09-27 to 2026-09-27 (trip days 13-13)",
		"the previous leg (Panama City) ends 2026-09-24",
		"shows this leg as 2026-09-24 to 2026-09-27",
		"was NOT refreshed",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("no-op result missing %q: %s", want, msg)
		}
	}
	if strings.Contains(msg, "already spans") {
		t.Fatalf("no-op result echoes the request as achieved: %s", msg)
	}
	if strings.Contains(rec2.Body.String(), "trip_updated") {
		t.Fatal("no-op emitted trip_updated")
	}
	if s2.tripID != nil || s2.itineraryEmitted {
		t.Fatal("no-op set session itinerary state")
	}
	if got := legDays(t, trip.ID, "Los Angeles"); !daysEqual(got, 13) {
		t.Fatalf("LA day = %v, want [13] unchanged", got)
	}
	var after time.Time
	if err := dbPool.QueryRow(context.Background(),
		`SELECT updated_at FROM trips WHERE id = $1`, trip.ID).Scan(&after); err != nil {
		t.Fatalf("updated_at requery: %v", err)
	}
	if !after.Equal(touchedAt) {
		t.Fatalf("no-op touched the trip: %v -> %v", touchedAt, after)
	}
}

// Moving a leg EARLIER than the previous leg's end never shrinks the
// neighbor — the overlap is narrated for the agent to raise instead.
func TestPlanSetLegDatesOverlapNarratesOnly(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "overlap@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedMultiCityTrip(t, trip, user.ID)

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"Los Angeles","start_date":"2026-09-18","end_date":"2026-09-20"}`))
	if isErr {
		t.Fatalf("overlap move errored: %s", msg)
	}
	if !strings.Contains(msg, "overlaps this leg's start 2026-09-18 by 2 night(s)") {
		t.Fatalf("result missing the overlap NOTE: %s", msg)
	}
	if in, out := scanDates(t, `SELECT check_in, check_out FROM accommodations WHERE trip_id = $1 AND name = $2`, trip.ID, "Hotel Casco Viejo"); in != "2026-09-15" || out != "2026-09-20" {
		t.Fatalf("PC stay = %s/%s, want untouched (neighbors never shrink)", in, out)
	}
}

// Shrinking a leg folds trailing items onto its new last day and says so.
func TestPlanSetLegDatesShrinkClampsItems(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "shrinker@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedMultiCityTrip(t, trip, user.ID)

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"Los Angeles","start_date":"2026-09-24","end_date":"2026-09-25"}`))
	if isErr {
		t.Fatalf("shrink errored: %s", msg)
	}
	// Day 9 is the end-carrier (an anchor move, not a fold), so only day 8
	// counts as clamped.
	for _, want := range []string{"folded onto 2026-09-25", "1 item(s)"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("result missing %q: %s", want, msg)
		}
	}
	if got := legDays(t, trip.ID, "Los Angeles"); !daysEqual(got, 10, 11, 11, 11) {
		t.Fatalf("LA days = %v, want [10 11 11 11]", got)
	}
	if in, out := scanDates(t, `SELECT check_in, check_out FROM accommodations WHERE trip_id = $1 AND name = $2`, trip.ID, "Stay in Los Angeles"); in != "2026-09-24" || out != "2026-09-25" {
		t.Fatalf("LA stay = %s/%s, want 2026-09-24/2026-09-25", in, out)
	}
	// The later start still drags PC's boundary along, shrink or not.
	if in, out := scanDates(t, `SELECT check_in, check_out FROM accommodations WHERE trip_id = $1 AND name = $2`, trip.ID, "Hotel Casco Viejo"); in != "2026-09-15" || out != "2026-09-24" {
		t.Fatalf("PC stay = %s/%s, want 2026-09-15/2026-09-24", in, out)
	}
}

// Invalid input is a tool error and the transaction leaves nothing behind.
func TestPlanSetLegDatesValidationLeavesDBUntouched(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "leginvalid@example.com")
	trip := createTestTrip(t, user.ID, 0)
	seedMultiCityTrip(t, trip, user.ID)

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	cases := []struct {
		name, input, want string
	}{
		{"end before start", `{"city":"Los Angeles","start_date":"2026-09-24","end_date":"2026-09-23"}`, "end_date must not be before start_date"},
		{"unknown city lists legs", `{"city":"Tokyo","start_date":"2026-09-24"}`, "The legs are: Panama City (2026-09-15 to 2026-09-20), Los Angeles (2026-09-20 to 2026-09-24)"},
		{"start before trip", `{"city":"Los Angeles","start_date":"2026-09-10"}`, "before the trip begins on 2026-09-15"},
		{"missing city", `{"start_date":"2026-09-24"}`, "city is required"},
		{"bad start date", `{"city":"Los Angeles","start_date":"Sep 24"}`, "start_date is required and must be YYYY-MM-DD"},
	}
	for _, tc := range cases {
		msg, isErr := runSetLegDatesTool(s, []byte(tc.input))
		if !isErr || !strings.Contains(msg, tc.want) {
			t.Fatalf("%s = %q (err=%v), want error containing %q", tc.name, msg, isErr, tc.want)
		}
	}
	if got := legDays(t, trip.ID, "Los Angeles"); !daysEqual(got, 6, 7, 8, 9) {
		t.Fatalf("LA days changed on invalid input: %v", got)
	}
	if start, end := tripDates(t, trip.ID); start != "2026-09-15" || end != "2026-09-24" {
		t.Fatalf("trip dates changed on invalid input: %s/%s", start, end)
	}
	if in, _ := scanDates(t, `SELECT check_in, check_out FROM accommodations WHERE trip_id = $1 AND name = $2`, trip.ID, "Stay in Los Angeles"); in != "2026-09-20" {
		t.Fatalf("LA stay moved on invalid input: %s", in)
	}
}

// A city the itinerary visits twice is ambiguous — honest error, nothing moves.
func TestPlanSetLegDatesAmbiguousCity(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "revisit@example.com")
	trip := createTestTrip(t, user.ID, 0)
	ctx := context.Background()
	q := store.New(dbPool)
	if _, err := q.UpdateTrip(ctx, store.UpdateTripParams{
		ID: trip.ID, UserID: user.ID,
		StartDate: validDate("2026-09-15"), EndDate: validDate("2026-09-19"),
	}); err != nil {
		t.Fatalf("seed trip dates: %v", err)
	}
	for i, leg := range []struct {
		city string
		day  int
	}{{"Athens", 1}, {"Santorini", 2}, {"Athens", 4}} {
		d := int32(leg.day)
		city := leg.city
		if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
			TripID: trip.ID, Position: int32(i), Name: fmt.Sprintf("%s stop", leg.city),
			City: &city, Day: &d, Latitude: 37.97, Longitude: 23.72,
		}); err != nil {
			t.Fatalf("seed item: %v", err)
		}
	}

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"Athens","start_date":"2026-09-16"}`))
	if !isErr || !strings.Contains(msg, "more than once") {
		t.Fatalf("ambiguous = %q (err=%v), want a more-than-once error", msg, isErr)
	}
	if got := legDays(t, trip.ID, "Athens"); !daysEqual(got, 1, 4) {
		t.Fatalf("Athens days changed on ambiguous input: %v", got)
	}
}

// Unit-level guards that need no seeded leg.
func TestSetLegDatesToolGuards(t *testing.T) {
	// Anonymous session.
	s, _ := testPlanSession(false, uuid.Nil)
	if msg, isErr := runSetLegDatesTool(s, []byte(`{"city":"LA","start_date":"2026-09-24"}`)); !isErr || !strings.Contains(msg, "signed in") {
		t.Fatalf("anonymous = %q (err=%v)", msg, isErr)
	}

	resetDB(t)
	user, _ := createTestUser(t, "legnotrip@example.com")

	// Authed but no trip anywhere in the session.
	s2, _ := testPlanSession(true, user.ID)
	if msg, isErr := runSetLegDatesTool(s2, []byte(`{"city":"LA","start_date":"2026-09-24"}`)); !isErr || !strings.Contains(msg, "create_itinerary") {
		t.Fatalf("no-trip = %q (err=%v)", msg, isErr)
	}

	// A dateless trip has no calendar to place a leg on.
	trip := createTestTrip(t, user.ID, 2)
	s3, _ := testPlanSession(true, user.ID)
	s3.boundTripID = &trip.ID
	if msg, isErr := runSetLegDatesTool(s3, []byte(`{"city":"LA","start_date":"2026-09-24"}`)); !isErr || !strings.Contains(msg, "set_trip_dates") {
		t.Fatalf("dateless trip = %q (err=%v), want a set_trip_dates redirect", msg, isErr)
	}
}

// An editor collaborator refining the owner's trip may move a leg; the
// analytics event marks the actor as a collaborator.
func TestPlanSetLegDatesEditorCollaborator(t *testing.T) {
	resetDB(t)
	newFakeAnthropic(t,
		toolTurn("set_leg_dates", `{"city":"Los Angeles","start_date":"2026-09-24","end_date":"2026-09-27"}`),
		textTurn("Moved LA for you both."))

	owner, _ := createTestUser(t, "legowner@example.com")
	editor, editorToken := createTestUser(t, "legeditor@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	seedMultiCityTrip(t, trip, owner.ID)
	if _, err := store.New(dbPool).CreateTripCollaborator(context.Background(), store.CreateTripCollaboratorParams{
		ChatID: *trip.ChatID, OwnerID: owner.ID, UserID: editor.ID, Role: "editor",
	}); err != nil {
		t.Fatalf("seed collaborator: %v", err)
	}

	rec := doJSON(t, "POST", "/api/v1/plan", editorToken, PlanRequest{
		TripID:   trip.ID.String(),
		Messages: []PlanChatMessage{{Role: "user", Content: "change LA to sep 24-27"}},
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d, want 200", rec.Code)
	}
	events := planEvents(t, rec.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}
	if got := legDays(t, trip.ID, "Los Angeles"); !daysEqual(got, 10, 11, 12, 13) {
		t.Fatalf("LA days = %v, want [10 11 12 13]", got)
	}
	waitForEventCount(t, editor.ID, "agent_leg_dates_set", 1)
}

// Fresh chat, NEXT turn: a later /plan request in the same conversation has
// no bound trip and no s.tripID — the chat lineage resolves the target.
func TestPlanSetLegDatesFreshChatNextTurnLineage(t *testing.T) {
	resetDB(t)
	// The fake keys turn selection off tool_result count, so a second /plan
	// request would replay turn 0 — script each request with its own fake.
	newFakeAnthropic(t,
		toolTurn("create_itinerary", `{"title":"Greek Hop","start_date":"2026-06-01","locations":[{"name":"Acropolis","latitude":37.97,"longitude":23.72,"day":1,"city":"Athens"},{"name":"Oia","latitude":36.46,"longitude":25.37,"day":2,"city":"Santorini"},{"name":"Red Beach","latitude":36.35,"longitude":25.39,"day":3,"city":"Santorini"}]}`),
		textTurn("Saved!"))

	user, token := createTestUser(t, "leglineage@example.com")
	first := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID:   "chat-leg-lineage",
		Messages: []PlanChatMessage{{Role: "user", Content: "athens then santorini june 1"}},
	})
	if first.Code != http.StatusOK {
		t.Fatalf("first /plan = %d, want 200", first.Code)
	}

	fa2 := newFakeAnthropic(t,
		toolTurn("set_leg_dates", `{"city":"Santorini","start_date":"2026-06-03","end_date":"2026-06-04"}`),
		textTurn("Santorini moved."))
	second := doJSON(t, "POST", "/api/v1/plan", token, PlanRequest{
		ChatID: "chat-leg-lineage",
		Messages: []PlanChatMessage{
			{Role: "user", Content: "athens then santorini june 1"},
			{Role: "assistant", Content: "Saved!"},
			{Role: "user", Content: "push santorini a day later"},
		},
	})
	if second.Code != http.StatusOK {
		t.Fatalf("second /plan = %d, want 200", second.Code)
	}
	events := planEvents(t, second.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}
	updated := eventsOfType(events, "trip_updated")
	if len(updated) != 1 {
		t.Fatalf("trip_updated events = %d, want 1", len(updated))
	}
	tid, err := uuid.Parse(eventData(updated[0])["trip_id"].(string))
	if err != nil {
		t.Fatalf("trip_updated trip_id: %v", err)
	}
	if got := legDays(t, tid, "Santorini"); !daysEqual(got, 3, 4) {
		t.Fatalf("Santorini days = %v, want [3 4]", got)
	}
	// Athens has no confirmed stay, so the boundary extension moves its last
	// itinerary day to Santorini's new start — and the result says so.
	if got := legDays(t, tid, "Athens"); !daysEqual(got, 3) {
		t.Fatalf("Athens days = %v, want [3] (boundary extension)", got)
	}
	if reqs := fa2.requestBodies(); len(reqs) < 2 || !strings.Contains(string(reqs[1]), "Athens now ends 2026-06-03 (was 2026-06-01)") {
		t.Fatalf("missing Athens boundary narration in follow-up request")
	}
	if _, end := tripDates(t, tid); end != "2026-06-04" {
		t.Fatalf("trip end = %s, want extended to 2026-06-04", end)
	}
	var trips int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM trips WHERE user_id = $1`, user.ID).Scan(&trips); err != nil {
		t.Fatalf("trips count: %v", err)
	}
	if trips != 1 {
		t.Fatalf("trips = %d, want 1 (set_leg_dates must never create a version)", trips)
	}
}
