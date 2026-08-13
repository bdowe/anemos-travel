package main

import (
	"fmt"
	"strings"
	"time"

	"travel-route-planner/store"
)

// trip_next_step.go — the "Next Step" projection (specs/next-step-cta): the
// single recommended next planning action for a trip, derived as the FIRST
// unmet phase of a fixed ladder (dates → itinerary → lodging → transport →
// schedule → bookings → packing). Like trip_review.go it is DETERMINISTIC and
// read-only: derived only from persisted data and the deterministic findings,
// never from the live weather/hours enrichment — so the step is identical
// whether or not the caller opted into check_hours, and both client cache
// variants agree.
//
// deriveNextStep is composed AFTER reviewTrip at both call sites (the review
// handler and the review_trip agent tool); it consumes lodging/transit
// findings by category and reads the extra signals (zero items, unbooked
// booking todos, empty packing checklist) straight off exportData. Budget,
// weather and opening hours are deliberately NOT phases: a budget target is
// optional, and the live enrichments would make the step flap between
// fetches.

// NextStep is the first unmet phase of the planning ladder. Title/Detail are
// localized display copy; SeedPrompt is CANONICAL ENGLISH (specs/i18n-spanish:
// it is agent input, not display copy — the client shows Title instead, and
// the templates live here as English constants precisely so nobody localizes
// them). Fix reuses the finding-fix contract so the client's existing
// apply-fix plumbing handles the mechanical path without new action types.
type NextStep struct {
	Kind       string      `json:"kind"` // set_dates|plan_itinerary|add_lodging|add_transport|schedule_items|book_trip|add_packing|all_set
	Title      string      `json:"title"`
	Detail     string      `json:"detail,omitempty"`
	Day        *int        `json:"day,omitempty"`   // scroll anchor, same convention as Finding.Day
	Count      *int        `json:"count,omitempty"` // items behind the step: unscheduled places, unbooked rows
	Fix        *FindingFix `json:"fix,omitempty"`
	SeedPrompt string      `json:"seed_prompt,omitempty"`
}

// PlanProgress is prefix progress through the ladder: Done phases are complete
// from the top, so the current step is phase Done+1 and all_set reports 7/7.
// Total is a field (not a client-side constant) so the ladder can grow without
// a lockstep client release.
type PlanProgress struct {
	Done  int `json:"done"`
	Total int `json:"total"`
}

const planLadderTotal = 7

// deriveNextStep walks the ladder and returns the first unmet phase, or the
// all_set terminal step when every phase is complete. Both results are nil for
// a past trip (end date before today) — nothing left to plan is different from
// "all set", and the card should show neither. `now` is explicit so tests are
// time-stable; callers pass time.Now().UTC().
func deriveNextStep(locale string, now time.Time, data exportData, findings []Finding) (*NextStep, *PlanProgress) {
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	if data.Trip.EndDate.Valid && data.Trip.EndDate.Time.Before(today) {
		return nil, nil
	}

	progress := func(done int) *PlanProgress {
		return &PlanProgress{Done: done, Total: planLadderTotal}
	}

	// Phase 1 — dates. The repo's first "unfinished work" arm (migration
	// 00057); every later phase is date-bound.
	if !data.Trip.StartDate.Valid || !data.Trip.EndDate.Valid {
		return &NextStep{
			Kind:       "set_dates",
			Title:      tr(locale, "review.next.setDates.title"),
			Detail:     tr(locale, "review.next.setDates.detail"),
			Fix:        &FindingFix{Action: "set_dates", Label: tr(locale, "review.fix.setDates")},
			SeedPrompt: seedSetDates(data),
		}, progress(0)
	}

	// Phase 2 — an itinerary that exists and is scheduled. The none-scheduled
	// variant is folded in here (not phase 5): with zero scheduled days the
	// hub/night walks below would run on air and their prefills would be
	// meaningless.
	if len(data.Items) == 0 {
		return &NextStep{
			Kind:       "plan_itinerary",
			Title:      tr(locale, "review.next.planItinerary.title"),
			Detail:     tr(locale, "review.next.planItinerary.empty"),
			SeedPrompt: seedPlanItineraryEmpty(data),
		}, progress(1)
	}
	if unscheduled := countUnscheduled(data.Items); unscheduled == len(data.Items) {
		count := unscheduled
		return &NextStep{
			Kind:       "plan_itinerary",
			Title:      tr(locale, "review.next.planItinerary.title"),
			Detail:     unscheduledMessage(locale, count),
			Count:      &count,
			SeedPrompt: seedPlanItineraryUnscheduled(data, count),
		}, progress(1)
	}

	// Phases 3 & 4 — lodging and transport gaps, straight from the findings
	// (first = earliest day thanks to reviewTrip's stable sort). The finding's
	// Fix rides along verbatim so the health sheet's one-tap path stays
	// available for the same gap.
	if f := firstFindingIn(findings, "lodging"); f != nil {
		return &NextStep{
			Kind:       "add_lodging",
			Title:      tr(locale, "review.next.addLodging.title"),
			Detail:     f.Message,
			Day:        f.Day,
			Fix:        f.Fix,
			SeedPrompt: seedAddLodging(data, f.Fix),
		}, progress(2)
	}
	if f := firstFindingIn(findings, "transit"); f != nil {
		return &NextStep{
			Kind:       "add_transport",
			Title:      tr(locale, "review.next.addTransport.title"),
			Detail:     f.Message,
			Day:        f.Day,
			Fix:        f.Fix,
			SeedPrompt: seedAddTransport(data, f.Fix),
		}, progress(3)
	}

	// Phase 5 — schedule cleanup: leftover unscheduled places and empty days.
	// Read via the shared helpers, not by sniffing findings — empty-day
	// findings share category "packing" with the over-packed warnings and
	// carry no distinguishing field.
	unscheduled := countUnscheduled(data.Items)
	emptyRuns := emptyDayRuns(data.Items)
	if unscheduled > 0 || len(emptyRuns) > 0 {
		step := &NextStep{
			Kind:       "schedule_items",
			Title:      tr(locale, "review.next.scheduleItems.title"),
			SeedPrompt: seedScheduleItems(data, unscheduled, emptyRuns),
		}
		switch {
		case unscheduled > 0:
			step.Detail = unscheduledMessage(locale, unscheduled)
			step.Count = &unscheduled
		case emptyRuns[0].first == emptyRuns[0].last:
			step.Detail = tr(locale, "review.emptyDay", emptyRuns[0].first)
		default:
			step.Detail = tr(locale, "review.emptyDayRange", emptyRuns[0].first, emptyRuns[0].last)
		}
		if len(emptyRuns) > 0 {
			step.Day = ptrTo(emptyRuns[0].first)
		}
		return step, progress(4)
	}

	// Phase 6 — book everything still open.
	if labels := unbookedLabels(data); len(labels) > 0 {
		count := len(labels)
		detail := tr(locale, "review.next.book.one")
		if count > 1 {
			detail = tr(locale, "review.next.book.many", count)
		}
		return &NextStep{
			Kind:       "book_trip",
			Title:      tr(locale, "review.next.book.title"),
			Detail:     detail,
			Count:      &count,
			SeedPrompt: seedBookTrip(data, labels),
		}, progress(5)
	}

	// Phase 7 — packing, only while the trip is still ahead: mid-trip the
	// checklist nag is noise, but booking tonight's hotel above never was.
	if len(data.Checklist) == 0 && today.Before(data.Trip.StartDate.Time) {
		return &NextStep{
			Kind:       "add_packing",
			Title:      tr(locale, "review.next.packing.title"),
			Detail:     tr(locale, "review.next.packing.detail"),
			SeedPrompt: seedAddPacking(data),
		}, progress(6)
	}

	// Terminal — an explicit step, not an absence, so the client renders the
	// celebration deliberately (absence means exactly one thing: past trip).
	return &NextStep{
		Kind:   "all_set",
		Title:  tr(locale, "review.next.allSet.title"),
		Detail: tr(locale, "review.next.allSet.detail"),
	}, progress(planLadderTotal)
}

// firstFindingIn returns the first finding of the given category — with
// reviewTrip's stable day→severity→category sort that is the earliest-day gap.
func firstFindingIn(findings []Finding, category string) *Finding {
	for i := range findings {
		if findings[i].Category == category {
			return &findings[i]
		}
	}
	return nil
}

// unscheduledMessage reuses the exact copy checkUnscheduled emits, so the card
// and the health sheet describe the same gap in the same words.
func unscheduledMessage(locale string, count int) string {
	if count == 1 {
		return tr(locale, "review.unscheduledOne")
	}
	return tr(locale, "review.unscheduledMany", count)
}

// unbookedLabels is the book_trip aggregate: display labels for every open
// booking, deduped across the two systems that can describe the same gap.
// Server-truth rows (the traveler's own accommodations/segments, non-auto,
// unbooked) count first; booking todos then count only when no non-auto row
// already claims their leg — a "Stay in Porto" todo and a hand-added Porto
// hotel are one gap, not two. Matching reuses the same fuzzy helpers as
// checkTransit; the todo_key prefixes (stay:<city>, transport:<a>>><b>) are
// the established cross-system convention the client derives and the sync
// handler dedupes on. The count is motivational — the TRIGGER (any label at
// all) is exact, and parity with the client's claim-once slot partition is
// explicitly out of scope (specs/next-step-cta).
func unbookedLabels(d exportData) []string {
	var labels []string
	for _, a := range d.Accommodations {
		if a.Auto || a.Booked {
			continue
		}
		labels = append(labels, a.Name)
	}
	for _, s := range d.Segments {
		if s.Auto || s.Booked {
			continue
		}
		labels = append(labels, segmentRoute(s))
	}
	for _, t := range d.BookingTodos {
		if t.Booked || todoClaimed(d, t) {
			continue
		}
		labels = append(labels, t.Title)
	}
	return labels
}

// todoClaimed reports whether a non-auto accommodation/segment already covers
// the leg a derived todo describes (booked or not — either way the todo is not
// a separate gap). Custom todos ("custom:*" keys) never match and always count.
func todoClaimed(d exportData, t store.BookingTodo) bool {
	switch t.Kind {
	case "stay":
		city := strings.TrimPrefix(t.TodoKey, "stay:")
		if city == "" || city == t.TodoKey {
			return false
		}
		for _, a := range d.Accommodations {
			if a.Auto {
				continue
			}
			name := strings.ToLower(a.Name)
			addr := strings.ToLower(strings.TrimSpace(strPtrVal(a.Address)))
			if fuzzyMatch(name, city) || fuzzyMatch(addr, city) {
				return true
			}
		}
	case "transport":
		key := strings.TrimPrefix(t.TodoKey, "transport:")
		origin, dest, ok := strings.Cut(key, ">>")
		if !ok || key == t.TodoKey {
			return false
		}
		var confirmed []store.TripSegment
		for _, s := range d.Segments {
			if !s.Auto {
				confirmed = append(confirmed, s)
			}
		}
		return segmentConnects(confirmed, origin, dest)
	}
	return false
}

// --- seed prompts -------------------------------------------------------------
//
// Canonical-English chat seeds, in _buildSectionSeed's first-person voice
// (trip_detail_screen.dart). Kept compact on purpose — they ride every review
// response — so instead of embedding the item list they point the agent at
// get_trip. Every tool they name exists in the /plan registry; if the toolset
// changes, change the template here (the server owns this vocabulary).

// seedTripRef renders `my saved trip "Title" (2026-09-01 to 2026-09-14)` — the
// shared opening reference of every seed.
func seedTripRef(d exportData) string {
	ref := fmt.Sprintf("my saved trip %q", d.Trip.Title)
	if d.Trip.StartDate.Valid && d.Trip.EndDate.Valid {
		ref += fmt.Sprintf(" (%s to %s)",
			d.Trip.StartDate.Time.Format(dateLayout), d.Trip.EndDate.Time.Format(dateLayout))
	}
	return ref
}

func seedSetDates(d exportData) string {
	return fmt.Sprintf("My saved trip %q has no dates yet. Help me pick travel dates — "+
		"start by asking when I want to go and for how long, then call set_trip_dates to save them.",
		d.Trip.Title)
}

func seedPlanItineraryEmpty(d exportData) string {
	return fmt.Sprintf("I want to plan %s. It has no places yet. Help me build the "+
		"itinerary from scratch: suggest real places day by day (use search_places, and check "+
		"search_local_recommendations for each city), and when I confirm a plan, call "+
		"update_itinerary_section with scope='trip' and the COMPLETE list of places. "+
		"Start by asking what kind of trip I want — pace, interests, and any must-sees.",
		seedTripRef(d))
}

func seedPlanItineraryUnscheduled(d exportData, count int) string {
	return fmt.Sprintf("I want to refine %s. It has %d saved place(s) but none are scheduled "+
		"to a day. Call get_trip to see them, propose a day-by-day arrangement, and when I "+
		"confirm, call update_itinerary_section with scope='trip' and the COMPLETE updated "+
		"list, keeping every place's coordinates and tags unchanged. Start by proposing a plan.",
		seedTripRef(d), count)
}

func seedAddLodging(d exportData, fix *FindingFix) string {
	where := ""
	dates := ""
	if fix != nil {
		if fix.City != nil {
			where = " in " + *fix.City
		}
		if fix.CheckIn != nil && fix.CheckOut != nil {
			dates = fmt.Sprintf(" for %s to %s", *fix.CheckIn, *fix.CheckOut)
		}
	}
	return fmt.Sprintf("I want to refine %s.\n\nI still need a place to stay%s%s. "+
		"Suggest a few good lodging options (call suggest_stays) at a couple of price levels, "+
		"well located for my itinerary, and help me pick one; when I choose, call "+
		"add_accommodation with those dates. Do not change the itinerary places. "+
		"Start by asking about my budget and preferred area.",
		seedTripRef(d), where, dates)
}

func seedAddTransport(d exportData, fix *FindingFix) string {
	leg := "between my cities"
	when := ""
	mode := ""
	if fix != nil {
		if fix.Origin != nil && fix.Destination != nil {
			leg = fmt.Sprintf("from %s to %s", *fix.Origin, *fix.Destination)
		}
		if fix.Date != nil {
			when = fmt.Sprintf(" around %s", *fix.Date)
		}
		if fix.Mode != nil {
			mode = fmt.Sprintf(" (%s suggested)", *fix.Mode)
		}
	}
	return fmt.Sprintf("I want to refine %s.\n\nI still need transport %s%s%s. "+
		"Compare the realistic options — mode, duration, rough price, where to book; use "+
		"search_flights for flights and suggest_ferries where a ferry fits — and help me "+
		"choose; when I decide, call add_transport_segment. Do not change the itinerary "+
		"places. Start with your recommendation and the alternatives.",
		seedTripRef(d), leg, when, mode)
}

func seedScheduleItems(d exportData, unscheduled int, runs []dayRun) string {
	var gaps []string
	if unscheduled > 0 {
		gaps = append(gaps, fmt.Sprintf("%d place(s) have no day assigned", unscheduled))
	}
	for _, r := range runs {
		if r.first == r.last {
			gaps = append(gaps, fmt.Sprintf("day %d is empty", r.first))
		} else {
			gaps = append(gaps, fmt.Sprintf("days %d–%d are empty", r.first, r.last))
		}
	}
	return fmt.Sprintf("I want to refine %s. The schedule has gaps: %s. "+
		"Call get_trip to see the current plan, propose where everything fits (suggest new "+
		"places for the empty days if it needs them), and when I confirm, call "+
		"update_itinerary_section with scope='trip' and the COMPLETE updated list, keeping "+
		"unchanged places exactly as they are (same coordinates and tags). "+
		"Start by proposing a plan for the gaps.",
		seedTripRef(d), strings.Join(gaps, "; "))
}

// seedBookTripMaxLines caps the unbooked list embedded in the book_trip seed so
// the review payload stays lean on a heavily-unbooked trip.
const seedBookTripMaxLines = 8

func seedBookTrip(d exportData, labels []string) string {
	shown := labels
	more := 0
	if len(shown) > seedBookTripMaxLines {
		more = len(shown) - seedBookTripMaxLines
		shown = shown[:seedBookTripMaxLines]
	}
	var b strings.Builder
	fmt.Fprintf(&b, "Help me get %s fully booked. Still unbooked:\n", seedTripRef(d))
	for _, l := range shown {
		b.WriteString("- " + l + "\n")
	}
	if more > 0 {
		fmt.Fprintf(&b, "…and %d more.\n", more)
	}
	b.WriteString("Walk me through them one at a time — use search_flights for flights and " +
		"suggest_stays for lodging — and as I confirm each one, mark the matching booking " +
		"to-do booked with update_booking_todo. Start with whichever booking is most urgent.")
	return b.String()
}

func seedAddPacking(d exportData) string {
	var cities []string
	seen := map[string]bool{}
	for _, g := range groupExportItems(d.Trip, d.Items) {
		hub := strings.TrimSpace(g.Hub)
		if hub == "" || hub == "Itinerary" || seen[strings.ToLower(hub)] {
			continue
		}
		seen[strings.ToLower(hub)] = true
		cities = append(cities, hub)
	}
	dest := ""
	if len(cities) > 0 {
		dest = fmt.Sprintf("; destinations: %s", strings.Join(cities, ", "))
	}
	return fmt.Sprintf("Build me a packing list for %s%s. Check the weather for those dates "+
		"(get_weather), then add the items with add_packing_item, one call per item with a "+
		"sensible category. Start with a short list of essentials tailored to the trip, then "+
		"ask what else I should include.",
		seedTripRef(d), dest)
}
