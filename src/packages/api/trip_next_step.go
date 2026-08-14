package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// trip_next_step.go — the "Next Step" projection (specs/next-step-cta): the
// single recommended next planning action for a trip, derived as the FIRST
// unmet phase of a fixed ladder (dates → itinerary → booking slots in
// itinerary order → schedule → bookings → packing). Like trip_review.go it is
// DETERMINISTIC and read-only: derived only from persisted data and the
// deterministic findings, never from the live weather/hours enrichment — so
// the step is identical whether or not the caller opted into check_hours, and
// both client cache variants agree.
//
// deriveNextStep is composed AFTER reviewTrip at both call sites (the review
// handler and the review_trip agent tool); phase 3 walks the client-synced
// booking todos in position order (flights before stays, per destination —
// see nextOpenBookingSlot), falling back to the lodging/transit findings only
// for trips with no derived slots, and reads the extra signals (zero items,
// unbooked booking todos, empty packing checklist) straight off exportData.
// Budget, weather and opening hours are deliberately NOT phases: a budget
// target is optional, and the live enrichments would make the step flap
// between fetches.

// NextStep is the first unmet phase of the planning ladder. Title/Detail are
// localized display copy; SeedPrompt is CANONICAL ENGLISH (specs/i18n-spanish:
// it is agent input, not display copy — the client shows Title instead, and
// the templates live here as English constants precisely so nobody localizes
// them). Fix reuses the finding-fix contract so the client's existing
// apply-fix plumbing handles the mechanical path without new action types.
type NextStep struct {
	// Kind names the phase; the vocabulary is unchanged from the 7-phase
	// ladder (no client migration): add_lodging/add_transport are now emitted
	// both by the phase-3 booking-slot walk and by its findings fallback.
	Kind       string      `json:"kind"` // set_dates|plan_itinerary|add_lodging|add_transport|schedule_items|book_trip|add_packing|all_set
	Title      string      `json:"title"`
	Detail     string      `json:"detail,omitempty"`
	Day        *int        `json:"day,omitempty"`   // scroll anchor, same convention as Finding.Day
	Count      *int        `json:"count,omitempty"` // items behind the step: unscheduled places, unbooked rows
	Fix        *FindingFix `json:"fix,omitempty"`
	SeedPrompt string      `json:"seed_prompt,omitempty"`
}

// PlanProgress is prefix progress through the ladder: Done phases are complete
// from the top, so the current step is phase Done+1 and all_set reports 6/6.
// Total is a field (not a client-side constant) so the ladder can grow or
// shrink (it did: 7 → 6 when lodging+transport merged into the booking-slot
// walk) without a lockstep client release.
type PlanProgress struct {
	Done  int `json:"done"`
	Total int `json:"total"`
}

const planLadderTotal = 6

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

	// Phase 3 — booking slots in itinerary order (Brian, 2026-08-14; decision
	// record in specs/next-step-cta/plan.md). The old ladder ran all lodging
	// findings before all transit findings, so the card said "book a stay"
	// while the outbound flight was still unbooked; guidance now follows the
	// trip instead: walk the client-synced derived booking todos (position
	// ASC = outbound leg, stay 1, leg 1→2, stay 2, …, return leg — the
	// client's _deriveTodos order) and surface the first OPEN slot, flights
	// before stays, per destination. Open = unbooked and not claimed by a
	// matching server row (bookingSlotClaimed). Trips with no derived slots
	// (import/MCP/agent-created, never opened in the app) fall back to the
	// old findings behavior in this same progress slot. What a slot DOES
	// cover, the walk answers alone: a checked checkbox with no
	// accommodation/segment row is complete by design — the traveler's
	// booked-elsewhere assertion — and never re-raised from the findings
	// (Trip Health keeps full fidelity on the same gap). The one thing a
	// satisfied walk still defers to the findings is a night no slot spans
	// at all; see below.
	if slot, walked := nextOpenBookingSlot(data); walked {
		if slot != nil {
			return bookingSlotStep(locale, data, *slot), progress(2)
		}
		// The walk is satisfied — but it can only speak for nights some slot
		// actually spans. A leg range ends at its last scheduled item, so
		// trailing nights of a trip can belong to NO slot: nobody ever asked
		// about them, which is the opposite of "booked elsewhere". Surface
		// those (and only those) from the lodging findings, so "You're all
		// set" can never contradict the health sheet.
		if f := firstUnslottedLodging(data, findings); f != nil {
			return &NextStep{
				Kind:       "add_lodging",
				Title:      tr(locale, "review.next.addLodging.title"),
				Detail:     f.Message,
				Day:        f.Day,
				Fix:        f.Fix,
				SeedPrompt: seedAddLodging(data, f.Fix),
			}, progress(2)
		}
	} else {
		// Findings fallback (first = earliest day thanks to reviewTrip's
		// stable sort). The finding's Fix rides along verbatim so the health
		// sheet's one-tap path stays available for the same gap. Both kinds
		// share phase 3's progress slot.
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
			}, progress(2)
		}
	}

	// Phase 4 — schedule cleanup: leftover unscheduled places and empty days.
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
		return step, progress(3)
	}

	// Phase 5 — book everything still open.
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
		}, progress(4)
	}

	// Phase 6 — packing, only while the trip is still ahead: mid-trip the
	// checklist nag is noise, but booking tonight's hotel above never was.
	if len(data.Checklist) == 0 && today.Before(data.Trip.StartDate.Time) {
		return &NextStep{
			Kind:       "add_packing",
			Title:      tr(locale, "review.next.packing.title"),
			Detail:     tr(locale, "review.next.packing.detail"),
			SeedPrompt: seedAddPacking(data),
		}, progress(5)
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

// --- phase 3: the booking-slot walk -------------------------------------------
//
// The client's _deriveTodos (trip_detail_screen.dart) is the ONE existing
// implementation of "the trip's booking slots in itinerary order"; the walk
// deliberately consumes its synced output instead of re-deriving legs from
// items. Its conventions, established by the sync contract: derived rows are
// auto=true with todo_key "stay:<label.lower>" / "transport:<o.lower>>><d.lower>",
// titled "Stay in <Label>" / "<Origin> → <Destination>". Origin/destination
// are never persisted as columns (booking_todo_handler.go,
// PatchBookingTodoRequest doc), so the title is the only place the original
// casing survives — the client itself re-parses titles the same way in
// _addDetailsFromTodo, and legEndpoints below makes the server the third
// reader of that convention (pinned by TestNextStep_WalkFlightBeforeStay's
// cased-endpoint assertions).

// nextOpenBookingSlot walks d.BookingTodos in slice order — position ASC from
// ListBookingTodosByTrip, i.e. the client's itinerary order (outbound leg,
// stay 1, leg 1→2, stay 2, …, return leg) — and returns the first OPEN
// derived slot. Only derived slots participate, recognized by the todo_key
// prefix ("stay:"/"transport:"); custom:* rows and any other keys are not
// slots — they surface in the book_trip aggregate instead. Open means
// !Booked && !bookingSlotClaimed. walked=false ⇔ the trip has zero derived
// slots (import/MCP/agent-created trips never opened in the app), which sends
// deriveNextStep to the findings fallback; (nil, true) means every slot is
// closed and phase 3 is satisfied.
func nextOpenBookingSlot(d exportData) (*store.BookingTodo, bool) {
	walked := false
	for i := range d.BookingTodos {
		t := &d.BookingTodos[i]
		if !strings.HasPrefix(t.TodoKey, "stay:") && !strings.HasPrefix(t.TodoKey, "transport:") {
			continue
		}
		walked = true
		if t.Booked || bookingSlotClaimed(d, *t) {
			continue
		}
		return t, true
	}
	return nil, walked
}

// bookingSlotClaimed is the walk's claim test — a date-aware upgrade of
// todoClaimed. A fully-dated stay slot is claimed only when EVERY night in
// [depart, return) passes nightCovered: precise, so partial coverage keeps
// the slot open where todoClaimed's fuzzy city match would have called one
// covered night "done" (a zero-night from >= to range is vacuously claimed).
// Undated/half-dated stays and ALL transport slots delegate to todoClaimed so
// there is one claim vocabulary, not two. The transport arm therefore counts
// only non-auto segments — drafts are suggestions, not commitments —
// deliberately stricter than checkTransit, which suppresses its finding on
// auto drafts too (pinned by TestNextStep_WalkTransportClaims).
func bookingSlotClaimed(d exportData, t store.BookingTodo) bool {
	if strings.HasPrefix(t.TodoKey, "stay:") && t.DepartDate.Valid && t.ReturnDate.Valid {
		return stayNightsCovered(d.Accommodations, t.DepartDate.Time, t.ReturnDate.Time)
	}
	return todoClaimed(d, t)
}

// stayNightsCovered reports whether every night in [from, to) — checkout-
// exclusive, matching stayCoversNight — has a real (non-auto) stay covering
// it. Vacuously true when from >= to.
func stayNightsCovered(accs []store.Accommodation, from, to time.Time) bool {
	for night := from; night.Before(to); night = night.AddDate(0, 0, 1) {
		if !nightCovered(accs, night) {
			return false
		}
	}
	return true
}

// slotSpansNight reports whether some derived stay slot spans this night —
// i.e. whether the walk has an opinion about it at all. Checkout-exclusive,
// the same convention as stayCoversNight.
func slotSpansNight(todos []store.BookingTodo, night time.Time) bool {
	for _, t := range todos {
		if !strings.HasPrefix(t.TodoKey, "stay:") || !t.DepartDate.Valid || !t.ReturnDate.Valid {
			continue
		}
		if !night.Before(t.DepartDate.Time) && night.Before(t.ReturnDate.Time) {
			return true
		}
	}
	return false
}

// firstUnslottedLodging returns the first lodging finding covering at least
// one night NO stay slot spans. Nights a slot does span belong to the walk —
// a checked slot there is the traveler's booked-elsewhere assertion and must
// not be re-raised — so only the unrepresented ones fall through. The finding
// carries its own night range on the fix (checkLodging fills check_in /
// check_out), which is what makes this a range test and not a day guess.
func firstUnslottedLodging(d exportData, findings []Finding) *Finding {
	for i := range findings {
		f := &findings[i]
		if f.Category != "lodging" || f.Fix == nil || f.Fix.CheckIn == nil || f.Fix.CheckOut == nil {
			continue
		}
		from, err := time.Parse(dateLayout, *f.Fix.CheckIn)
		if err != nil {
			continue
		}
		to, err := time.Parse(dateLayout, *f.Fix.CheckOut)
		if err != nil {
			continue
		}
		for night := from; night.Before(to); night = night.AddDate(0, 0, 1) {
			if !slotSpansNight(d.BookingTodos, night) {
				return f
			}
		}
	}
	return nil
}

// bookingSlotStep renders the walk's winning slot as a NextStep, dispatching
// on the todo_key PREFIX — the same field nextOpenBookingSlot filtered on, so
// the filter and this branch structurally cannot disagree (Kind is a separate
// client-supplied column that could in principle drift from the key).
func bookingSlotStep(locale string, d exportData, t store.BookingTodo) *NextStep {
	if strings.HasPrefix(t.TodoKey, "transport:") {
		return transportSlotStep(locale, d, t)
	}
	return staySlotStep(locale, d, t)
}

// legEndpoints extracts a transport slot's origin/destination, preferring the
// title ("<Origin> → <Destination>", the only survivor of the client's
// casing — see the section comment above) and falling back to the todo_key
// "transport:<o>>><d>" parse todoClaimed uses (lowercase). ok=false when both
// fail (a hand-renamed title over an unparseable key); the step then keeps
// the generic endpoint-less copy.
func legEndpoints(t store.BookingTodo) (origin, dest string, ok bool) {
	if o, d, found := strings.Cut(t.Title, " → "); found {
		if o, d = strings.TrimSpace(o), strings.TrimSpace(d); namesAPlace(o) && namesAPlace(d) {
			return o, d, true
		}
	}
	if key := strings.TrimPrefix(t.TodoKey, "transport:"); key != t.TodoKey {
		if o, d, found := strings.Cut(key, ">>"); found {
			if o, d = strings.TrimSpace(o), strings.TrimSpace(d); namesAPlace(o) && namesAPlace(d) {
				return o, d, true
			}
		}
	}
	return "", "", false
}

// namesAPlace rejects the empty string and the two grouping placeholders that
// stand in for "we could not resolve a city": the server's own "Itinerary"
// hub and the client's kOtherPlacesLabel (trip_legs.dart — documented as
// never translated, because screens localize it at render time). Neither is
// somewhere a traveler can sleep or fly to, so a slot naming one keeps the
// generic copy and an endpoint-less fix — the same silence checkLodging and
// checkTransit keep for a hubless group, and it also keeps the placeholder
// out of the canonical-English seed, where it would send the agent hunting
// for hotels in a city called "Other places".
func namesAPlace(s string) bool {
	return s != "" && !strings.EqualFold(s, "Itinerary") && !strings.EqualFold(s, "Other places")
}

// staySlotCity extracts a stay slot's city: the "Stay in <Label>" title keeps
// the client's casing; the "stay:<label>" key suffix (lowercase) is the
// fallback for hand-renamed titles; "" when neither yields one (the step then
// keeps the generic addLodging title).
func staySlotCity(t store.BookingTodo) string {
	if c := strings.TrimPrefix(t.Title, "Stay in "); c != t.Title {
		if c = strings.TrimSpace(c); namesAPlace(c) {
			return c
		}
	}
	if c := strings.TrimPrefix(t.TodoKey, "stay:"); c != t.TodoKey {
		if c = strings.TrimSpace(c); namesAPlace(c) {
			return c
		}
	}
	return ""
}

// stayCitySet is the lowercase set of the trip's stay-slot cities (the
// "stay:" key suffixes). A transport destination outside the set is a home
// leg — nowhere on the trip to stay there means the traveler is heading
// home — which picks the "…Home" title variant. An EMPTY set never reads as
// home: with no stays at all, every destination would be "outside the set"
// and a one-way trip's only leg would absurdly say "book your flight home".
func stayCitySet(todos []store.BookingTodo) map[string]bool {
	set := map[string]bool{}
	for _, t := range todos {
		if c := strings.TrimPrefix(t.TodoKey, "stay:"); c != t.TodoKey && c != "" {
			set[strings.ToLower(c)] = true
		}
	}
	return set
}

// transportSlotMode resolves a transport slot's mode for copy and fix: the
// per-leg override (todo.mode, validated against allowedLegModes) wins; else
// the provider the sync stored implies it (google_flights → flight, ferry →
// ferry, rome2rio → the trip's ground travel mode when it names a concrete
// one — rome2rio alone can't distinguish car/train/bus); nil when nothing
// concrete is known, and the step then uses the generic copy with a mode-less
// fix.
func transportSlotMode(trip store.Trip, t store.BookingTodo) *string {
	if m := strings.TrimSpace(strPtrVal(t.Mode)); m != "" && allowedLegModes[m] {
		return &m
	}
	switch strPtrVal(t.Provider) {
	case "google_flights":
		return ptrTo("flight")
	case "ferry":
		return ptrTo("ferry")
	case "rome2rio":
		if tm := trip.TravelMode; tm != nil {
			switch *tm {
			case "car", "train", "bus":
				return ptrTo(*tm)
			}
		}
	}
	return nil
}

// slotDay converts a slot's depart date to the trip-day scroll anchor
// (depart − trip start + 1; pgtype dates are UTC midnights so the math is
// exact). nil when the slot is undated OR the result falls outside
// [1, tripDayCount]: todos re-sync only when the trip screen loads, so a
// stale slot left over from before a date shift must not scroll the client
// to a nonexistent day.
func slotDay(trip store.Trip, depart pgtype.Date) *int {
	if !depart.Valid || !trip.StartDate.Valid {
		return nil
	}
	day := nightsBetween(trip.StartDate.Time, depart.Time) + 1
	if day < 1 || day > tripDayCount(trip) {
		return nil
	}
	return &day
}

// transportSlotStep renders an open transport slot. Copy is mode-aware
// (flight and ferry get their own verb; ground/unknown modes stay generic)
// and home-aware (stayCitySet). The Fix mirrors what a transit finding's fix
// carries — same action, mode-resolved label, cased endpoints, leg date — so
// the client's existing apply-fix plumbing works unchanged, and the seed goes
// through the same seedAddTransport template (which handles the endpoint-less
// fix with its "between my cities" fallback).
func transportSlotStep(locale string, d exportData, t store.BookingTodo) *NextStep {
	origin, dest, ok := legEndpoints(t)
	mode := transportSlotMode(d.Trip, t)
	set := stayCitySet(d.BookingTodos)
	home := ok && len(set) > 0 && !set[strings.ToLower(dest)]

	modeKey := "generic"
	switch strPtrVal(mode) {
	case "flight":
		modeKey = "flight"
	case "ferry":
		modeKey = "ferry"
	}
	var title string
	switch {
	case !ok:
		title = tr(locale, "review.next.addTransport.title")
	case home:
		title = tr(locale, "review.next.bookTransport."+modeKey+"Home")
	default:
		title = tr(locale, "review.next.bookTransport."+modeKey, dest)
	}

	detail := ""
	if t.DepartDate.Valid {
		// The title-convention leg name plus the localized date; the todo
		// title is exactly the "<Origin> → <Destination>" route label.
		detail = tr(locale, "review.next.bookTransport.detail", t.Title,
			localizedDate(locale, t.DepartDate.Time, dateStyleWeekdayMonthDay))
	} else if t.Title != "" {
		detail = t.Title
	}

	fix := &FindingFix{
		Action: "add_transport",
		Label:  transportFixLabel(locale, strPtrVal(mode)),
		Mode:   mode,
	}
	if ok {
		fix.Origin, fix.Destination = &origin, &dest
	}
	if t.DepartDate.Valid {
		fix.Date = ptrTo(t.DepartDate.Time.Format(dateLayout))
	}
	return &NextStep{
		Kind:       "add_transport",
		Title:      title,
		Detail:     detail,
		Day:        slotDay(d.Trip, t.DepartDate),
		Fix:        fix,
		SeedPrompt: seedAddTransport(d, fix),
	}
}

// staySlotStep renders an open stay slot. The detail reuses the exact
// review.noLodging(Range) copy for the slot's own night range so the card and
// the health sheet keep one voice, and the Fix mirrors a lodging finding's
// fix (city + check-in/out prefills for the add-a-stay sheet), feeding the
// same seedAddLodging template.
func staySlotStep(locale string, d exportData, t store.BookingTodo) *NextStep {
	city := staySlotCity(t)
	title := tr(locale, "review.next.addLodging.title")
	if city != "" {
		title = tr(locale, "review.next.bookStay.title", city)
	}
	detail := ""
	if t.DepartDate.Valid && t.ReturnDate.Valid {
		nights := nightsBetween(t.DepartDate.Time, t.ReturnDate.Time)
		switch {
		case nights == 1:
			detail = tr(locale, "review.noLodging",
				localizedDate(locale, t.DepartDate.Time, dateStyleWeekdayMonthDay))
		case nights > 1:
			// Last NIGHT, not the checkout date — same convention as
			// checkLodging's range message.
			detail = tr(locale, "review.noLodgingRange",
				localizedDate(locale, t.DepartDate.Time, dateStyleWeekdayMonthDay),
				localizedDate(locale, t.ReturnDate.Time.AddDate(0, 0, -1), dateStyleWeekdayMonthDay),
				nights)
		}
	}
	fix := &FindingFix{Action: "add_lodging", Label: tr(locale, "review.fix.addStay")}
	if city != "" {
		fix.City = &city
	}
	if t.DepartDate.Valid && t.ReturnDate.Valid {
		fix.CheckIn = ptrTo(t.DepartDate.Time.Format(dateLayout))
		fix.CheckOut = ptrTo(t.ReturnDate.Time.Format(dateLayout))
	}
	return &NextStep{
		Kind:       "add_lodging",
		Title:      title,
		Detail:     detail,
		Day:        slotDay(d.Trip, t.DepartDate),
		Fix:        fix,
		SeedPrompt: seedAddLodging(d, fix),
	}
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
