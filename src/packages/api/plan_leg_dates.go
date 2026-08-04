package main

// set_leg_dates (specs/set-leg-dates): the /plan agent's way to change WHEN
// one city leg of a saved trip happens without moving the rest of the trip.
// set_trip_dates shifts everything by one delta; a leg move is endpoint-
// anchored instead — the start and end can shift by different amounts (LA
// Sep 20-24 -> Sep 24-27 is +4 on check-in, +3 on check-out). One transaction
// renumbers the leg's item days, moves its matched confirmed stays and
// boundary transport, and extends the trip's end date when the leg now runs
// past it. Neighbor legs deliberately do NOT move (decided 2026-08-04): the
// tool result narrates any gap/overlap it opened so the agent can offer the
// follow-up fix, and the trip health review flags whatever remains. Gated
// authedOnly (per-conversation stable, prompt-cache safe); target-trip
// resolution reuses resolveDateShiftTrip.

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	anthropic "github.com/anthropics/anthropic-sdk-go"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

var setLegDatesTool = anthropic.ToolParam{
	Name: "set_leg_dates",
	Description: anthropic.String("Change the dates of ONE city's leg within the traveler's saved trip — 'make LA Sep 24 to 27', 'arrive in Rome a day later' — without moving the rest of the trip. " +
		"It moves that city's itinerary days, its stay's check-in/check-out, and the transport into and out of that city, extending the trip's end date when the new leg runs past it. " +
		"Other cities do NOT move: the result reports any gap or overlap this created with neighboring legs — relay it to the traveler and offer to fix those legs too. " +
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

// legDisplayRange resolves the calendar span a leg currently occupies, with
// the same precedence the trip screen renders: the first confirmed matched
// stay with both dates, else the dated items' day range off the trip anchor.
func legDisplayRange(run legRun, stays []store.Accommodation, tripStart time.Time) (time.Time, time.Time) {
	hubLower := strings.ToLower(run.hub)
	for _, a := range stays {
		if a.Auto || !a.CheckIn.Valid || !a.CheckOut.Valid {
			continue
		}
		if stayMatchesHub(a, hubLower) {
			return a.CheckIn.Time, a.CheckOut.Time
		}
	}
	return tripStart.AddDate(0, 0, run.minDay-1), tripStart.AddDate(0, 0, run.maxDay-1)
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
	for _, r := range runs {
		if r.minDay < 1 || r.hub == "" {
			continue
		}
		s, e := legDisplayRange(r, stays, tripStart)
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
			s0, e0 := legDisplayRange(runs[i], stays, tripStart)
			spans = append(spans, legRangeText(s0, e0))
		}
		return fmt.Sprintf("The itinerary visits %s more than once (%s), and moving just one of several visits isn't supported yet — tell the traveler plainly what you couldn't do.", runs[matched[0]].hub, strings.Join(spans, "; ")), true
	}

	run := runs[matched[0]]
	hubLower := strings.ToLower(run.hub)
	oldLegStart, oldLegEnd := legDisplayRange(run, stays, tripStart)

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

	// Renumber the run's dated items, preserving within-leg offsets; items
	// past a shortened leg fold onto its new last day (the item-beyond-span
	// review finding covers the same shape for manual edits).
	dayShift := ch.newStartIdx - run.minDay
	itemsMoved, itemsClamped := 0, 0
	for _, it := range run.items {
		if it.Day == nil {
			continue
		}
		nd := int(*it.Day) + dayShift
		if nd > ch.newEndIdx {
			nd = ch.newEndIdx
			itemsClamped++
		}
		if nd == int(*it.Day) {
			continue
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
			"is_collaborator":   s.uid != ownerID,
		})
	})
	// Same collaborator-edit signal as touchTripAs; self-gated in SQL for
	// owner actors.
	if s.uid != ownerID {
		safeGo("notifyCollabEdit", func() { notifyCollabEdit(tid, s.uid) })
	}

	rangeText := legRangeText(ch.newStart, ch.newEnd)
	if itemsMoved+staysMoved+arrMoved+depMoved == 0 && !tripEndExtended {
		return fmt.Sprintf("Nothing needed to move — %s already spans %s. The traveler's trip page has refreshed.", run.hub, rangeText), false
	}

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

	// Deterministic neighbor narration: the prompt's "point out the gap"
	// instruction only works if the gap is computed here, not hoped for.
	if i := matched[0]; i > 0 {
		if prev := prevDatedRun(runs, i); prev != nil {
			_, prevEnd := legDisplayRange(*prev, stays, tripStart)
			if n := int(ch.newStart.Sub(prevEnd).Hours() / 24); n > 0 {
				fmt.Fprintf(&b, " NOTE: the previous leg (%s) ends %s but this leg now starts %s — %d uncovered night(s). Point this out to the traveler and offer to extend that stay or fix it with another set_leg_dates call.", prev.hub, prevEnd.Format(dateLayout), ch.newStart.Format(dateLayout), n)
			} else if n < 0 {
				fmt.Fprintf(&b, " NOTE: the previous leg (%s) ends %s, which now overlaps this leg's start %s by %d night(s). Point this out to the traveler and offer to fix it.", prev.hub, prevEnd.Format(dateLayout), ch.newStart.Format(dateLayout), -n)
			}
		}
	}
	if i := matched[0]; i < len(runs)-1 {
		if next := nextDatedRun(runs, i); next != nil {
			nextStart, _ := legDisplayRange(*next, stays, tripStart)
			if n := int(nextStart.Sub(ch.newEnd).Hours() / 24); n > 0 {
				fmt.Fprintf(&b, " NOTE: this leg now ends %s but the next leg (%s) starts %s — %d uncovered night(s). Point this out to the traveler and offer to fix it.", ch.newEnd.Format(dateLayout), next.hub, nextStart.Format(dateLayout), n)
			} else if n < 0 {
				fmt.Fprintf(&b, " NOTE: this leg now ends %s, overlapping the next leg (%s) which starts %s. Point this out to the traveler and offer to fix it.", ch.newEnd.Format(dateLayout), next.hub, nextStart.Format(dateLayout))
			}
		}
	}

	b.WriteString(" IMPORTANT: anything already booked with a real provider (flights, hotels, ferries) still holds its ORIGINAL dates — remind the traveler to re-check and rebook those. If any manually added booking to-dos carry the old dates, update them with update_booking_todo. The traveler's trip page has refreshed.")
	return b.String(), false
}

// prevDatedRun / nextDatedRun find the nearest movable neighbor for the
// gap/overlap narration; hubless or undated filler runs are skipped.
func prevDatedRun(runs []legRun, i int) *legRun {
	for j := i - 1; j >= 0; j-- {
		if runs[j].minDay >= 1 && runs[j].hub != "" {
			return &runs[j]
		}
	}
	return nil
}

func nextDatedRun(runs []legRun, i int) *legRun {
	for j := i + 1; j < len(runs); j++ {
		if runs[j].minDay >= 1 && runs[j].hub != "" {
			return &runs[j]
		}
	}
	return nil
}
