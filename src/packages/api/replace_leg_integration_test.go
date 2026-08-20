package main

// replace_leg end to end, on the shape that produced it: "replace Copenhagen
// with Belgrade" on a multi-city spine.
//
// The assertion that matters most here is the NEGATIVE one — every city other
// than the swapped one keeps byte-identical leg dates, night counts and date
// source. That is the regression the whole piece of work started from, so
// TestWholeTripRewriteMovesOtherLegsDates runs the SAME swap through the path
// the tooling used to route it to (update_itinerary_section scope 'trip', with
// the model re-authoring every day number) and pins that it MOVES three legs.
// It is the failing baseline; without it the positive test is a claim about
// nothing.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// legFacts is a leg reduced to what a traveler would notice moving.
type legFacts struct {
	Key    string
	Label  string
	Start  string
	End    string
	Nights int
	Source string
	Zero   bool
}

func (l legFacts) String() string {
	return fmt.Sprintf("%s %s→%s (%d nights, %s, zero=%v)", l.Key, l.Start, l.End, l.Nights, l.Source, l.Zero)
}

// tripLegFacts reads the trip's CURRENT rendered legs through computeTripLegs —
// the one derivation the page draws, the `legs` payload serializes and the
// tool's own result quotes. Never a second opinion computed for the test.
func tripLegFacts(t *testing.T, owner, tripID uuid.UUID) map[string]legFacts {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	trip, err := q.GetEditableTripByID(ctx, store.GetEditableTripByIDParams{ID: tripID, UserID: owner})
	if err != nil {
		t.Fatalf("load trip: %v", err)
	}
	items, err := q.GetItineraryItemsByTrip(ctx, tripID)
	if err != nil {
		t.Fatalf("load items: %v", err)
	}
	stays, err := q.ListAccommodationsByTrip(ctx, tripID)
	if err != nil {
		t.Fatalf("load stays: %v", err)
	}
	out := map[string]legFacts{}
	for _, leg := range computeTripLegs(trip, items, stays) {
		f := legFacts{Key: leg.Key, Label: leg.Label, Source: leg.DateSource, Zero: leg.ZeroNight}
		if leg.Start != nil && leg.End != nil {
			f.Start = leg.Start.Format(dateLayout)
			f.End = leg.End.Format(dateLayout)
			f.Nights = nightsBetween(*leg.Start, *leg.End)
		}
		out[leg.Key] = f
	}
	return out
}

// seedSwapTrip builds the four-city spine the swap runs against, plus the
// attachments a real trip carries: a confirmed stay and two confirmed transport
// segments for the city being replaced, and the NEIGHBOUR's equivalents, which
// must come through untouched.
//
//	Amsterdam days 1-4   Copenhagen days 4-7
//	Oslo      days 7-10  Stockholm  days 10-12   (trip runs to day 13, the day home)
func seedSwapTrip(t *testing.T, owner uuid.UUID) store.Trip {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	trip := createTestTrip(t, owner, 0)
	if _, err := q.UpdateTrip(ctx, store.UpdateTripParams{
		ID: trip.ID, UserID: owner,
		StartDate: validDate("2026-06-01"), EndDate: validDate("2026-06-13"),
	}); err != nil {
		t.Fatalf("seed trip dates: %v", err)
	}
	for i, s := range []rlSeed{
		{name: "Rijksmuseum", city: "Amsterdam", day: 1, timeOfDay: "afternoon"},
		{name: "Jordaan walk", city: "Amsterdam", day: 4, timeOfDay: "morning"},
		{name: "Nyhavn", city: "Copenhagen", day: 4, timeOfDay: "evening"},
		{name: "Torvehallerne", city: "Copenhagen", day: 7, timeOfDay: "morning"},
		{name: "Opera House", city: "Oslo", day: 7, timeOfDay: "evening"},
		{name: "Vigeland Park", city: "Oslo", day: 10, timeOfDay: "morning"},
		{name: "Vasa Museum", city: "Stockholm", day: 10, timeOfDay: "evening"},
		{name: "Gamla Stan", city: "Stockholm", day: 12, timeOfDay: "morning"},
	} {
		city, tod, day := s.city, s.timeOfDay, int32(s.day)
		if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
			TripID: trip.ID, Position: int32(i), Name: s.name, City: &city,
			TimeOfDay: &tod, Day: &day,
			Latitude: 55 + float64(i)*0.01, Longitude: 12 + float64(i)*0.01,
		}); err != nil {
			t.Fatalf("seed item %s: %v", s.name, err)
		}
	}

	cphAddr := "Nyhavn 12, Copenhagen, Denmark"
	if _, err := q.CreateAccommodation(ctx, store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Hotel Nyhavn 71", Address: &cphAddr,
		CheckIn: validDate("2026-06-04"), CheckOut: validDate("2026-06-07"),
	}); err != nil {
		t.Fatalf("seed CPH stay: %v", err)
	}
	// Address-less, agent-added shape — the reason stayMatchesHub has a NAME
	// fallback at all. It is the neighbour's, and must survive the swap.
	if _, err := q.CreateAccommodation(ctx, store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Stay in Oslo",
		CheckIn: validDate("2026-06-07"), CheckOut: validDate("2026-06-10"),
	}); err != nil {
		t.Fatalf("seed Oslo stay: %v", err)
	}
	seg := func(mode, from, to, depart string) {
		t.Helper()
		o, d := from, to
		if _, err := q.CreateSegment(ctx, store.CreateSegmentParams{
			TripID: trip.ID, Mode: mode, Origin: &o, Destination: &d,
			DepartDate: validDate(depart), ArriveDate: validDate(depart),
		}); err != nil {
			t.Fatalf("seed segment %s->%s: %v", from, to, err)
		}
	}
	seg("flight", "Amsterdam", "Copenhagen", "2026-06-04")
	seg("flight", "Copenhagen", "Oslo", "2026-06-07")
	seg("train", "Oslo", "Stockholm", "2026-06-10") // the neighbour's: must survive
	return trip
}

// seedSwapTodos adds the checklist rows a real trip carries, one of each kind
// the clearing has to tell apart.
func seedSwapTodos(t *testing.T, tripID uuid.UUID) {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	auto := func(kind, key, title string, pos int32) store.BookingTodo {
		t.Helper()
		row, err := q.UpsertBookingTodo(ctx, store.UpsertBookingTodoParams{
			TripID: tripID, Kind: kind, TodoKey: key, Title: title, Position: pos,
		})
		if err != nil {
			t.Fatalf("seed todo %s: %v", key, err)
		}
		return row
	}
	auto("stay", "stay:copenhagen", "Book a stay in Copenhagen", 0)
	booked := auto("transport", "transport:amsterdam>>copenhagen", "Amsterdam → Copenhagen", 1)
	auto("stay", "stay:oslo", "Book a stay in Oslo", 2)
	auto("transport", "transport:oslo>>stockholm", "Oslo → Stockholm", 3)
	if _, err := q.SetBookingTodoBooked(ctx, store.SetBookingTodoBookedParams{
		ID: booked.ID, TripID: tripID, Booked: true,
	}); err != nil {
		t.Fatalf("mark todo booked: %v", err)
	}
	// A hand-added row that merely MENTIONS the city. Its key speaks no derived
	// grammar, so it belongs to no leg and must be left alone — an under-clear
	// the traveler can fix in two taps beats deleting something they wrote.
	if _, err := q.CreateBookingTodo(ctx, store.CreateBookingTodoParams{
		TripID: tripID, Kind: "other", TodoKey: "custom-harbour-tour",
		Title: "Book the Copenhagen harbour tour", Position: 4,
	}); err != nil {
		t.Fatalf("seed manual todo: %v", err)
	}
}

func swapSession(t *testing.T, owner uuid.UUID, trip store.Trip) (*planSession, *httptest.ResponseRecorder) {
	t.Helper()
	s, rec := testPlanSession(true, owner)
	s.boundTripID = &trip.ID
	s.boundTripOwnerID = owner
	return s, rec
}

const belgradePayload = `{"city":"Copenhagen","new_city":"Belgrade","places":[` +
	`{"name":"Kalemegdan Fortress","latitude":44.823,"longitude":20.450,"city":"Belgrade"},` +
	`{"name":"Skadarlija","latitude":44.818,"longitude":20.462,"city":"Belgrade"}]}`

// THE acceptance test. One city out, one city in, and every other city's dates,
// night counts and date source byte-identical.
func TestReplaceLegLeavesOtherCitiesUntouched(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "replaceleg@example.com")
	trip := seedSwapTrip(t, owner.ID)

	before := tripLegFacts(t, owner.ID, trip.ID)
	s, rec := swapSession(t, owner.ID, trip)
	msg, isErr := runReplaceLegTool(s, json.RawMessage(belgradePayload))
	if isErr {
		t.Fatalf("replace_leg errored: %s", msg)
	}
	after := tripLegFacts(t, owner.ID, trip.ID)

	// The traveler's page only redraws on this event, so a swap that skipped it
	// would leave them looking at the old city while the tool says otherwise.
	if !strings.Contains(rec.Body.String(), "trip_updated") {
		t.Fatal("the swap did not emit trip_updated")
	}
	if !s.itineraryEmitted {
		t.Fatal("the swap did not mark the itinerary emitted (suggest_replies would still fire)")
	}

	if len(after) != len(before) {
		t.Fatalf("leg count %d -> %d\nbefore %v\nafter %v", len(before), len(after), before, after)
	}
	// Belgrade occupies exactly ONE leg — no "Belgrade#2", which is what a
	// fragmenting rewrite produces.
	if _, dup := after["Belgrade#2"]; dup {
		t.Fatalf("Belgrade fragmented into two runs: %v", after)
	}
	bel, ok := after["Belgrade"]
	if !ok {
		t.Fatalf("no Belgrade leg after the swap: %v", after)
	}
	if _, still := after["Copenhagen"]; still {
		t.Fatalf("Copenhagen survived the swap: %v", after)
	}
	// The swapped leg inherits the old city's span exactly — both ends are
	// shared with its neighbours, so this IS the neighbours' dates.
	cph := before["Copenhagen"]
	if bel.Start != cph.Start || bel.End != cph.End || bel.Nights != cph.Nights {
		t.Fatalf("Belgrade %s did not inherit Copenhagen's span %s", bel, cph)
	}
	// And the negative assertion, the one this whole piece of work is about.
	for key, was := range before {
		if key == "Copenhagen" {
			continue
		}
		now, ok := after[key]
		if !ok {
			t.Fatalf("leg %s disappeared: %v", key, after)
		}
		if now != was {
			t.Fatalf("leg %s moved: was %s, now %s", key, was, now)
		}
	}

	// The result has to make that checkable from the tool output alone — the
	// model verifies what it reports against what the traveler asked for.
	for _, want := range []string{
		"Copenhagen is now Belgrade",
		"trip days 4-7",
		"The page now renders these city legs:",
		"- Amsterdam: 2026-06-01 to 2026-06-04",
		"- Belgrade: 2026-06-04 to 2026-06-07",
		"- Oslo: 2026-06-07 to 2026-06-10",
		"- Stockholm: 2026-06-10 to 2026-06-13",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("result missing %q:\n%s", want, msg)
		}
	}
	// A leg that lost the place fixing its departure date renders zero nights
	// and the summary shouts about it. Nothing here should.
	if strings.Contains(msg, "renders ZERO nights") || strings.Contains(msg, "dates GUESSED") {
		t.Fatalf("the swap damaged a leg:\n%s", msg)
	}
}

// The failing baseline for the test above: the SAME swap through the path the
// tooling routed it to before replace_leg existed — scope 'trip' with the model
// re-authoring every day number, which is what update_itinerary_section's own
// description asks for. Three legs move. Nothing here is a bug being fixed in
// this lane (guarding that scope is a separate one); it is here so the positive
// assertion above is provably about something.
func TestWholeTripRewriteMovesOtherLegsDates(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "wholetrip@example.com")
	trip := seedSwapTrip(t, owner.ID)

	before := tripLegFacts(t, owner.ID, trip.ID)
	s, _ := swapSession(t, owner.ID, trip)
	// A plausible recompute: consecutive day numbers per city, which quietly
	// drops the convention that the move day carries the SAME number in both.
	msg, isErr := runUpdateItinerarySectionTool(s, json.RawMessage(
		`{"scope":"trip","items":[`+
			`{"name":"Rijksmuseum","latitude":55.00,"longitude":12.00,"day":1,"city":"Amsterdam","time_of_day":"afternoon"},`+
			`{"name":"Jordaan walk","latitude":55.01,"longitude":12.01,"day":2,"city":"Amsterdam","time_of_day":"morning"},`+
			`{"name":"Kalemegdan Fortress","latitude":44.823,"longitude":20.450,"day":3,"city":"Belgrade","time_of_day":"evening"},`+
			`{"name":"Skadarlija","latitude":44.818,"longitude":20.462,"day":4,"city":"Belgrade","time_of_day":"morning"},`+
			`{"name":"Opera House","latitude":55.04,"longitude":12.04,"day":5,"city":"Oslo","time_of_day":"evening"},`+
			`{"name":"Vigeland Park","latitude":55.05,"longitude":12.05,"day":6,"city":"Oslo","time_of_day":"morning"},`+
			`{"name":"Vasa Museum","latitude":55.06,"longitude":12.06,"day":7,"city":"Stockholm","time_of_day":"evening"},`+
			`{"name":"Gamla Stan","latitude":55.07,"longitude":12.07,"day":8,"city":"Stockholm","time_of_day":"morning"}]}`))
	if isErr {
		t.Fatalf("scope-trip rewrite errored: %s", msg)
	}
	after := tripLegFacts(t, owner.ID, trip.ID)

	var moved []string
	for key, was := range before {
		if key == "Copenhagen" {
			continue
		}
		if now := after[key]; now != was {
			moved = append(moved, fmt.Sprintf("%s: %s -> %s", key, was, now))
		}
	}
	if len(moved) == 0 {
		t.Fatalf("the pre-replace_leg path left every leg alone — this baseline no longer demonstrates anything, so the positive test above may be vacuous.\nbefore %v\nafter %v", before, after)
	}
	t.Logf("legs a whole-trip rewrite moved (this is the regression replace_leg removes):\n  %s", strings.Join(moved, "\n  "))
}

// Clearing, both directions in one test: the replaced city's attachments go and
// are NAMED, and the neighbour's identically-shaped ones do not.
func TestReplaceLegClearsOnlyTheReplacedCity(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "replacelegclear@example.com")
	trip := seedSwapTrip(t, owner.ID)
	seedSwapTodos(t, trip.ID)

	s, _ := swapSession(t, owner.ID, trip)
	msg, isErr := runReplaceLegTool(s, json.RawMessage(belgradePayload))
	if isErr {
		t.Fatalf("replace_leg errored: %s", msg)
	}

	ctx := context.Background()
	q := store.New(dbPool)
	stays, err := q.ListAccommodationsByTrip(ctx, trip.ID)
	if err != nil {
		t.Fatalf("load stays: %v", err)
	}
	var stayNames []string
	for _, a := range stays {
		stayNames = append(stayNames, a.Name)
	}
	if fmt.Sprint(stayNames) != fmt.Sprint([]string{"Stay in Oslo"}) {
		t.Fatalf("stays after swap = %v, want only the Oslo stay", stayNames)
	}

	segs, err := q.ListSegmentsByTrip(ctx, trip.ID)
	if err != nil {
		t.Fatalf("load segments: %v", err)
	}
	if len(segs) != 1 || strPtrVal(segs[0].Origin) != "Oslo" {
		var got []string
		for _, sg := range segs {
			got = append(got, segmentLabel(sg))
		}
		t.Fatalf("segments after swap = %v, want only Oslo → Stockholm", got)
	}

	todos, err := q.ListBookingTodosByTrip(ctx, trip.ID)
	if err != nil {
		t.Fatalf("load todos: %v", err)
	}
	byKey := map[string]store.BookingTodo{}
	for _, td := range todos {
		byKey[td.TodoKey] = td
	}
	if _, still := byKey["stay:copenhagen"]; still {
		t.Fatal("the Copenhagen stay row survived the swap")
	}
	// A BOOKED row is traveler state, not garbage: demoted to a manual row
	// under "Other bookings", never deleted (the 00064/00065 policy, reached by
	// calling the same statements the checklist sync calls).
	flight, ok := byKey["transport:amsterdam>>copenhagen"]
	if !ok {
		t.Fatal("a BOOKED checklist row was deleted rather than demoted")
	}
	if flight.Auto || !flight.Booked {
		t.Fatalf("demoted row auto=%v booked=%v, want auto=false booked=true", flight.Auto, flight.Booked)
	}
	// The neighbour's rows, and a hand-added row that merely names the city,
	// are untouched.
	for _, key := range []string{"stay:oslo", "transport:oslo>>stockholm", "custom-harbour-tour"} {
		if _, ok := byKey[key]; !ok {
			t.Fatalf("%s was swept up by the clear; the trip's rows are %v", key, byKey)
		}
	}
	if !byKey["stay:oslo"].Auto {
		t.Fatal("the neighbour's auto row was demoted")
	}

	// Reporting removals is not politeness — a silently dropped reservation is
	// a defect. Every removed thing is named, and the BOOKED one is called out
	// as still existing with the provider.
	for _, want := range []string{
		`Removed with Copenhagen:`,
		`the stay "Hotel Nyhavn 71"`,
		`"Amsterdam → Copenhagen (flight)"`,
		`"Copenhagen → Oslo (flight)"`,
		`the checklist row(s) "Book a stay in Copenhagen"`,
		`no longer tracking the itinerary`,
		`"Amsterdam → Copenhagen"`,
		"offer to find replacements",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("result missing %q:\n%s", want, msg)
		}
	}
	// Scoped to the CLEARING prose: the post-state echo below it legitimately
	// lists "Oslo → Stockholm" as a checklist row the traveler still has, so a
	// whole-message Contains would pass or fail for the wrong reason.
	removalProse, _, _ := strings.Cut(msg, "The page now renders these city legs:")
	for _, neighbour := range []string{"Stay in Oslo", "Oslo → Stockholm", "harbour tour", "Book a stay in Oslo"} {
		if strings.Contains(removalProse, neighbour) {
			t.Fatalf("the result claimed a neighbour's booking (%s) was removed:\n%s", neighbour, removalProse)
		}
	}
}

// A stay marked BOOKED is a real reservation. Detaching it from the plan does
// not cancel it, and the result has to say so in words the model will relay.
func TestReplaceLegNamesABookedStayItDetached(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "replacelegbooked@example.com")
	trip := seedSwapTrip(t, owner.ID)
	ctx := context.Background()
	q := store.New(dbPool)
	stays, err := q.ListAccommodationsByTrip(ctx, trip.ID)
	if err != nil {
		t.Fatalf("load stays: %v", err)
	}
	booked := true
	for _, a := range stays {
		if !strings.Contains(a.Name, "Nyhavn") {
			continue
		}
		if _, err := q.UpdateAccommodation(ctx, store.UpdateAccommodationParams{
			ID: a.ID, TripID: trip.ID, Booked: &booked,
		}); err != nil {
			t.Fatalf("mark stay booked: %v", err)
		}
	}

	s, _ := swapSession(t, owner.ID, trip)
	msg, isErr := runReplaceLegTool(s, json.RawMessage(belgradePayload))
	if isErr {
		t.Fatalf("replace_leg errored: %s", msg)
	}
	for _, want := range []string{"was marked BOOKED", "cancel or change it themselves", `"Hotel Nyhavn 71"`} {
		if !strings.Contains(msg, want) {
			t.Fatalf("result missing %q:\n%s", want, msg)
		}
	}
}

// Re-placing a city with ITSELF keeps its stay, its transport and its checklist
// rows — they are still valid, and clearing them would be destruction with no
// question behind it.
func TestReplaceLegSameCityKeepsAttachments(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "replacelegsame@example.com")
	trip := seedSwapTrip(t, owner.ID)
	seedSwapTodos(t, trip.ID)

	before := tripLegFacts(t, owner.ID, trip.ID)
	s, _ := swapSession(t, owner.ID, trip)
	msg, isErr := runReplaceLegTool(s, json.RawMessage(
		`{"city":"Copenhagen","places":[`+
			`{"name":"Nyhavn","latitude":55.68,"longitude":12.59,"city":"Copenhagen"},`+
			`{"name":"Tivoli Gardens","latitude":55.67,"longitude":12.56,"city":"Copenhagen"},`+
			`{"name":"Torvehallerne","latitude":55.68,"longitude":12.57,"city":"Copenhagen"}]}`))
	if isErr {
		t.Fatalf("replace_leg errored: %s", msg)
	}
	if strings.Contains(msg, "Removed with") {
		t.Fatalf("a same-city refill cleared attachments:\n%s", msg)
	}
	ctx := context.Background()
	q := store.New(dbPool)
	stays, err := q.ListAccommodationsByTrip(ctx, trip.ID)
	if err != nil || len(stays) != 2 {
		t.Fatalf("stays after refill = %d (err %v), want both kept", len(stays), err)
	}
	todos, err := q.ListBookingTodosByTrip(ctx, trip.ID)
	if err != nil || len(todos) != 5 {
		t.Fatalf("todos after refill = %d (err %v), want all 5 kept", len(todos), err)
	}
	after := tripLegFacts(t, owner.ID, trip.ID)
	for key, was := range before {
		if now := after[key]; now != was {
			t.Fatalf("leg %s moved on a same-city refill: was %s, now %s", key, was, now)
		}
	}
}

// A refusal must leave the trip byte-identical: spliceLeg runs before the
// delete, so the model retries against the state it read.
func TestReplaceLegWritesNothingOnRefusal(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "replacelegmiss@example.com")
	trip := seedSwapTrip(t, owner.ID)
	seedSwapTodos(t, trip.ID)

	before := tripLegFacts(t, owner.ID, trip.ID)
	ctx := context.Background()
	q := store.New(dbPool)
	itemsBefore, err := q.GetItineraryItemsByTrip(ctx, trip.ID)
	if err != nil {
		t.Fatalf("load items: %v", err)
	}
	tripBefore, err := q.GetEditableTripByID(ctx, store.GetEditableTripByIDParams{ID: trip.ID, UserID: owner.ID})
	if err != nil {
		t.Fatalf("load trip: %v", err)
	}

	s, _ := swapSession(t, owner.ID, trip)
	msg, isErr := runReplaceLegTool(s, json.RawMessage(
		`{"city":"Bergen","new_city":"Belgrade","places":[`+
			`{"name":"Kalemegdan Fortress","latitude":44.823,"longitude":20.450,"city":"Belgrade"},`+
			`{"name":"Skadarlija","latitude":44.818,"longitude":20.462,"city":"Belgrade"}]}`))
	if !isErr {
		t.Fatalf("an unknown city was accepted: %s", msg)
	}
	for _, want := range []string{`no leg for "Bergen"`, "Amsterdam (trip days 1-4)", "Copenhagen (trip days 4-7)"} {
		if !strings.Contains(msg, want) {
			t.Fatalf("error missing %q:\n%s", want, msg)
		}
	}

	itemsAfter, err := q.GetItineraryItemsByTrip(ctx, trip.ID)
	if err != nil {
		t.Fatalf("reload items: %v", err)
	}
	if len(itemsAfter) != len(itemsBefore) {
		t.Fatalf("items %d -> %d on a refused call", len(itemsBefore), len(itemsAfter))
	}
	for i := range itemsAfter {
		if itemsAfter[i].ID != itemsBefore[i].ID {
			t.Fatalf("item %d was rewritten on a refused call", i)
		}
	}
	stays, _ := q.ListAccommodationsByTrip(ctx, trip.ID)
	segs, _ := q.ListSegmentsByTrip(ctx, trip.ID)
	todos, _ := q.ListBookingTodosByTrip(ctx, trip.ID)
	if len(stays) != 2 || len(segs) != 3 || len(todos) != 5 {
		t.Fatalf("a refused call detached something: %d stays, %d segments, %d todos", len(stays), len(segs), len(todos))
	}
	// Not even updated_at: nothing was committed at all.
	tripAfter, err := q.GetEditableTripByID(ctx, store.GetEditableTripByIDParams{ID: trip.ID, UserID: owner.ID})
	if err != nil {
		t.Fatalf("reload trip: %v", err)
	}
	if !tripAfter.UpdatedAt.Equal(tripBefore.UpdatedAt) {
		t.Fatal("a refused call touched the trip")
	}
	if after := tripLegFacts(t, owner.ID, trip.ID); fmt.Sprint(after) != fmt.Sprint(before) {
		t.Fatalf("legs changed on a refused call:\nbefore %v\nafter %v", before, after)
	}
	if s.itineraryEmitted {
		t.Fatal("a refused call marked the itinerary as emitted")
	}
}

// The tool is gated on a bound trip; without one it has to say so rather than
// reach for a trip it was never given.
func TestReplaceLegNeedsABoundTrip(t *testing.T) {
	s, _ := testPlanSession(true, uuid.New())
	msg, isErr := runReplaceLegTool(s, json.RawMessage(belgradePayload))
	if !isErr || !strings.Contains(msg, "not bound to a saved trip") {
		t.Fatalf("unbound replace_leg = %q (err=%v)", msg, isErr)
	}
}
