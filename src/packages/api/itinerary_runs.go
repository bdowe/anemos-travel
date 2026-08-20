package main

// The shared hub-run classifier: the ONE answer to "does this list of places,
// in position order, fragment a city into duplicate runs, and do its day
// numbers run forwards?"
//
// It exists because two callers need that answer and must never disagree about
// it: itinerary_repair.go's offline `repair-sections` (detection, after the
// fact) and itinerary_section.go's scope-'trip' guard (enforcement, on the
// write path). itinerary_repair.go's header already set the rule — reuse the
// same hub predicate "so detection and enforcement cannot drift apart" — and a
// second copy of "what counts as a fragmented city" is precisely the drift that
// rule forbids.
//
// Everything here is pure: no DB, no I/O, no clock. That is what lets the guard
// run it on a payload inside a transaction and the repair tool run it on a
// stored trip, from one implementation.
//
// The predicate is deliberately conservative, and the reason is the single most
// load-bearing fact in this file: A HUB OCCUPYING TWO RUNS IS NOT BY ITSELF
// CORRUPTION. computeTripLegs supports genuine revisits (Paris → Rome → Paris)
// and renders them as two legs on purpose. A run is only called fragmented when
// it is ALSO a content duplicate of its twin AND the two disagree about dates.
// A check that merely counted "each city appears once" would reject a supported
// itinerary shape, and a guard that rejects legal itineraries gets turned off.

import (
	"fmt"
	"sort"
	"strings"

	"travel-route-planner/store"
)

// runItem is the neutral shape both a stored itinerary row and a submitted
// agent location reduce to before any run reasoning happens — the same
// one-shape-two-writers discipline sectionKey already applies to section
// membership, for the same reason: a stored trip and a submitted payload judged
// by two predicates is how they drift.
//
// It carries only what run classification needs. Ids, positions and tags stay
// with the caller, which maps a run's index range back onto its own richer
// rows.
type runItem struct {
	Hub      string // day_trip_from ?? city, trimmed. "" = unspecified.
	Day      *int   // nil = unscheduled/unspecified.
	Name     string // for naming the offending place in a report or rejection.
	Identity itemIdentity
}

// itemIdentity is what a verbatim splice copy preserves byte-for-byte. `day` is
// deliberately EXCLUDED: the duplicate's stale day is the whole reason the two
// copies differ, so keying on it would hide exactly the pairs we're looking for.
// Position is excluded for the same reason.
type itemIdentity struct {
	Name, PlaceID, City, DayTripFrom string
	LatE5, LngE5                     int64
}

// foldIdentity normalizes one identity field: trimmed, diacritic-folded and
// lowercased, so the model re-typing "Kraków" as "Krakow" doesn't read as a
// different place. Same folding sameHub uses, for the same reason.
func foldIdentity(s string) string { return strings.ToLower(foldHub(s)) }

// coordE5 quantizes a coordinate to ~1 m so a re-serialized copy of the same
// place still compares equal.
func coordE5(v float64) int64 { return int64(v * 1e5) }

// runItemOfStored reduces a stored row. Hub and day come from keyOfItem, so the
// runs the classifier sees are grouped by the SAME predicate section membership
// uses.
func runItemOfStored(it store.ItineraryItem) runItem {
	k := keyOfItem(it)
	return runItem{
		Hub:  k.Hub,
		Day:  k.Day,
		Name: it.Name,
		Identity: itemIdentity{
			Name:        foldIdentity(it.Name),
			PlaceID:     foldIdentity(strPtrVal(it.PlaceID)),
			City:        foldIdentity(strPtrVal(it.City)),
			DayTripFrom: foldIdentity(strPtrVal(it.DayTripFrom)),
			LatE5:       coordE5(it.Latitude),
			LngE5:       coordE5(it.Longitude),
		},
	}
}

// runItemOfLocation is [runItemOfStored] for the agent's location-map shape. The
// field coercion matches itemParamsFromLocation and keyOfLocation exactly, so
// the guard can never reject on a value the writer would itself have ignored.
func runItemOfLocation(loc map[string]any) runItem {
	k := keyOfLocation(loc)
	str := func(key string) string {
		s, _ := loc[key].(string)
		return foldIdentity(s)
	}
	name, _ := loc["name"].(string)
	lat, _ := loc["latitude"].(float64)
	lng, _ := loc["longitude"].(float64)
	return runItem{
		Hub:  k.Hub,
		Day:  k.Day,
		Name: name,
		Identity: itemIdentity{
			Name:        foldIdentity(name),
			PlaceID:     str("place_id"),
			City:        str("city"),
			DayTripFrom: str("day_trip_from"),
			LatE5:       coordE5(lat),
			LngE5:       coordE5(lng),
		},
	}
}

func runItemsOfStored(items []store.ItineraryItem) []runItem {
	out := make([]runItem, len(items))
	for i, it := range items {
		out[i] = runItemOfStored(it)
	}
	return out
}

func runItemsOfLocations(locs []map[string]any) []runItem {
	out := make([]runItem, len(locs))
	for i, loc := range locs {
		out[i] = runItemOfLocation(loc)
	}
	return out
}

// hubRun is one contiguous same-hub stretch in position order — the same
// grouping computeTripLegs renders a leg from. Start/End is a half-open index
// range into the slice the runs were computed from, so contiguity is structural
// and a caller holding richer rows can slice its own list by the same range.
type hubRun struct {
	Hub        string
	Start, End int
}

func (r hubRun) len() int { return r.End - r.Start }

func (r hubRun) slice(items []runItem) []runItem { return items[r.Start:r.End] }

func hubRuns(items []runItem) []hubRun {
	var runs []hubRun
	for i, it := range items {
		if len(runs) == 0 || !sameHub(runs[len(runs)-1].Hub, it.Hub) {
			runs = append(runs, hubRun{Hub: it.Hub, Start: i})
		}
		runs[len(runs)-1].End = i + 1
	}
	return runs
}

// fragmentedHub is one hub occupying two runs that are content duplicates
// disagreeing about dates — the corruption shape described in
// itinerary_repair.go's header, where "the city appeared twice: once with its
// dates, once collapsed to a zero-night stop".
type fragmentedHub struct {
	Hub  string // as first spelled in the list
	A, B int    // indexes into runClassification.Runs, in position order
}

// runClassification is everything classifyHubRuns decided about one list.
// Skipped records the hubs it deliberately left alone and why — a genuine
// revisit is a SKIP, not a finding, and the repair tool prints those reasons.
type runClassification struct {
	Runs       []hubRun
	Fragmented []fragmentedHub
	Skipped    []string
}

// classifyHubRuns is THE fragmentation predicate. Hubs are examined in
// alphabetical (folded) order so the reasons it reports are stable regardless of
// map iteration.
func classifyHubRuns(items []runItem) runClassification {
	c := runClassification{Runs: hubRuns(items)}

	byHub := map[string][]int{}
	var order []string
	for i, r := range c.Runs {
		if strings.TrimSpace(r.Hub) == "" {
			continue // hubless runs group together by a different rule; skip
		}
		k := foldIdentity(r.Hub)
		if _, seen := byHub[k]; !seen {
			order = append(order, k)
		}
		byHub[k] = append(byHub[k], i)
	}
	sort.Strings(order)

	for _, k := range order {
		idx := byHub[k]
		if len(idx) < 2 {
			continue
		}
		hub := c.Runs[idx[0]].Hub
		if len(idx) > 2 {
			c.Skipped = append(c.Skipped,
				fmt.Sprintf("%s: %d runs — too many to classify automatically", hub, len(idx)))
			continue
		}
		a, b := c.Runs[idx[0]].slice(items), c.Runs[idx[1]].slice(items)
		ca, cb := identityCounts(a), identityCounts(b)
		if !subsetOf(ca, cb) && !subsetOf(cb, ca) {
			c.Skipped = append(c.Skipped,
				fmt.Sprintf("%s: two runs hold different places — looks like a real revisit", hub))
			continue
		}
		aLo, aHi, aOK := dayRange(a)
		bLo, bHi, bOK := dayRange(b)
		if aOK && bOK && aLo == bLo && aHi == bHi {
			c.Skipped = append(c.Skipped,
				fmt.Sprintf("%s: duplicate runs share the same days — not the splice bug", hub))
			continue
		}
		c.Fragmented = append(c.Fragmented, fragmentedHub{Hub: hub, A: idx[0], B: idx[1]})
	}
	return c
}

func identityCounts(items []runItem) map[itemIdentity]int {
	m := make(map[itemIdentity]int, len(items))
	for _, it := range items {
		m[it.Identity]++
	}
	return m
}

// subsetOf reports whether every identity in a appears in b at least as often.
func subsetOf(a, b map[itemIdentity]int) bool {
	for k, n := range a {
		if b[k] < n {
			return false
		}
	}
	return true
}

func dayRange(items []runItem) (lo, hi int, ok bool) {
	for _, it := range items {
		if it.Day == nil {
			continue
		}
		if !ok || *it.Day < lo {
			lo = *it.Day
		}
		if !ok || *it.Day > hi {
			hi = *it.Day
		}
		ok = true
	}
	return lo, hi, ok
}

// dayBreak is one place whose day number runs BACKWARDS from the dated place
// before it in position order.
type dayBreak struct {
	Index int
	Name  string
	Day   int
	Prev  int
}

// dayOrderBreaks walks a list in position order and returns every backward step.
// Undated places are skipped rather than treated as day 0 — a spine leaves the
// middle of a stay empty and an unscheduled tail is legitimate, so "no day" is
// an absence of evidence, not a violation.
//
// The comparison is strictly `<`, which is what makes a SHARED TRANSITION DAY
// legal: the day a traveler moves between cities carries the same number in the
// city they leave and the one they reach (itineraryLocationSchema's `day`
// description), so day 4 following day 4 is the design, not a break.
func dayOrderBreaks(items []runItem) []dayBreak {
	var out []dayBreak
	var prev *int
	for i, it := range items {
		if it.Day == nil {
			continue
		}
		if prev != nil && *it.Day < *prev {
			out = append(out, dayBreak{Index: i, Name: it.Name, Day: *it.Day, Prev: *prev})
		}
		d := *it.Day
		prev = &d
	}
	return out
}

// dayOrderViolations counts what dayOrderBreaks names. The splice bug leaves the
// stale copy's days out of order with everything around it, so removing the
// stale run drops this count while removing the fresh one does not — which is
// how planTripRepair decides which copy to drop. Counting what the namer returns
// (rather than walking a second time) keeps the count and the names from ever
// disagreeing.
func dayOrderViolations(items []runItem) int { return len(dayOrderBreaks(items)) }

// tripScopeVerdict is the guard's whole answer about one list of places treated
// as a complete trip: both checks, computed independently so a report can show
// both at once even though the rejection names only the first.
type tripScopeVerdict struct {
	Runs       []hubRun
	Items      []runItem
	Fragmented []fragmentedHub
	Breaks     []dayBreak
	Skipped    []string
}

func (v tripScopeVerdict) ok() bool { return len(v.Fragmented) == 0 && len(v.Breaks) == 0 }

// inspectTripScope runs both checks over a whole-trip list. It is the one entry
// point the write-path guard and the report-only audit share, so what the audit
// predicts and what the guard does cannot come apart.
func inspectTripScope(items []runItem) tripScopeVerdict {
	c := classifyHubRuns(items)
	return tripScopeVerdict{
		Runs:       c.Runs,
		Items:      items,
		Fragmented: c.Fragmented,
		Skipped:    c.Skipped,
		Breaks:     dayOrderBreaks(items),
	}
}

// describeDayRange renders a run's days the way both the rejection and the audit
// name them.
func describeDayRange(items []runItem) string {
	lo, hi, ok := dayRange(items)
	switch {
	case !ok:
		return "no days"
	case lo == hi:
		return fmt.Sprintf("day %d", lo)
	default:
		return fmt.Sprintf("days %d-%d", lo, hi)
	}
}

// fragmentSampleNames bounds how many place names a fragment names, so a
// whole-itinerary mistake can't blow up the tool_result. straySampleCap bounds
// the fragments; this bounds each one.
const fragmentSampleNames = 2

// describeFragment names one fragmented hub, both of its day ranges and a couple
// of the places involved — enough for the model to see which city to reassemble
// without reprinting the itinerary.
func describeFragment(v tripScopeVerdict, f fragmentedHub) string {
	a, b := v.Runs[f.A].slice(v.Items), v.Runs[f.B].slice(v.Items)
	names := make([]string, 0, fragmentSampleNames)
	for _, it := range b {
		if len(names) == fragmentSampleNames {
			break
		}
		n := strings.TrimSpace(it.Name)
		if n == "" {
			n = "(unnamed place)"
		}
		names = append(names, n)
	}
	sample := strings.Join(names, ", ")
	if rest := len(b) - len(names); rest > 0 {
		sample += fmt.Sprintf(" and %d more", rest)
	}
	hub := strings.TrimSpace(f.Hub)
	if hub == "" {
		hub = "(no city)"
	}
	return fmt.Sprintf("%s (%s, then again on %s: %s)",
		hub, describeDayRange(a), describeDayRange(b), sample)
}

// describeFragments joins the fragments, capped at straySampleCap the way
// describeStrays caps its sample.
func describeFragments(v tripScopeVerdict) string {
	parts := make([]string, 0, straySampleCap)
	for _, f := range v.Fragmented {
		if len(parts) == straySampleCap {
			break
		}
		parts = append(parts, describeFragment(v, f))
	}
	s := strings.Join(parts, ", ")
	if rest := len(v.Fragmented) - len(parts); rest > 0 {
		s += fmt.Sprintf(" and %d more", rest)
	}
	return s
}
