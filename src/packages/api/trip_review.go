package main

import (
	"context"
	"sort"
	"strings"
	"time"
	"unicode"

	"github.com/jackc/pgx/v5/pgtype"
	"golang.org/x/sync/errgroup"

	"travel-route-planner/store"
)

// trip_review.go — a DETERMINISTIC, read-only trip review. It flags real
// problems in a saved trip (unscheduled items, uncovered nights, missing
// transport, over budget, unconfirmed bookings, …) by walking the already-
// loaded exportData. NO AI, NO external calls, NO migration: every finding
// traces to persisted data, so nothing here can hallucinate. reviewTrip is a
// pure function over its inputs — each check is a small, individually-testable
// helper so PR3 can add checkWeather/checkHours alongside without reshaping it.

// Finding is one flagged issue. Day/ItemID follow ItineraryItemResponse's
// nullable-pointer + omitempty convention: absent when the finding isn't tied
// to a specific day or entity. Severity is info|warn|critical; Category is one
// of dates|unscheduled|packing|lodging|transit|budget|bookings|weather|hours.
type Finding struct {
	Severity string      `json:"severity"`
	Category string      `json:"category"`
	Message  string      `json:"message"`
	TripID   string      `json:"trip_id"`
	Day      *int        `json:"day,omitempty"`
	ItemID   *string     `json:"item_id,omitempty"`
	Fix      *FindingFix `json:"fix,omitempty"`
}

// FindingFix is a structured, typed descriptor of the one-tap remediation a
// finding suggests — additive over the prose Message so the UI (and, later, the
// AI agent) can act on a finding without re-parsing its text. Every field is a
// nullable pointer with omitempty: only the ones an Action needs are populated,
// so the payload stays lean and backward-compatible (older clients ignore it).
// Populated deterministically inside the same checkX helper that emits the
// finding — never a live/external lookup.
type FindingFix struct {
	Action          string  `json:"action"` // add_lodging|add_transport|move_item|mark_booked|add_packing|set_dates|raise_budget
	Label           string  `json:"label"`  // human button label, e.g. "Add a stay", "Add ferry", "Move to Day 3"
	ItemID          *string `json:"item_id,omitempty"`
	EntityType      *string `json:"entity_type,omitempty"` // "accommodation"|"segment" — disambiguates a bookings ItemID
	TargetDay       *int    `json:"target_day,omitempty"`
	City            *string `json:"city,omitempty"`
	Origin          *string `json:"origin,omitempty"`
	Destination     *string `json:"destination,omitempty"`
	CheckIn         *string `json:"check_in,omitempty"`  // YYYY-MM-DD
	CheckOut        *string `json:"check_out,omitempty"` // YYYY-MM-DD
	Date            *string `json:"date,omitempty"`      // YYYY-MM-DD
	Mode            *string `json:"mode,omitempty"`      // ferry|flight|train|bus|car
	PackingItem     *string `json:"packing_item,omitempty"`
	PackingCategory *string `json:"packing_category,omitempty"`
}

// ptrTo returns a pointer to v — a tiny helper for populating FindingFix's
// nullable-pointer fields from literals without a temporary local each time.
func ptrTo[T any](v T) *T { return &v }

// reviewOptions carries inputs that don't live on exportData. Budget is the
// pre-computed BudgetResponse (nil when there's no budget row) so checkBudget
// stays a pure reader. CheckHours opts the trip into the (billable, live
// Google) operating-hours check — off by default so a plain review never
// spends.
type reviewOptions struct {
	CheckHours bool
	Budget     *BudgetResponse
}

// reviewDeps carries the live-lookup services the enrichment checks need. Both
// are nil-safe: a nil service makes its check a silent no-op (that's how the
// pure unit tests and the deterministic-order test run without a network).
type reviewDeps struct {
	Weather *WeatherService
	Places  *GooglePlacesService
}

// reviewTrip runs every deterministic check over the loaded trip data and
// returns the findings in a stable order (by day, then severity, then
// category) so the output is reproducible for a given trip snapshot. The
// weather/place-hours checks are best-effort live lookups threaded through
// deps; any provider error skips silently so the review never fails.
// The locale is threaded in explicitly rather than read off ctx: reviewTrip is
// also driven by the agent tool and by tests that have no request context, and
// an explicit parameter keeps the finding copy a pure function of its inputs.
func reviewTrip(ctx context.Context, locale string, data exportData, opts reviewOptions, deps reviewDeps) []Finding {
	findings := make([]Finding, 0)
	findings = append(findings, checkDates(locale, data)...)
	findings = append(findings, checkUnscheduled(locale, data)...)
	findings = append(findings, checkDensity(locale, data)...)
	findings = append(findings, checkLodging(locale, data)...)
	findings = append(findings, checkTransit(locale, data)...)
	findings = append(findings, checkBudget(locale, data, opts.Budget)...)
	findings = append(findings, checkBookings(locale, data)...)
	findings = append(findings, checkWeather(ctx, locale, data, deps.Weather)...)
	if opts.CheckHours {
		findings = append(findings, checkHours(ctx, locale, data, deps.Places)...)
	}

	severityRank := map[string]int{"critical": 0, "warn": 1, "info": 2}
	sort.SliceStable(findings, func(i, j int) bool {
		di, dj := findingDayKey(findings[i]), findingDayKey(findings[j])
		if di != dj {
			return di < dj
		}
		if si, sj := severityRank[findings[i].Severity], severityRank[findings[j].Severity]; si != sj {
			return si < sj
		}
		return findings[i].Category < findings[j].Category
	})
	return findings
}

// findingDayKey sorts undated findings (Day == nil) after all day-bound ones.
func findingDayKey(f Finding) int {
	if f.Day == nil {
		return 1 << 30
	}
	return *f.Day
}

// tripDayCount is the number of days the trip's DATES cover (start..end,
// inclusive) — the date-span branch of trip_days.dart's dayCount. Unlike the
// Dart helper it deliberately does NOT fold in tagged item days: this is the
// yardstick the beyond-span check measures items against, so an item tagged
// past the span must not extend the yardstick to hide itself. 0 when undated.
func tripDayCount(trip store.Trip) int {
	if !trip.StartDate.Valid || !trip.EndDate.Valid {
		return 0
	}
	return nightsBetween(trip.StartDate.Time, trip.EndDate.Time) + 1
}

// nightsBetween counts whole calendar days from start to end. pgtype dates are
// UTC midnights, so the subtraction is exact; the +0.5 guards against any FP
// drift.
func nightsBetween(start, end time.Time) int {
	return int(end.Sub(start).Hours()/24 + 0.5)
}

// checkDates flags a trip with no dates (blocks every day-bound check) and any
// item tagged to a day past the trip's span.
func checkDates(locale string, d exportData) []Finding {
	tripID := d.Trip.ID.String()
	var out []Finding
	if !d.Trip.StartDate.Valid || !d.Trip.EndDate.Valid {
		out = append(out, Finding{
			Severity: "info", Category: "dates", TripID: tripID,
			Message: tr(locale, "review.noDates"),
			Fix:     &FindingFix{Action: "set_dates", Label: tr(locale, "review.fix.setDates")},
		})
		return out // no span → the beyond-span check below is meaningless
	}
	dc := tripDayCount(d.Trip)
	for _, it := range d.Items {
		if it.Day != nil && int(*it.Day) > dc {
			day := int(*it.Day)
			id := it.ID.String()
			lastValidDay := dc
			out = append(out, Finding{
				Severity: "warn", Category: "dates", TripID: tripID, Day: &day, ItemID: &id,
				Message: tr(locale, "review.itemBeyondSpan", it.Name, day, dc),
				Fix: &FindingFix{
					Action: "move_item", Label: tr(locale, "review.fix.moveToDay", lastValidDay),
					ItemID: &id, TargetDay: &lastValidDay,
				},
			})
		}
	}
	return out
}

// countUnscheduled counts the items with no day assigned. Shared with
// deriveNextStep (trip_next_step.go) so "unscheduled" has one definition.
func countUnscheduled(items []store.ItineraryItem) int {
	count := 0
	for _, it := range items {
		if it.Day == nil {
			count++
		}
	}
	return count
}

// checkUnscheduled emits one grouped finding for all items with no day (cleaner
// than one-per-item when many are unscheduled).
func checkUnscheduled(locale string, d exportData) []Finding {
	count := countUnscheduled(d.Items)
	if count == 0 {
		return nil
	}
	msg := tr(locale, "review.unscheduledOne")
	if count > 1 {
		msg = tr(locale, "review.unscheduledMany", count)
	}
	return []Finding{{
		Severity: "info", Category: "unscheduled", TripID: d.Trip.ID.String(), Message: msg,
	}}
}

// dayRun is an inclusive run of consecutive empty days ([first, last]).
type dayRun struct {
	first, last int
}

// isCityFiller reports the AI's "city filler" placeholder — an item whose name
// is just the city (or day-trip hub) it renders under, emitted by
// create_itinerary for days with no specific activities.
//
// SECOND IMPLEMENTATION, deliberately: the Flutter app owns the first
// (isCityFiller, lib/screens/trip_detail_derivation.dart) and HIDES these rows,
// so a server that counts them speaks about places the traveler cannot see —
// which is exactly how "Plan your days" came to check itself off on a trip with
// nothing planned. docs/zen.md requires a parity contract for the second
// implementation: twin fixture tables in city_filler_test.go and
// test/trip_detail_derivation_test.dart, each naming the other.
//
// One DOCUMENTED divergence, pinned in both tables: the Dart predicate compares
// against cityOf(), which falls back to a regex over the item's address when
// the city column is empty. The server has no copy of that heuristic and is not
// growing one — a second regex would drift. AI-emitted fillers always set city,
// so the divergence only reaches hand-made rows with an empty city column,
// where the server is merely less aggressive about hiding.
func isCityFiller(it store.ItineraryItem) bool {
	name := strings.ToLower(strings.TrimSpace(it.Name))
	if name == "" {
		return false
	}
	eq := func(s *string) bool {
		return s != nil && strings.ToLower(strings.TrimSpace(*s)) == name
	}
	return eq(it.City) || eq(it.DayTripFrom)
}

// dayCoverage is the trip's day-by-day planning state, in ONE pass: which days
// carry real content, the runs that do not, and the exact denominator the
// ladder's "Plan your days" rung reports. Trip Health's empty-day findings, the
// ladder's rung-4 test and that rung's tally all read this one value, so they
// cannot disagree — the doctrine walkBookingSlots already follows for rung 3.
type dayCoverage struct {
	Planned int      // days inside Total carrying real content
	Total   int      // PLANNABLE days (see walkDayCoverage); 0 when undated
	Empty   []dayRun // runs of consecutive days with nothing planned
}

// walkDayCoverage decides what "a planned day" means, once.
//
// A day counts as planned when it carries at least one non-filler itinerary
// item, OR a real transport segment departing/arriving on it: travel days ARE
// planned days, and without that an eleven-flight trip would trade one lie
// ("Plan your days" checked with nothing planned) for another ("Day 5 has
// nothing planned" on the day you fly to Kraków). Booking TO-DOS deliberately
// do not count — intending to book transport is not yet a plan for the day, and
// counting them would let the todo list silently satisfy a rung about the
// itinerary.
//
// The span is the WHOLE trip, not the first-to-last scheduled day it used to
// be: that older window made a single dated item enough to declare a 37-day
// trip scheduled, and hid every day past the last one. Undated trips have no
// honest span, so they keep the old min..max window and report no denominator.
//
// PLANNABLE days are the span minus its last day, which is the day you leave —
// there is nothing to plan on it, and flagging it would put a finding on every
// tidy trip in the app. That count is the trip's nights, the unit the rest of
// the app already measures a stay in. A single-day trip keeps its one day.
func walkDayCoverage(d exportData) dayCoverage {
	real := map[int]bool{}
	minDay, maxDay := 0, 0
	mark := func(day int) {
		if day < 1 {
			return
		}
		real[day] = true
		if minDay == 0 || day < minDay {
			minDay = day
		}
		if day > maxDay {
			maxDay = day
		}
	}
	for _, it := range d.Items {
		if it.Day == nil || isCityFiller(it) {
			continue
		}
		mark(int(*it.Day))
	}

	cov := dayCoverage{Total: tripDayCount(d.Trip)}
	if cov.Total > 1 {
		cov.Total-- // drop the departure day
	}
	if cov.Total > 0 && d.Trip.StartDate.Valid {
		start := d.Trip.StartDate.Time
		for _, s := range d.Segments {
			if s.Auto || s.Dismissed {
				continue
			}
			for _, when := range []pgtype.Date{s.DepartDate, s.ArriveDate} {
				if !when.Valid {
					continue
				}
				if day := nightsBetween(start, when.Time) + 1; day <= cov.Total {
					mark(day)
				}
			}
		}
	}

	first, last := 1, cov.Total
	if cov.Total == 0 {
		// Undated: the only span we can speak for is the one the items
		// themselves describe. No items, no runs — same as before.
		if len(real) == 0 {
			return cov
		}
		first, last = minDay, maxDay
	}
	for day := first; day <= last; day++ {
		if real[day] {
			cov.Planned++
			continue
		}
		runStart := day
		for day < last && !real[day+1] {
			day++
		}
		cov.Empty = append(cov.Empty, dayRun{first: runStart, last: day})
	}
	return cov
}

// checkDensity flags days with nothing planned (walkDayCoverage owns what that
// means — whole trip span, city fillers excluded, travel days included) and
// over-packed days (more than 6 items, or two+ items sharing a time_of_day).
// Buckets by absolute day so a day split across hubs still counts once. The
// zero-dated-items early return stands: "no places saved yet" is
// checkUnscheduled's finding to make, and one empty run spanning the whole trip
// would only repeat it.
func checkDensity(locale string, d exportData) []Finding {
	tripID := d.Trip.ID.String()
	buckets := map[int][]store.ItineraryItem{}
	minDay, maxDay := 0, 0
	for _, it := range d.Items {
		if it.Day == nil {
			continue
		}
		day := int(*it.Day)
		buckets[day] = append(buckets[day], it)
		if minDay == 0 || day < minDay {
			minDay = day
		}
		if day > maxDay {
			maxDay = day
		}
	}
	if len(buckets) == 0 {
		return nil
	}
	var out []Finding
	// One finding per empty-day run, anchored on the run's first day (that's
	// where tap-to-scroll lands).
	for _, r := range walkDayCoverage(d).Empty {
		msg := tr(locale, "review.emptyDay", r.first)
		if r.last > r.first {
			msg = tr(locale, "review.emptyDayRange", r.first, r.last)
		}
		dd := r.first
		out = append(out, Finding{
			Severity: "info", Category: "packing", TripID: tripID, Day: &dd,
			Message: msg,
		})
	}
	for day := minDay; day <= maxDay; day++ {
		items := buckets[day]
		if len(items) == 0 {
			continue
		}
		dd := day
		if len(items) > 6 {
			f := Finding{
				Severity: "warn", Category: "packing", TripID: tripID, Day: &dd,
				Message: tr(locale, "review.packedDay", day, len(items)),
			}
			// Offer a one-tap move of the last item in the crowded day to the
			// nearest meaningfully-lighter day — only when both a movable item
			// and a lighter day exist; otherwise stay report-only.
			if target := lighterDay(d, day); target != nil {
				id := items[len(items)-1].ID.String()
				f.Fix = &FindingFix{
					Action: "move_item", Label: tr(locale, "review.fix.moveToDay", *target),
					ItemID: &id, TargetDay: target,
				}
			}
			out = append(out, f)
		}
		todCount := map[string]int{}
		for _, it := range items {
			if t := strings.TrimSpace(strPtrVal(it.TimeOfDay)); t != "" {
				todCount[t]++
			}
		}
		// Fixed order keeps the output deterministic.
		for _, tod := range []string{"morning", "afternoon", "evening"} {
			if todCount[tod] > 1 {
				f := Finding{
					Severity: "warn", Category: "packing", TripID: tripID, Day: &dd,
					Message: tr(locale, "review.timeOfDayCollision", day, todCount[tod], tr(locale, "review.tod."+tod)),
				}
				if target := lighterDay(d, day); target != nil {
					// The last item in that colliding slot is the one to move.
					if id, ok := lastItemInSlot(items, tod); ok {
						f.Fix = &FindingFix{
							Action: "move_item", Label: tr(locale, "review.fix.moveToDay", *target),
							ItemID: &id, TargetDay: target,
						}
					}
				}
				out = append(out, f)
			}
		}
	}
	return out
}

// lighterDay finds the nearest day to fromDay — searching outward (fromDay-1,
// fromDay+1, fromDay-2, …) within the scheduled span — whose item count is at
// least two fewer than fromDay's, so a move meaningfully de-crowds. Returns nil
// when no such day exists (then the finding stays report-only).
func lighterDay(data exportData, fromDay int) *int {
	counts := map[int]int{}
	minDay, maxDay := 0, 0
	for _, it := range data.Items {
		if it.Day == nil {
			continue
		}
		day := int(*it.Day)
		counts[day]++
		if minDay == 0 || day < minDay {
			minDay = day
		}
		if day > maxDay {
			maxDay = day
		}
	}
	fromCount := counts[fromDay]
	for delta := 1; delta <= maxDay-minDay; delta++ {
		for _, cand := range []int{fromDay - delta, fromDay + delta} {
			if cand < minDay || cand > maxDay {
				continue
			}
			if counts[cand] <= fromCount-2 {
				c := cand
				return &c
			}
		}
	}
	return nil
}

// lastItemInSlot returns the ID of the last item scheduled in the given
// time-of-day slot (the one whose move relieves the collision), false if none.
func lastItemInSlot(items []store.ItineraryItem, tod string) (string, bool) {
	id, ok := "", false
	for _, it := range items {
		if strings.TrimSpace(strPtrVal(it.TimeOfDay)) == tod {
			id, ok = it.ID.String(), true
		}
	}
	return id, ok
}

// checkLodging walks each night of a dated trip (start .. end-1, checkout-
// exclusive) and flags each run of consecutive uncovered nights as ONE
// finding whose fix prefills the whole range. Runs split when the hub city
// changes so every "add a stay" spans a single place; a night with no known
// city never forces a split (the run adopts the first known city it sees).
// The dates guard is the only gate (specs/retire-trip-status): an undated
// trip is skipped, and a dated trip without lodging is exactly what this
// check exists to flag.
func checkLodging(locale string, d exportData) []Finding {
	if !d.Trip.StartDate.Valid || !d.Trip.EndDate.Valid {
		return nil
	}
	tripID := d.Trip.ID.String()
	start := d.Trip.StartDate.Time
	nights := nightsBetween(start, d.Trip.EndDate.Time)
	type nightRun struct {
		firstN, lastN int // 0-based night indexes
		city          *string
	}
	var runs []nightRun
	var cur *nightRun
	for n := 0; n < nights; n++ {
		night := start.AddDate(0, 0, n)
		if nightCovered(d.Accommodations, night) {
			cur = nil
			continue
		}
		city := cityForDay(d.Items, n+1)
		switch {
		case cur == nil:
			runs = append(runs, nightRun{n, n, city})
			cur = &runs[len(runs)-1]
		case city == nil || cur.city == nil || strings.EqualFold(*city, *cur.city):
			cur.lastN = n
			if cur.city == nil {
				cur.city = city
			}
		default: // a different known city starts a new per-place run
			runs = append(runs, nightRun{n, n, city})
			cur = &runs[len(runs)-1]
		}
	}
	var out []Finding
	for _, r := range runs {
		day := r.firstN + 1
		firstNight := start.AddDate(0, 0, r.firstN)
		lastNight := start.AddDate(0, 0, r.lastN)
		checkIn := firstNight.Format(dateLayout)
		checkOut := lastNight.AddDate(0, 0, 1).Format(dateLayout)
		msg := tr(locale, "review.noLodging", localizedDate(locale, firstNight, dateStyleWeekdayMonthDay))
		if r.lastN > r.firstN {
			msg = tr(locale, "review.noLodgingRange",
				localizedDate(locale, firstNight, dateStyleWeekdayMonthDay),
				localizedDate(locale, lastNight, dateStyleWeekdayMonthDay),
				r.lastN-r.firstN+1)
		}
		out = append(out, Finding{
			Severity: "warn", Category: "lodging", TripID: tripID, Day: &day,
			Message: msg,
			Fix: &FindingFix{
				Action: "add_lodging", Label: tr(locale, "review.fix.addStay"),
				City:     r.city,
				CheckIn:  &checkIn,
				CheckOut: &checkOut,
			},
		})
	}
	return out
}

// nightCovered reports whether any real (non-auto) accommodation covers the
// given night. Auto drafts are itinerary-derived suggestions, not real
// lodging — counting them as coverage hides genuinely unbooked nights (same
// skip as checkBookings). Shared by checkLodging's night walk and the
// next-step booking-slot walk (trip_next_step.go) so "covered" has one
// definition.
func nightCovered(accs []store.Accommodation, night time.Time) bool {
	for _, a := range accs {
		if a.Auto {
			continue
		}
		if stayCoversNight(a.CheckIn, a.CheckOut, night) {
			return true
		}
	}
	return false
}

// stayCoversNight is the server twin of trip_days.dart's stayCoversDate:
// check-in <= night < check-out (checkout-exclusive). All values are UTC
// midnights, so the comparison is a plain date compare.
func stayCoversNight(checkIn, checkOut pgtype.Date, night time.Time) bool {
	if !checkIn.Valid || !checkOut.Valid {
		return false
	}
	return !night.Before(checkIn.Time) && night.Before(checkOut.Time)
}

// itemHub derives an item's hub city the same way groupExportItems does:
// day_trip_from → city → "" (unknown). Used to prefill the "add a stay" sheet.
func itemHub(it store.ItineraryItem) string {
	hub := strings.TrimSpace(strPtrVal(it.DayTripFrom))
	if hub == "" {
		hub = strings.TrimSpace(strPtrVal(it.City))
	}
	return hub
}

// cityForDay returns the hub city of the first item scheduled on the given day,
// or nil when that day has no item with a real (non-"Itinerary") hub — the add-
// lodging sheet then prefills only the dates.
func cityForDay(items []store.ItineraryItem, day int) *string {
	for _, it := range items {
		if it.Day == nil || int(*it.Day) != day {
			continue
		}
		if hub := itemHub(it); hub != "" && !strings.EqualFold(hub, "Itinerary") {
			return &hub
		}
	}
	return nil
}

// hubFirstDate returns the earliest calendar date of any item whose hub matches,
// so a missing-transport fix can carry the destination leg's date. Not datable
// when the trip is undated or no matching item has a resolvable day.
func hubFirstDate(trip store.Trip, items []store.ItineraryItem, hub string) (time.Time, bool) {
	var best time.Time
	found := false
	for _, it := range items {
		if !strings.EqualFold(itemHub(it), hub) {
			continue
		}
		dt, ok := itemStartDate(trip, it)
		if !ok {
			continue
		}
		if !found || dt.Before(best) {
			best, found = dt, true
		}
	}
	return best, found
}

// checkTransit walks consecutive hub groups; when the hub city changes and no
// segment plausibly connects the two, it flags a missing leg. Conservative on
// purpose — a same-city move or a fuzzy origin/destination match suppresses the
// warning to avoid false positives.
func checkTransit(locale string, d exportData) []Finding {
	groups := groupExportItems(d.Trip, d.Items)
	if len(groups) < 2 {
		return nil
	}
	tripID := d.Trip.ID.String()
	// Same coordinate index the booking-todo sync resolves modes from, so the
	// gap Trip Health reports and the row the page shows agree about how the
	// traveler crosses it — "Add train", not "Add flight", between Rome and
	// Florence.
	legCoords := legCoordIndex(computeTripLegs(d.Trip, d.Items, d.Accommodations))
	var out []Finding
	for i := 1; i < len(groups); i++ {
		from, to := groups[i-1].Hub, groups[i].Hub
		if from == "" || to == "" || from == "Itinerary" || to == "Itinerary" {
			continue
		}
		if strings.EqualFold(from, to) {
			continue
		}
		if segmentConnects(d.Segments, from, to) {
			continue
		}
		origin, dest := from, to
		// One resolution for the whole app (leg_transport_mode.go): a bookable
		// ferry pair, then the trip's stated mode, then geography, then flight.
		// It replaced this function's own ladder, whose Greek test was an OR —
		// Athens → Rome came back a ferry — and whose floor was always flight.
		// There is no per-leg override to pass: a review finding is about a leg
		// with no booking at all.
		mode := resolveLegMode(d.Trip,
			legEndpointFrom(origin, legCoords), legEndpointFrom(dest, legCoords), nil)
		fix := &FindingFix{
			Action: "add_transport", Label: transportFixLabel(locale, mode),
			Origin: &origin, Destination: &dest, Mode: &mode,
		}
		// The leg's date, when derivable, is the destination hub's first day.
		if dt, ok := hubFirstDate(d.Trip, d.Items, groups[i].Hub); ok {
			fix.Date = ptrTo(dt.Format(dateLayout))
		}
		out = append(out, Finding{
			Severity: "warn", Category: "transit", TripID: tripID,
			Message: tr(locale, "review.noTransport", from, to),
			Fix:     fix,
		})
	}
	return out
}

// transportFixLabel maps a RESOLVED transport mode to its add-fix button
// label. Callers resolve the mode first (Greek-leg ferry override, trip
// travel-mode, per-leg override); anything unresolved — flight, "", or an
// unrecognized value — falls to the generic "Add transport" label, which is
// exactly what checkTransit's inline switch produced (it had no flight case
// and 'mixed' never reached it). Shared with the next-step booking-slot walk
// (trip_next_step.go) so mode→label lives in one place.
func transportFixLabel(locale, mode string) string {
	switch mode {
	case "ferry":
		return tr(locale, "review.fix.addFerry")
	case "car":
		return tr(locale, "review.fix.addDrive")
	case "train":
		return tr(locale, "review.fix.addTrain")
	case "bus":
		return tr(locale, "review.fix.addBus")
	}
	return tr(locale, "review.fix.addTransport")
}

// segmentConnects reports whether any segment plausibly links from→to (either
// direction), via case-insensitive substring matching of the hub cities
// against the segment's origin/destination.
func segmentConnects(segs []store.TripSegment, from, to string) bool {
	from, to = strings.ToLower(from), strings.ToLower(to)
	for _, s := range segs {
		o := strings.ToLower(strings.TrimSpace(strPtrVal(s.Origin)))
		dst := strings.ToLower(strings.TrimSpace(strPtrVal(s.Destination)))
		if fuzzyMatch(o, from) && fuzzyMatch(dst, to) {
			return true
		}
		if fuzzyMatch(o, to) && fuzzyMatch(dst, from) {
			return true
		}
	}
	return false
}

// fuzzyMatch is a lenient, non-empty substring match in either direction.
func fuzzyMatch(a, b string) bool {
	if a == "" || b == "" {
		return false
	}
	// Short tokens match whole WORDS, not substrings. A derived home leg's
	// endpoint can now be an IATA code (00064), and a plain substring test lets
	// "alb" claim a confirmed segment to "Albufeira" — which would silently
	// mark the flight out as already booked. Whole-word matching still lets
	// genuinely short city names work ("rio" ↔ "Rio de Janeiro").
	if len(a) <= 3 || len(b) <= 3 {
		return a == b || hasWord(a, b) || hasWord(b, a)
	}
	return strings.Contains(a, b) || strings.Contains(b, a)
}

// hasWord reports whether w appears in s as a whole alphanumeric word, so
// punctuation and separators ("New York, NY") don't hide a match.
func hasWord(s, w string) bool {
	for _, f := range strings.FieldsFunc(s, func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsDigit(r)
	}) {
		if f == w {
			return true
		}
	}
	return false
}

// checkBudget flags a trip whose spending exceeds its target — or, failing
// that, one whose PLAN already does.
//
// At most one budget finding ever fires: two overlapping warnings about the
// same target is noise, and the overspend is strictly the more urgent of the
// two. The second reads `Projected`, not `Planned`: planned ignores purchases
// that never carried a plan and would under-report where the trip is heading.
// It is `info`, not `warn`, because nothing has actually gone wrong yet — this
// is the version of the warning a traveler can still act on.
func checkBudget(locale string, d exportData, budget *BudgetResponse) []Finding {
	if budget == nil {
		return nil
	}
	if budget.Remaining != nil && *budget.Remaining < 0 {
		over := -*budget.Remaining
		return []Finding{{
			Severity: "warn", Category: "budget", TripID: d.Trip.ID.String(),
			Message: tr(locale, "review.overBudget", over, budget.Currency),
			Fix:     &FindingFix{Action: "raise_budget", Label: tr(locale, "review.fix.adjustBudget")},
		}}
	}
	if budget.TargetAmount != nil && budget.Projected > *budget.TargetAmount {
		over := budget.Projected - *budget.TargetAmount
		return []Finding{{
			Severity: "info", Category: "budget", TripID: d.Trip.ID.String(),
			Message: tr(locale, "review.planOverBudget", over, budget.Currency),
			Fix:     &FindingFix{Action: "raise_budget", Label: tr(locale, "review.fix.adjustBudget")},
		}}
	}
	return nil
}

// checkBookings flags each unbooked accommodation and segment at info level —
// a gentle "don't forget to confirm", never critical. Auto rows are system-
// generated "Suggested" drafts that track the itinerary, not commitments the
// traveler made, so they're skipped: nagging "confirm your booking" for a
// suggestion the traveler never chose is noise.
func checkBookings(locale string, d exportData) []Finding {
	tripID := d.Trip.ID.String()
	var out []Finding
	for _, a := range d.Accommodations {
		if a.Booked || a.Auto {
			continue
		}
		id := a.ID.String()
		et := "accommodation"
		out = append(out, Finding{
			Severity: "info", Category: "bookings", TripID: tripID, ItemID: &id,
			Message: tr(locale, "review.confirmBooking", a.Name),
			Fix: &FindingFix{
				Action: "mark_booked", Label: tr(locale, "review.fix.markBooked"), ItemID: &id, EntityType: &et,
			},
		})
	}
	for _, s := range d.Segments {
		if s.Booked || s.Auto {
			continue
		}
		id := s.ID.String()
		et := "segment"
		out = append(out, Finding{
			Severity: "info", Category: "bookings", TripID: tripID, ItemID: &id,
			Message: tr(locale, "review.confirmBooking", segmentRoute(s)),
			Fix: &FindingFix{
				Action: "mark_booked", Label: tr(locale, "review.fix.markBooked"), ItemID: &id, EntityType: &et,
			},
		})
	}
	return out
}

// --- live-lookup enrichment checks (PR3) --------------------------------------

// Weather advisory thresholds. Rain is split by report kind: a forecast carries
// a precipitation probability (flag at ≥60%), while last year's archive gives
// only a mm total (flag at ≥5mm, a solidly wet day). Temperature extremes flag
// off the day's high/low. All weather findings are info-level advice.
const (
	rainProbPct     = 60
	rainHistoricMM  = 5.0
	hotThresholdC   = 34.0
	coldThresholdC  = 0.0
	maxHoursLookups = 30 // cap billable Google detail calls per review
)

// checkWeather adds advisory findings for rainy or temperature-extreme trip
// days, one GetTripWeather lookup per distinct city (keyless, TTL-cached).
// Best-effort: a nil service, an undated trip, or any provider error/empty
// result skips silently — weather never fails or blocks a review.
func checkWeather(ctx context.Context, locale string, d exportData, weather *WeatherService) []Finding {
	if weather == nil || !d.Trip.StartDate.Valid {
		return nil
	}
	tripID := d.Trip.ID.String()

	// Per city, the distinct trip days present (with their calendar dates) and
	// whether each has an outdoor plan the rain would actually spoil.
	type dayInfo struct {
		date    time.Time
		outdoor bool
	}
	cityDays := map[string]map[int]*dayInfo{}
	var order []string // deterministic city iteration
	for _, it := range d.Items {
		city := strings.TrimSpace(strPtrVal(it.City))
		if city == "" || it.Day == nil {
			continue
		}
		date, ok := itemStartDate(d.Trip, it)
		if !ok {
			continue
		}
		days, seen := cityDays[city]
		if !seen {
			days = map[int]*dayInfo{}
			cityDays[city] = days
			order = append(order, city)
		}
		day := int(*it.Day)
		di := days[day]
		if di == nil {
			di = &dayInfo{date: date}
			days[day] = di
		}
		if isOutdoorItem(it) {
			di.outdoor = true
		}
	}

	// cityFindings is checkWeather's per-city body: one GetTripWeather lookup
	// spanning the city's trip days, matched back day-by-day. Returns nil on
	// any provider error or empty report (best-effort, as before).
	cityFindings := func(city string, days map[int]*dayInfo) []Finding {
		var out []Finding
		var first, last time.Time
		for _, di := range days {
			if first.IsZero() || di.date.Before(first) {
				first = di.date
			}
			if di.date.After(last) {
				last = di.date
			}
		}
		report, err := weather.GetTripWeather(ctx, city, first.Format(dateLayout), last.Format(dateLayout))
		if err != nil || len(report.Days) == 0 {
			return nil // best-effort
		}
		// Index the report by day. A forecast carries real (this-year) dates —
		// match exact. The archive fallback carries LAST year's dates for the
		// same days, so match on month-day only (MM-DD suffix).
		historical := report.Kind == "historical"
		byKey := make(map[string]WeatherDay, len(report.Days))
		for _, wd := range report.Days {
			byKey[weatherDayKey(wd.Date, historical)] = wd
		}
		for day, di := range days {
			var lookup string
			if historical {
				lookup = di.date.Format("01-02")
			} else {
				lookup = di.date.Format(dateLayout)
			}
			wd, ok := byKey[lookup]
			if !ok {
				continue
			}
			dd := day
			if di.outdoor && weatherDayRainy(wd) {
				out = append(out, Finding{
					Severity: "info", Category: "weather", TripID: tripID, Day: &dd,
					Message: tr(locale, "review.rainLikely", day, city),
					Fix: &FindingFix{
						Action: "add_packing", Label: tr(locale, "review.fix.addUmbrella"),
						PackingItem: ptrTo("Umbrella"), PackingCategory: ptrTo("general"),
					},
				})
			}
			switch {
			case wd.TempMaxC >= hotThresholdC:
				out = append(out, Finding{
					Severity: "info", Category: "weather", TripID: tripID, Day: &dd,
					Message: tr(locale, "review.veryHot", day, city, wd.TempMaxC),
					Fix: &FindingFix{
						Action: "add_packing", Label: tr(locale, "review.fix.addSunProtection"),
						PackingItem: ptrTo("Sunscreen"), PackingCategory: ptrTo("health"),
					},
				})
			case wd.TempMinC <= coldThresholdC:
				out = append(out, Finding{
					Severity: "info", Category: "weather", TripID: tripID, Day: &dd,
					Message: tr(locale, "review.veryCold", day, city, wd.TempMinC),
					Fix: &FindingFix{
						Action: "add_packing", Label: tr(locale, "review.fix.addWarmLayers"),
						PackingItem: ptrTo("Warm layers"), PackingCategory: ptrTo("clothing"),
					},
				})
			}
		}
		return out
	}

	// One lookup per city, fanned out with a small concurrency cap (the
	// service is TTL-cached and keyless, but stay polite). Findings order is
	// user-visible, so each city's findings land in the slot indexed by its
	// position in `order` and are appended in order after Wait. Best-effort
	// semantics are unchanged: the goroutines always return nil, so a
	// per-city provider error skips that city, never fails the review.
	perCity := make([][]Finding, len(order))
	var g errgroup.Group
	g.SetLimit(4)
	for i, city := range order {
		i, city := i, city
		days := cityDays[city]
		g.Go(func() error {
			perCity[i] = cityFindings(city, days)
			return nil
		})
	}
	_ = g.Wait() // never errors; Wait just joins the goroutines
	var out []Finding
	for _, findings := range perCity {
		out = append(out, findings...)
	}
	return out
}

// weatherDayKey normalizes a report day's date to the map key used to align it
// with a trip day: the full YYYY-MM-DD for a forecast, or the MM-DD suffix for
// the archive (whose dates are last year's for the same calendar days).
func weatherDayKey(date string, historical bool) string {
	if historical && len(date) >= 10 {
		return date[5:]
	}
	return date
}

// weatherDayRainy reports a meaningfully wet day: a high forecast probability,
// or (archive, no probability) a solid rainfall total.
func weatherDayRainy(wd WeatherDay) bool {
	if wd.PrecipPct != nil {
		return *wd.PrecipPct >= rainProbPct
	}
	return wd.PrecipMM >= rainHistoricMM
}

// indoorCategories are the item categories rain doesn't disrupt; everything
// else (attractions, parks, tours, or an untagged item) counts as outdoor for
// the umbrella advisory.
var indoorCategories = map[string]bool{
	"restaurant":  true,
	"coffee_shop": true,
	"cafe":        true,
	"museum":      true,
	"shopping":    true,
	"bar":         true,
}

func isOutdoorItem(it store.ItineraryItem) bool {
	cat := strings.ToLower(strings.TrimSpace(strPtrVal(it.Category)))
	return !indoorCategories[cat]
}

// checkHours flags saved places that may be closed on the trip day they're
// scheduled. Opt-in (billable Google detail calls): for each item with a
// place_id and a resolvable trip-day weekday, it fetches 24h-cached place
// details, converts the opening hours, and warns when the place is closed that
// weekday. Bounded to maxHoursLookups upstream fetches per review. Best-effort:
// a nil service, a Places error, or unresolvable hours skips that item.
func checkHours(ctx context.Context, locale string, d exportData, places *GooglePlacesService) []Finding {
	if places == nil {
		return nil
	}
	tripID := d.Trip.ID.String()
	th := &TimeHelper{}
	var out []Finding
	lookups := 0
	for _, it := range d.Items {
		placeID := strings.TrimSpace(strPtrVal(it.PlaceID))
		if placeID == "" {
			continue
		}
		date, ok := itemStartDate(d.Trip, it)
		if !ok {
			continue // no trip-day weekday to check against
		}
		if lookups >= maxHoursLookups {
			ctxLog(ctx).Info("trip review hours check hit lookup cap",
				"trip_id", tripID, "cap", maxHoursLookups)
			break
		}
		lookups++
		details, err := places.GetPlaceDetails(ctx, placeID)
		if err != nil || details == nil || details.OpeningHours == nil {
			continue // best-effort
		}
		hours := ConvertGoogleHoursToOperatingHours(details.OpeningHours)
		if hours == nil {
			continue
		}
		weekday := date.Weekday()
		hoursStr := strings.TrimSpace(th.getHoursForDay(hours, weekday))
		if hoursStr == "" {
			continue // no hours known for that weekday → don't guess
		}
		// Only flag a weekday Google explicitly marks "closed" — the reliable
		// all-day-closed signal. We deliberately don't probe a clock time:
		// ConvertGoogleHoursToOperatingHours is lossy on AM/PM, so an
		// evening-only venue must not read as "closed".
		if _, _, _, _, isClosed, perr := th.parseOperatingHours(hoursStr); perr != nil || !isClosed {
			continue
		}
		day := int(*it.Day)
		id := it.ID.String()
		out = append(out, Finding{
			Severity: "warn", Category: "hours", TripID: tripID, Day: &day, ItemID: &id,
			Message: tr(locale, "review.mayBeClosed", it.Name, localizedWeekday(locale, weekday), day),
			// No cheap "open on day N" signal here (we only fetched this item's
			// hours), so the client opens an editor — TargetDay stays nil.
			Fix: &FindingFix{Action: "move_item", Label: tr(locale, "review.fix.reschedule"), ItemID: &id},
		})
	}
	return out
}
