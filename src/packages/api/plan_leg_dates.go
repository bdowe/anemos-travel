package main

// set_leg_dates (specs/set-leg-dates): the /plan agent's way to change WHEN
// one city leg of a saved trip happens without moving the rest of the trip.
// set_trip_dates shifts everything by one delta; a leg move is endpoint-
// anchored instead — the start and end can shift by different amounts (LA
// Sep 20-24 -> Sep 24-27 is +4 on check-in, +3 on check-out). One transaction
// renumbers the leg's item days END-anchored (the old last day is the
// departure day the trip screen renders), moves its matched confirmed stays
// and boundary transport, and extends the trip's end date when the leg now
// runs past it. The PREVIOUS leg's end extends to meet a later start in the
// same transaction (decided 2026-08-05 — the screen draws a leg from the
// neighbor's end, so an unmoved boundary makes the change invisible); an
// earlier start (overlap) and the NEXT leg still only narrate — including a
// SQUEEZE note when the new end consumes all the next leg's nights, which
// the agent resolves by chaining further set_leg_dates calls. The FIRST
// dated leg's visible start is the trip's start date (anchored, mirroring
// the client's _locationGroupRanges clamp) so a first-leg start change
// steers to set_trip_dates. A zero-change call commits nothing and reports
// actual saved state — never the requested range, and no trip_updated SSE.
// Gated authedOnly (per-conversation stable, prompt-cache safe); target-trip
// resolution reuses resolveDateShiftTrip.

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	anthropic "github.com/anthropics/anthropic-sdk-go"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

var setLegDatesTool = anthropic.ToolParam{
	Name: "set_leg_dates",
	Description: anthropic.String("Change the dates of ONE city's leg within the traveler's saved trip — 'make LA Sep 24 to 27', 'arrive in Rome a day later' — without moving the rest of the trip. " +
		"It moves that city's itinerary days, its stay's check-in/check-out, and the transport into and out of that city, extending the trip's end date when the new leg runs past it. " +
		"Moving a leg later also extends the PREVIOUS city's end to meet the new start (the result says so); other cities do not move — the result reports any remaining gap or overlap with neighboring legs, so relay every change it describes to the traveler and offer to fix those legs too. " +
		"Omit end_date to keep the leg the same length. " +
		"When the WHOLE trip moves, use set_trip_dates instead. " +
		"Only the saved plan changes: anything already booked with a real provider keeps its original dates, so remind the traveler to re-check those bookings."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"city": map[string]any{
				"type":        "string",
				"description": "The city whose leg is changing, exactly as it appears in the itinerary, e.g. 'Los Angeles'",
			},
			"start_date": map[string]any{
				"type":        "string",
				"description": "The leg's new first day in that city as YYYY-MM-DD",
			},
			"end_date": map[string]any{
				"type":        "string",
				"description": "Optional new last day (the departure day) as YYYY-MM-DD; omit to keep the leg's current length. Must not be before start_date.",
			},
		},
		Required: []string{"city", "start_date"},
	},
}

// legRun is one contiguous run of itinerary items sharing a hub city, in
// position order. minDay/maxDay span the run's dated items (0 when none —
// such a run has no calendar footprint and can't be moved).
type legRun struct {
	hub    string
	items  []store.ItineraryItem
	minDay int
	maxDay int
}

// legRuns walks items in position order and splits on hub change (itemHub:
// day_trip_from else city, so day trips ride their hub). An empty hub never
// splits — it adopts the current run, and a run started by hubless items
// adopts the first named hub it meets, same as checkLodging's night runs.
func legRuns(items []store.ItineraryItem) []legRun {
	var runs []legRun
	for _, it := range items {
		hub := itemHub(it)
		if len(runs) == 0 {
			runs = append(runs, legRun{hub: hub})
		} else if cur := &runs[len(runs)-1]; hub != "" && cur.hub != "" && !strings.EqualFold(hub, cur.hub) {
			runs = append(runs, legRun{hub: hub})
		} else if cur.hub == "" {
			cur.hub = hub
		}
		cur := &runs[len(runs)-1]
		cur.items = append(cur.items, it)
		if it.Day != nil {
			d := int(*it.Day)
			if cur.minDay == 0 || d < cur.minDay {
				cur.minDay = d
			}
			if d > cur.maxDay {
				cur.maxDay = d
			}
		}
	}
	return runs
}

// matchLegRuns returns the dated runs whose hub matches the requested city —
// exact (case-insensitive) matches win outright; only when there are none
// does the lenient fuzzyMatch pass run, so "Los Angeles" never accidentally
// pulls in "East Los Angeles" when an exact leg exists.
func matchLegRuns(runs []legRun, city string) []int {
	var exact, fuzzy []int
	cityLower := strings.ToLower(strings.TrimSpace(city))
	for i, r := range runs {
		if r.minDay < 1 {
			continue
		}
		if strings.EqualFold(strings.TrimSpace(r.hub), strings.TrimSpace(city)) {
			exact = append(exact, i)
		} else if fuzzyMatch(strings.ToLower(r.hub), cityLower) {
			fuzzy = append(fuzzy, i)
		}
	}
	if len(exact) > 0 {
		return exact
	}
	return fuzzy
}

// stayMatchesHub mirrors the Flutter trip screen's stay-to-city matching
// (address fuzzy match), with the name as a fallback for agent-added stays
// that carry no address ("Stay in Los Angeles").
func stayMatchesHub(a store.Accommodation, hubLower string) bool {
	if addr := strings.ToLower(strings.TrimSpace(strPtrVal(a.Address))); addr != "" && fuzzyMatch(addr, hubLower) {
		return true
	}
	name := strings.ToLower(strings.TrimSpace(a.Name))
	return name != "" && fuzzyMatch(name, hubLower)
}

// matchedConfirmedStay finds the stay that anchors a leg's displayed span:
// the first confirmed (non-auto) hub-matched stay with both dates. Nil means
// the leg's span comes from its item days — whoever moves a leg boundary must
// edit the same source that produced the span, so this is shared by
// legDisplayRange and the previous-boundary extension.
func matchedConfirmedStay(run legRun, stays []store.Accommodation) *store.Accommodation {
	hubLower := strings.ToLower(run.hub)
	for i, a := range stays {
		if a.Auto || !a.CheckIn.Valid || !a.CheckOut.Valid {
			continue
		}
		if stayMatchesHub(a, hubLower) {
			return &stays[i]
		}
	}
	return nil
}

// legDisplayRange resolves the calendar span a leg currently occupies, with
// the same precedence the trip screen renders: the first confirmed matched
// stay with both dates, else the dated items' day range off the trip anchor.
func legDisplayRange(run legRun, stays []store.Accommodation, tripStart time.Time) (time.Time, time.Time) {
	if a := matchedConfirmedStay(run, stays); a != nil {
		return a.CheckIn.Time, a.CheckOut.Time
	}
	return tripStart.AddDate(0, 0, run.minDay-1), tripStart.AddDate(0, 0, run.maxDay-1)
}

// firstDatedRunIdx finds the lowest-index movable run — the leg whose arrival
// IS the trip's start date. -1 when none. Same dated-run criteria as
// prevDatedRunIdx/nextDatedRunIdx.
func firstDatedRunIdx(runs []legRun) int {
	for i, r := range runs {
		if r.minDay >= 1 && r.hub != "" {
			return i
		}
	}
	return -1
}

// anchoredLegDisplayRange is legDisplayRange plus the first-leg anchor: the
// first dated run's visible start pulls back to the trip start when its span
// is item-derived — the traveler is in the first city from the trip's first
// day, so a single late item must not read as a late arrival. A confirmed
// stay still wins, mirroring the client's _locationGroupRanges clamp
// (trip_detail_screen.dart). Item days are >= 1, so the anchor only ever
// pulls the start back, never forward.
func anchoredLegDisplayRange(runs []legRun, i int, stays []store.Accommodation, tripStart time.Time) (time.Time, time.Time) {
	s, e := legDisplayRange(runs[i], stays, tripStart)
	if i == firstDatedRunIdx(runs) && matchedConfirmedStay(runs[i], stays) == nil && tripStart.Before(s) {
		s = tripStart
	}
	return s, e
}

// legDateChange is the pure outcome of a leg move: the resolved new span,
// the endpoint-anchored day deltas, and the leg's new 1-based trip-day
// indices.
type legDateChange struct {
	newStart, newEnd       time.Time
	startDelta, endDelta   int
	newStartIdx, newEndIdx int
}

var (
	errLegEndBeforeStart  = fmt.Errorf("end_date must not be before start_date")
	errLegBeforeTripStart = fmt.Errorf("leg start precedes trip start")
)

// computeLegDateChange resolves the new leg span and both deltas. A nil
// newEnd preserves the leg's current length. All values are civil dates as
// UTC midnights, so hour math is exact — no DST.
func computeLegDateChange(tripStart, oldLegStart, oldLegEnd, newStart time.Time, newEnd *time.Time) (legDateChange, error) {
	end := newStart.Add(oldLegEnd.Sub(oldLegStart))
	if newEnd != nil {
		end = *newEnd
	}
	if end.Before(newStart) {
		return legDateChange{}, errLegEndBeforeStart
	}
	startIdx := int(newStart.Sub(tripStart).Hours()/24) + 1
	if startIdx < 1 {
		return legDateChange{}, errLegBeforeTripStart
	}
	return legDateChange{
		newStart:    newStart,
		newEnd:      end,
		startDelta:  int(newStart.Sub(oldLegStart).Hours() / 24),
		endDelta:    int(end.Sub(oldLegEnd).Hours() / 24),
		newStartIdx: startIdx,
		newEndIdx:   int(end.Sub(tripStart).Hours()/24) + 1,
	}, nil
}

func legRangeText(start, end time.Time) string {
	return start.Format(dateLayout) + " to " + end.Format(dateLayout)
}

// legsSummary lists the trip's movable legs with their current spans — the
// honest error payload when the requested city doesn't resolve.
func legsSummary(runs []legRun, stays []store.Accommodation, tripStart time.Time) string {
	var parts []string
	for i, r := range runs {
		if r.minDay < 1 || r.hub == "" {
			continue
		}
		s, e := anchoredLegDisplayRange(runs, i, stays, tripStart)
		parts = append(parts, fmt.Sprintf("%s (%s)", r.hub, legRangeText(s, e)))
	}
	return strings.Join(parts, ", ")
}

func runSetLegDatesTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		City      string `json:"city"`
		StartDate string `json:"start_date"`
		EndDate   string `json:"end_date"`
	}
	json.Unmarshal(input, &in)

	if !s.authed {
		return "The traveler isn't signed in, so there's no saved trip to change. Give the advice in your reply instead.", true
	}
	if dbPool == nil {
		return "Saved trips are unavailable right now (persistence offline).", true
	}

	city := strings.TrimSpace(in.City)
	if city == "" {
		return "city is required — the city whose leg is changing, as it appears in the itinerary.", true
	}
	start, err := parseDateParam(&in.StartDate)
	if err != nil || !start.Valid {
		return "start_date is required and must be YYYY-MM-DD.", true
	}
	var newEnd *time.Time
	if endParam, err := parseDateParam(&in.EndDate); err != nil {
		return "end_date must be YYYY-MM-DD.", true
	} else if endParam.Valid {
		newEnd = &endParam.Time
	}

	tid, msg, failed := resolveDateShiftTrip(s)
	if failed {
		return msg, true
	}

	tx, err := dbPool.Begin(s.ctx)
	if err != nil {
		return "Could not update the leg's dates right now.", true
	}
	defer tx.Rollback(s.ctx)
	q := store.New(tx)

	// Same row lock replaceTripSection and set_trip_dates take: serializes
	// leg moves against concurrent rewrites and whole-trip shifts.
	trip, err := q.GetTripForUpdate(s.ctx, tid)
	if err != nil {
		return "Could not load the trip to update its dates.", true
	}
	if !trip.StartDate.Valid {
		return "This trip has no dates yet, so one city's dates can't be placed on its calendar. Set the trip's dates first with set_trip_dates.", true
	}
	tripStart := trip.StartDate.Time

	items, err := q.GetItineraryItemsByTrip(s.ctx, tid)
	if err != nil {
		return "Could not load the trip's itinerary.", true
	}
	stays, err := q.ListAccommodationsByTrip(s.ctx, tid)
	if err != nil {
		return "Could not load the trip's stays.", true
	}
	segs, err := q.ListSegmentsByTrip(s.ctx, tid)
	if err != nil {
		return "Could not load the trip's transport legs.", true
	}

	runs := legRuns(items)
	matched := matchLegRuns(runs, city)
	if len(matched) == 0 {
		if legs := legsSummary(runs, stays, tripStart); legs != "" {
			return fmt.Sprintf("No leg for '%s' in this trip. The legs are: %s. Use the city name as it appears in the itinerary.", city, legs), true
		}
		return "This trip's itinerary has no day-numbered city legs to move. Use set_trip_dates for the whole trip instead.", true
	}
	if len(matched) > 1 {
		var spans []string
		for _, i := range matched {
			s0, e0 := anchoredLegDisplayRange(runs, i, stays, tripStart)
			spans = append(spans, legRangeText(s0, e0))
		}
		return fmt.Sprintf("The itinerary visits %s more than once (%s), and moving just one of several visits isn't supported yet — tell the traveler plainly what you couldn't do.", runs[matched[0]].hub, strings.Join(spans, "; ")), true
	}

	run := runs[matched[0]]
	hubLower := strings.ToLower(run.hub)
	oldLegStart, oldLegEnd := anchoredLegDisplayRange(runs, matched[0], stays, tripStart)

	// The first leg's arrival IS the trip's start date (its span is anchored
	// there), so a different start is really a trip-start change — steer to
	// set_trip_dates rather than silently re-numbering items into a shape the
	// screen can't show. Carve-out: a confirmed stay anchors the leg's start
	// instead, and its check-in stays movable like any other leg's.
	if matched[0] == firstDatedRunIdx(runs) && matchedConfirmedStay(run, stays) == nil && !start.Time.Equal(tripStart) {
		return fmt.Sprintf("%s is the trip's first city, so its arrival IS the trip's start date (%s). To move when the trip begins, use set_trip_dates; to change only the departure from %s, call set_leg_dates again with start_date=%s and the new end_date.",
			run.hub, tripStart.Format(dateLayout), run.hub, tripStart.Format(dateLayout)), true
	}

	// The previous leg's end is what the trip screen renders as this leg's
	// visible start (arrival = the neighbor's departure), so a later start
	// must drag that boundary along. Resolve it before any writes.
	var prevRun *legRun
	var prevEnd time.Time
	var prevStay *store.Accommodation
	if pi := prevDatedRunIdx(runs, matched[0]); pi >= 0 {
		prevRun = &runs[pi]
		_, prevEnd = anchoredLegDisplayRange(runs, pi, stays, tripStart)
		prevStay = matchedConfirmedStay(*prevRun, stays)
	}

	ch, err := computeLegDateChange(tripStart, oldLegStart, oldLegEnd, start.Time, newEnd)
	switch err {
	case nil:
	case errLegEndBeforeStart:
		return "end_date must not be before start_date.", true
	case errLegBeforeTripStart:
		return fmt.Sprintf("The new start is before the trip begins on %s — itinerary days are anchored to the trip's first day. To start the whole trip earlier use set_trip_dates.", tripStart.Format(dateLayout)), true
	default:
		return "Could not compute the leg's new dates.", true
	}

	// Renumber the run's dated items endpoint-anchored: the old last day IS
	// the leg's departure day (the trip screen renders a leg as [previous
	// leg's end → max item day]), so its items ride the new END — a
	// single-item placeholder leg is an end-carrier, not a start-carrier.
	// Everything else keeps its within-leg offset and folds into the new span
	// (the item-beyond-span review finding covers the same shape for manual
	// edits). The shift is the DISPLAY start's delta, not min-item-day
	// anchored: for the trip-start-anchored first leg a same-start ask yields
	// zero, so interior items hold still while only the end-carrier moves;
	// item-anchored legs get the identical value either way.
	dayShift := ch.startDelta
	itemsMoved, itemsClamped := 0, 0
	for _, it := range run.items {
		if it.Day == nil {
			continue
		}
		nd := int(*it.Day) + dayShift
		clamped := false
		if int(*it.Day) == run.maxDay {
			nd = ch.newEndIdx
		} else if nd > ch.newEndIdx {
			nd, clamped = ch.newEndIdx, true
		} else if nd < ch.newStartIdx {
			nd = ch.newStartIdx
		}
		if nd == int(*it.Day) {
			continue
		}
		if clamped {
			itemsClamped++
		}
		d32 := int32(nd)
		if _, err := q.UpdateItineraryItem(s.ctx, store.UpdateItineraryItemParams{Day: &d32, ID: it.ID, TripID: tid}); err != nil {
			return "Could not move the leg's itinerary days.", true
		}
		itemsMoved++
	}

	// Move matched CONFIRMED stays, endpoint-anchored. Auto drafts are
	// skipped on purpose: UpdateAccommodation confirms a row (auto=false),
	// which would silently adopt a suggestion the traveler never chose — and
	// the client re-derives drafts from the refreshed itinerary anyway.
	staysMoved := 0
	movedStayIDs := map[uuid.UUID]bool{}
	for _, a := range stays {
		if a.Auto || !stayMatchesHub(a, hubLower) {
			continue
		}
		var newIn, newOut pgtype.Date
		if a.CheckIn.Valid {
			newIn = pgtype.Date{Time: a.CheckIn.Time.AddDate(0, 0, ch.startDelta), Valid: true}
		}
		if a.CheckOut.Valid {
			newOut = pgtype.Date{Time: a.CheckOut.Time.AddDate(0, 0, ch.endDelta), Valid: true}
		}
		if newIn.Valid && newOut.Valid && !newOut.Time.After(newIn.Time) {
			newOut.Time = newIn.Time.AddDate(0, 0, 1)
		}
		if (!newIn.Valid || newIn.Time.Equal(a.CheckIn.Time)) && (!newOut.Valid || newOut.Time.Equal(a.CheckOut.Time)) {
			continue
		}
		if _, err := q.UpdateAccommodation(s.ctx, store.UpdateAccommodationParams{CheckIn: newIn, CheckOut: newOut, ID: a.ID, TripID: tid}); err != nil {
			return "Could not move the leg's stay dates.", true
		}
		movedStayIDs[a.ID] = true
		staysMoved++
	}

	// Boundary transport (confirmed only): a segment arriving at the hub
	// rides the leg start, one departing it rides the leg end, one inside
	// the leg rides the start.
	arrMoved, depMoved := 0, 0
	for _, seg := range segs {
		if seg.Auto {
			continue
		}
		origMatch := fuzzyMatch(strings.ToLower(strings.TrimSpace(strPtrVal(seg.Origin))), hubLower)
		destMatch := fuzzyMatch(strings.ToLower(strings.TrimSpace(strPtrVal(seg.Destination))), hubLower)
		delta, departure := 0, false
		switch {
		case destMatch:
			delta = ch.startDelta
		case origMatch:
			delta, departure = ch.endDelta, true
		default:
			continue
		}
		if delta == 0 || (!seg.DepartDate.Valid && !seg.ArriveDate.Valid) {
			continue
		}
		var newDep, newArr pgtype.Date
		if seg.DepartDate.Valid {
			newDep = pgtype.Date{Time: seg.DepartDate.Time.AddDate(0, 0, delta), Valid: true}
		}
		if seg.ArriveDate.Valid {
			newArr = pgtype.Date{Time: seg.ArriveDate.Time.AddDate(0, 0, delta), Valid: true}
		}
		if _, err := q.UpdateSegment(s.ctx, store.UpdateSegmentParams{DepartDate: newDep, ArriveDate: newArr, ID: seg.ID, TripID: tid}); err != nil {
			return "Could not move the leg's transport dates.", true
		}
		if departure {
			depMoved++
		} else {
			arrMoved++
		}
	}

	// Previous-boundary extension (decided 2026-08-05): when the leg now
	// starts after the previous leg's end, drag that boundary to the new
	// start in the same transaction — editing the SAME source that produced
	// prevEnd (its confirmed stay's check-out, else its departure-day items),
	// so the visible arrival matches the ask. Gap-only: an earlier start
	// (overlap) still narrates-and-asks, neighbors never shrink.
	prevExtended := false
	var prevWasEnd time.Time
	if prevRun != nil && ch.newStart.After(prevEnd) {
		prevWasEnd = prevEnd
		switch {
		case prevStay != nil && !movedStayIDs[prevStay.ID]:
			// UpdateAccommodation flips auto=false — harmless, prevStay is
			// already confirmed; COALESCE keeps check_in.
			if _, err := q.UpdateAccommodation(s.ctx, store.UpdateAccommodationParams{
				CheckOut: pgtype.Date{Time: ch.newStart, Valid: true},
				ID:       prevStay.ID, TripID: tid,
			}); err != nil {
				return "Could not extend the previous leg's stay.", true
			}
			prevExtended = true
		case prevStay == nil:
			for _, it := range prevRun.items {
				if it.Day == nil || int(*it.Day) != prevRun.maxDay {
					continue
				}
				d32 := int32(ch.newStartIdx)
				if _, err := q.UpdateItineraryItem(s.ctx, store.UpdateItineraryItemParams{Day: &d32, ID: it.ID, TripID: tid}); err != nil {
					return "Could not extend the previous leg's days.", true
				}
				prevExtended = true
			}
		}
		// prevStay already moved as part of THIS leg (degenerate double-hub
		// match): leave the boundary alone rather than moving it twice.
	}

	tripEndExtended := false
	if trip.EndDate.Valid && ch.newEnd.After(trip.EndDate.Time) {
		if err := q.SetTripDates(s.ctx, store.SetTripDatesParams{
			ID:        tid,
			StartDate: trip.StartDate,
			EndDate:   pgtype.Date{Time: ch.newEnd, Valid: true},
		}); err != nil {
			return "Could not extend the trip's end date.", true
		}
		tripEndExtended = true
	}

	// Honest no-op: nothing changed, so nothing is committed — no touched
	// updated_at, no trip_updated SSE (the client must not flash "Trip
	// updated"), no analytics. The result reports the ACTUAL saved state,
	// never the requested range echoed back as if achieved: this branch is
	// exactly where a mismatch between what the traveler sees and what the
	// tool tracks surfaces, and the model needs the real numbers to explain
	// it (the deferred tx.Rollback discards the open transaction).
	if itemsMoved+staysMoved+arrMoved+depMoved == 0 && !prevExtended && !tripEndExtended {
		itemStart := tripStart.AddDate(0, 0, run.minDay-1)
		itemEnd := tripStart.AddDate(0, 0, run.maxDay-1)
		var b strings.Builder
		fmt.Fprintf(&b, "No saved rows changed. Actual saved state for %s: itinerary items sit on %s (trip days %d-%d)", run.hub, legRangeText(itemStart, itemEnd), run.minDay, run.maxDay)
		if a := matchedConfirmedStay(run, stays); a != nil {
			fmt.Fprintf(&b, "; its confirmed stay %q runs %s", a.Name, legRangeText(a.CheckIn.Time, a.CheckOut.Time))
		}
		if prevRun != nil {
			fmt.Fprintf(&b, "; the previous leg (%s) ends %s", prevRun.hub, prevEnd.Format(dateLayout))
		}
		visStart, visEnd := oldLegStart, oldLegEnd
		if prevRun != nil && prevEnd.Before(visStart) {
			visStart = prevEnd
		}
		fmt.Fprintf(&b, ". The trip page shows this leg as %s (a leg's visible start is the previous leg's end — or the trip's start date for the first leg — when that comes first) and was NOT refreshed.", legRangeText(visStart, visEnd))
		b.WriteString(" Never tell the traveler anything changed; if this state doesn't match what they asked for, tell them the actual dates and ask how to adjust.")
		return b.String(), false
	}

	if err := q.TouchTrip(s.ctx, store.TouchTripParams{
		ID: tid, UpdatedBy: pgtype.UUID{Bytes: s.uid, Valid: true},
	}); err != nil {
		return "Could not update the leg's dates.", true
	}
	if err := tx.Commit(s.ctx); err != nil {
		return "Could not update the leg's dates.", true
	}

	sendSSE(s.w, "trip_updated", map[string]string{"trip_id": tid.String()})
	s.itineraryEmitted = true
	s.tripID = &tid
	ownerID := trip.UserID
	safeGo("recordEvent", func() {
		recordEvent(s.uid, "agent_leg_dates_set", &tid, map[string]any{
			"city":              run.hub,
			"start_delta_days":  ch.startDelta,
			"end_delta_days":    ch.endDelta,
			"items":             itemsMoved,
			"items_clamped":     itemsClamped,
			"stays":             staysMoved,
			"segments":          arrMoved + depMoved,
			"trip_end_extended": tripEndExtended,
			"prev_leg_extended": prevExtended,
			"is_collaborator":   s.uid != ownerID,
		})
	})
	// Same collaborator-edit signal as touchTripAs; self-gated in SQL for
	// owner actors.
	if s.uid != ownerID {
		safeGo("notifyCollabEdit", func() { notifyCollabEdit(tid, s.uid) })
	}

	rangeText := legRangeText(ch.newStart, ch.newEnd)

	var b strings.Builder
	fmt.Fprintf(&b, "%s is now %s.", run.hub, rangeText)
	var parts []string
	if itemsMoved > 0 {
		parts = append(parts, fmt.Sprintf("%d itinerary item(s) onto new days", itemsMoved))
	}
	if staysMoved > 0 {
		parts = append(parts, fmt.Sprintf("%d stay(s) (check-in %s, check-out %s)", staysMoved, ch.newStart.Format(dateLayout), ch.newEnd.Format(dateLayout)))
	}
	if arrMoved+depMoved > 0 {
		parts = append(parts, fmt.Sprintf("%d arriving and %d departing transport leg(s)", arrMoved, depMoved))
	}
	if len(parts) > 0 {
		fmt.Fprintf(&b, " Moved: %s.", strings.Join(parts, ", "))
	}
	if staysMoved == 0 {
		fmt.Fprintf(&b, " No saved stay matched %s.", run.hub)
	}
	if itemsClamped > 0 {
		fmt.Fprintf(&b, " The leg got shorter, so %d item(s) past its new last day were folded onto %s.", itemsClamped, ch.newEnd.Format(dateLayout))
	}
	if tripEndExtended {
		fmt.Fprintf(&b, " Trip end extended to %s.", ch.newEnd.Format(dateLayout))
	}
	if prevExtended {
		if prevStay != nil {
			fmt.Fprintf(&b, " %s now ends %s (was %s) — its stay's check-out moved to match this leg's start.", prevRun.hub, ch.newStart.Format(dateLayout), prevWasEnd.Format(dateLayout))
		} else {
			fmt.Fprintf(&b, " %s now ends %s (was %s) — its last itinerary day moved to match this leg's start.", prevRun.hub, ch.newStart.Format(dateLayout), prevWasEnd.Format(dateLayout))
		}
	}

	// Deterministic neighbor narration: the prompt's "point out the gap"
	// instruction only works if the gap is computed here, not hoped for.
	// prevEnd is the pre-move value, so the gap branch is skipped once the
	// boundary extension closed it.
	if prevRun != nil && !prevExtended {
		if n := int(ch.newStart.Sub(prevEnd).Hours() / 24); n > 0 {
			fmt.Fprintf(&b, " NOTE: the previous leg (%s) ends %s but this leg now starts %s — %d uncovered night(s). Point this out to the traveler and offer to extend that stay or fix it with another set_leg_dates call.", prevRun.hub, prevEnd.Format(dateLayout), ch.newStart.Format(dateLayout), n)
		} else if n < 0 {
			fmt.Fprintf(&b, " NOTE: the previous leg (%s) ends %s, which now overlaps this leg's start %s by %d night(s). Point this out to the traveler and offer to fix it.", prevRun.hub, prevEnd.Format(dateLayout), ch.newStart.Format(dateLayout), -n)
		}
	}
	if ni := nextDatedRunIdx(runs, matched[0]); ni >= 0 {
		next := &runs[ni]
		nextStart, nextEnd := anchoredLegDisplayRange(runs, ni, stays, tripStart)
		n := int(nextStart.Sub(ch.newEnd).Hours() / 24)
		switch {
		// Squeeze first: the next leg's visible span is [this leg's end → its
		// own departure day], so newEnd reaching its END consumes ALL its
		// nights even when the starts compare as contiguous (n == 0) — the
		// exact case gap/overlap math is silent on.
		case !ch.newEnd.Before(nextEnd):
			fmt.Fprintf(&b, " NOTE: this leg now ends %s, which reaches the end of the next leg (%s, currently ending %s) — %s has no nights left. Point this out and offer to move %s later with set_leg_dates; if the traveler agrees, also move any legs after it, calling set_leg_dates once per leg in order (earliest first) in this same turn.", ch.newEnd.Format(dateLayout), next.hub, nextEnd.Format(dateLayout), next.hub, next.hub)
		case n < 0:
			fmt.Fprintf(&b, " NOTE: this leg now ends %s, overlapping the next leg (%s) which starts %s. Point this out to the traveler and offer to fix it.", ch.newEnd.Format(dateLayout), next.hub, nextStart.Format(dateLayout))
		case n > 0:
			fmt.Fprintf(&b, " NOTE: this leg now ends %s but the next leg (%s) starts %s — %d uncovered night(s). Point this out to the traveler and offer to fix it.", ch.newEnd.Format(dateLayout), next.hub, nextStart.Format(dateLayout), n)
		}
	}

	b.WriteString(" IMPORTANT: anything already booked with a real provider (flights, hotels, ferries) still holds its ORIGINAL dates — remind the traveler to re-check and rebook those. If any manually added booking to-dos carry the old dates, update them with update_booking_todo. The traveler's trip page has refreshed.")
	return b.String(), false
}

// prevDatedRunIdx / nextDatedRunIdx find the nearest movable neighbor for
// the boundary moves and gap/overlap/squeeze narration; hubless or undated
// filler runs are skipped. -1 when there is none. Index-returning so callers
// can resolve ranges through anchoredLegDisplayRange.
func prevDatedRunIdx(runs []legRun, i int) int {
	for j := i - 1; j >= 0; j-- {
		if runs[j].minDay >= 1 && runs[j].hub != "" {
			return j
		}
	}
	return -1
}

func nextDatedRunIdx(runs []legRun, i int) int {
	for j := i + 1; j < len(runs); j++ {
		if runs[j].minDay >= 1 && runs[j].hub != "" {
			return j
		}
	}
	return -1
}
