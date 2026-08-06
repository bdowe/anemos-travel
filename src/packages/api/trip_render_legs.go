package main

// The ONE trip-legs derivation (specs/trip-dates-truth, stage 0b): the city
// legs a trip renders, with the calendar span each occupies. This module is
// the server-canonical twin of the client's utils/leg_ranges.dart +
// utils/trip_legs.dart pair, built to back the `legs` payload
// (specs/server-leg-dates) and, later, server-derived booking todos and the
// item_date storage flip. Its fixtures are hand-mirrored 1:1 with
// test/leg_ranges_test.dart (the calendar-parity convention) — change either
// side and you must change both.
//
// Reconciled rules (each was a documented divergence between the old Dart
// and Go derivations; decisions recorded in specs/server-leg-dates/plan.md):
//   - grouping: DART rule — a null/empty hub is its own run and groups with
//     adjacent hubless items; revisited cities stay separate runs keyed
//     "City", "City#2", …; NO address parsing (day_trip_from ?? city only —
//     the client's cityFromAddress fallback retires at cutover).
//   - stay matching: GO rule — fuzzy address, then NAME fallback, so
//     agent-added address-less stays ("Stay in Los Angeles") anchor their
//     leg.
//   - span precedence: confirmed stay > item days > weighted auto-allocation
//     (the Dart-only _allocateDays fallback, ported) > none.
//   - first-leg anchor: the first leg WITH a span, when that span is
//     item-derived, pulls its start back to the trip start.
//   - arrival chain + zero-night collapse: GO rule — legs without a span are
//     skipped and never reset the chain.
//
// Not yet wired to any consumer — stage 1a/1b repoint the payload and the
// existing plan_leg_dates.go summaries onto this module.

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"travel-route-planner/store"
)

// otherPlacesLabel is the canonical key/label for legs whose locality can't
// be resolved — the client's kOtherPlacesLabel. It keys collapse/header
// registries and is NEVER localized server-side; screens map it to a display
// label at render time.
const otherPlacesLabel = "Other places"

// RenderLeg is one city leg as the trip page renders it. Start/End are civil
// dates (UTC midnights); nil when the leg has no calendar span. DateSource
// says which rule produced the span: "stay", "items", "auto", or "" (none).
type RenderLeg struct {
	Key         string     `json:"key"`
	Label       string     `json:"label"`
	Hub         *string    `json:"hub"`
	Start       *time.Time `json:"start_date"`
	End         *time.Time `json:"end_date"`
	DateSource  string     `json:"date_source"`
	ZeroNight   bool       `json:"zero_night"`
	FirstPos    int32      `json:"first_position"`
	LastPos     int32      `json:"last_position"`
	Lat         *float64   `json:"lat"`
	Lng         *float64   `json:"lng"`
	itemDays    []int32    // dated items' day numbers, derivation-internal
	stayMatched bool       // span came from a confirmed stay
}

// renderHubOf resolves the locality an item groups under: its day-trip hub
// when set, else its own city. No address parsing — the server never
// second-guesses missing tags (decision: specs/server-leg-dates).
func renderHubOf(it store.ItineraryItem) string {
	if h := strings.TrimSpace(strPtrVal(it.DayTripFrom)); h != "" {
		return h
	}
	return strings.TrimSpace(strPtrVal(it.City))
}

// computeTripLegs derives the trip's rendered city legs. Items must be in
// position order (GetItineraryItemsByTrip's order).
func computeTripLegs(trip store.Trip, items []store.ItineraryItem, stays []store.Accommodation) []RenderLeg {
	if len(items) == 0 {
		return nil
	}

	// 1. Group into runs: split when the hub changes (Dart tripLegs rule —
	// hubless items form their own runs with hubless neighbors).
	type run struct {
		hub      string
		items    []store.ItineraryItem
		firstPos int32
		lastPos  int32
	}
	var runs []run
	for _, it := range items {
		hub := renderHubOf(it)
		if len(runs) == 0 || !strings.EqualFold(runs[len(runs)-1].hub, hub) {
			runs = append(runs, run{hub: hub, firstPos: it.Position})
		}
		cur := &runs[len(runs)-1]
		cur.items = append(cur.items, it)
		cur.lastPos = it.Position
	}

	// Run keys: revisited labels get #2, #3, … suffixes (client convention —
	// collapse-state and header keys are per-run).
	seen := map[string]int{}
	legs := make([]RenderLeg, 0, len(runs))
	for _, r := range runs {
		label := r.hub
		if label == "" {
			label = otherPlacesLabel
		}
		seen[strings.ToLower(label)]++
		key := label
		if n := seen[strings.ToLower(label)]; n > 1 {
			key = fmt.Sprintf("%s#%d", label, n)
		}
		leg := RenderLeg{Key: key, Label: label, FirstPos: r.firstPos, LastPos: r.lastPos}
		if r.hub != "" {
			hub := r.hub
			leg.Hub = &hub
		}
		for _, it := range r.items {
			if it.Day != nil && *it.Day >= 1 {
				leg.itemDays = append(leg.itemDays, *it.Day)
			}
			// Representative coordinate: the first item with real coords —
			// (0,0) is the "no location" sentinel for manually-added places.
			if leg.Lat == nil && (it.Latitude != 0 || it.Longitude != 0) {
				lat, lng := it.Latitude, it.Longitude
				leg.Lat, leg.Lng = &lat, &lng
			}
		}
		legs = append(legs, leg)
	}

	// 2. Auto-allocation lattice: a weighted contiguous slice of the whole
	// trip span per leg, used only as the per-leg third fallback below.
	var autoStart, autoEnd []time.Time
	haveAuto := false
	if trip.StartDate.Valid && trip.EndDate.Valid && !trip.EndDate.Time.Before(trip.StartDate.Time) {
		start, end := trip.StartDate.Time, trip.EndDate.Time
		totalDays := int(end.Sub(start).Hours()/24) + 1
		n := len(legs)
		autoStart = make([]time.Time, n)
		autoEnd = make([]time.Time, n)
		haveAuto = true
		if n <= totalDays {
			weights := make([]int, n)
			for i, r := range runs {
				weights[i] = len(r.items)
			}
			counts := allocateLegDays(totalDays, weights)
			cursor := start
			for i := 0; i < n; i++ {
				rStart := cursor
				if rStart.After(end) {
					rStart = end
				}
				rEnd := rStart.AddDate(0, 0, counts[i]-1)
				if rEnd.After(end) {
					rEnd = end
				}
				autoStart[i], autoEnd[i] = rStart, rEnd
				cursor = rEnd.AddDate(0, 0, 1)
			}
		} else {
			// More locations than days: one ascending day each.
			for i := 0; i < n; i++ {
				off := i * totalDays / n
				if off > totalDays-1 {
					off = totalDays - 1
				}
				d := start.AddDate(0, 0, off)
				autoStart[i], autoEnd[i] = d, d
			}
		}
	}

	// 3. Per-leg own span: stay > item days > auto slice > none.
	tripStart := trip.StartDate.Time
	for i := range legs {
		leg := &legs[i]
		hubLower := strings.ToLower(strPtrVal(leg.Hub))
		if hubLower != "" {
			if a := firstConfirmedStayForHub(stays, hubLower); a != nil {
				s, e := a.CheckIn.Time, a.CheckOut.Time
				leg.Start, leg.End = &s, &e
				leg.DateSource = "stay"
				leg.stayMatched = true
				continue
			}
		}
		if len(leg.itemDays) > 0 && trip.StartDate.Valid {
			lo, hi := leg.itemDays[0], leg.itemDays[0]
			for _, d := range leg.itemDays[1:] {
				if d < lo {
					lo = d
				}
				if d > hi {
					hi = d
				}
			}
			s := tripStart.AddDate(0, 0, int(lo)-1)
			e := tripStart.AddDate(0, 0, int(hi)-1)
			leg.Start, leg.End = &s, &e
			leg.DateSource = "items"
			continue
		}
		if haveAuto {
			s, e := autoStart[i], autoEnd[i]
			leg.Start, leg.End = &s, &e
			leg.DateSource = "auto"
		}
	}

	// 4. First-leg anchor: the first leg WITH a span, when item-derived,
	// starts at the trip start — the traveler is in the first city from the
	// trip's first day; a single late item must not read as a late arrival.
	if trip.StartDate.Valid {
		for i := range legs {
			if legs[i].Start == nil {
				continue
			}
			if legs[i].DateSource == "items" && tripStart.Before(*legs[i].Start) {
				s := tripStart
				legs[i].Start = &s
			}
			break
		}
	}

	// 5. Arrival chain + zero-night collapse: a leg renders from its arrival
	// (the previous spanned leg's VISIBLE end) when that comes first, and
	// collapses to a zero-night stop at the arrival when the previous leg has
	// run past its own last day. Spanless legs are skipped and never reset
	// the chain; confirmed stays never collapse.
	var prevEnd *time.Time
	for i := range legs {
		leg := &legs[i]
		if leg.Start == nil || leg.End == nil {
			continue
		}
		if prevEnd != nil {
			if prevEnd.Before(*leg.Start) {
				s := *prevEnd
				leg.Start = &s
			} else if prevEnd.After(*leg.End) && !leg.stayMatched {
				s := *prevEnd
				leg.Start, leg.End = &s, &s
				leg.ZeroNight = true
			}
		}
		prevEnd = leg.End
	}

	return legs
}

// firstConfirmedStayForHub finds the confirmed (non-auto) stay that anchors a
// leg's span: fuzzy address match, then NAME fallback for agent-added stays
// with no address; both dates required. Same predicate as stayMatchesHub
// (plan_leg_dates.go) — kept separate so this module stays free of legRun.
func firstConfirmedStayForHub(stays []store.Accommodation, hubLower string) *store.Accommodation {
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

// allocateLegDays splits totalDays across legs proportional to weights, each
// leg at least 1 day, summing to totalDays (largest-remainder; trims from
// the largest legs when the min-1 floor overshoots). Twin of allocateDays in
// utils/leg_ranges.dart.
func allocateLegDays(totalDays int, weights []int) []int {
	n := len(weights)
	if n == 0 {
		return nil
	}
	counts := make([]int, n)
	if totalDays <= n {
		for i := range counts {
			counts[i] = 1 // spans clamp to the trip end
		}
		return counts
	}
	totalW := 0
	norm := make([]int, n)
	for i, w := range weights {
		if w <= 0 {
			w = 1
		}
		norm[i] = w
		totalW += w
	}
	exact := make([]float64, n)
	used := 0
	for i, w := range norm {
		exact[i] = float64(totalDays) * float64(w) / float64(totalW)
		counts[i] = int(exact[i])
		if counts[i] < 1 {
			counts[i] = 1
		}
		used += counts[i]
	}
	frac := func(i int) float64 { return exact[i] - float64(int(exact[i])) }
	// Hand out remaining days to the largest fractional remainders.
	byRemainder := make([]int, n)
	for i := range byRemainder {
		byRemainder[i] = i
	}
	sort.SliceStable(byRemainder, func(a, b int) bool {
		return frac(byRemainder[a]) > frac(byRemainder[b])
	})
	for k := 0; used < totalDays; k++ {
		counts[byRemainder[k%n]]++
		used++
	}
	// Or trim back from the largest legs if the min-1 floor overshot. The
	// count snapshot is taken once, like the Dart twin's byCount sort.
	byCount := make([]int, n)
	for i := range byCount {
		byCount[i] = i
	}
	sort.SliceStable(byCount, func(a, b int) bool {
		return counts[byCount[a]] > counts[byCount[b]]
	})
	for k := 0; used > totalDays; k++ {
		j := byCount[k%n]
		if counts[j] > 1 {
			counts[j]--
			used--
		}
	}
	return counts
}
