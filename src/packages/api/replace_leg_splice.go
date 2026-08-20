package main

// replace_leg_splice.go — the pure, DB-free half of replace_leg: swap ONE city
// leg's places for another city's, with the SERVER owning every position and
// every day number.
//
// Why that ownership is the whole feature. Before this there was no swap
// primitive, so "replace Copenhagen with Belgrade" routed to
// update_itinerary_section scope 'trip' — a whole-trip rewrite in which the
// model hand-authors every position and every day integer. Observed 2026-08-20
// on an eight-city trip: four cities fragmented into duplicate entries and two
// legs' dates moved. The model was not flailing; it was obeying
// update_itinerary_section's own description. A rewrite that re-authors every
// day number cannot avoid moving dates, so the fix has to remove the
// transcription exercise rather than warn about it.
//
// THE INVARIANT. itineraryLocationSchema's `day` description states the
// convention the whole calendar rests on: "The day the traveler moves between
// cities carries the SAME day number in both — the easy place in the city they
// leave (time_of_day 'morning') and the arrival place in the city they reach
// ('afternoon' or 'evening')." So a leg occupying days [a..d] shares BOTH ends
// with its neighbours: day a also holds the previous city's morning place, day
// d also holds the next city's arrival. computeTripLegs derives every leg's
// span from its own items' day range, so moving either end moves a neighbour's
// rendered dates. This file preserves [a..d] exactly. That is what makes a swap
// leave every other city byte-identical.
//
// Any `day` the caller sends is DROPPED before anything else looks at the
// place. Assigning days here IS the fix; accepting them would rebuild the bug
// inside the tool built to remove it.
//
// Deliberately no start_date/end_date parameter — see spliceLeg's header for
// why moving the span belongs to set_leg_dates and cannot be made correct here.
//
// Pure: no DB, no I/O, no context, so it is unit-testable without Postgres —
// the discipline planTripRepair already follows. The run split, the hub
// predicate and the location shape are all CALLED from itinerary_repair.go /
// itinerary_section.go rather than restated, so detection and enforcement
// cannot drift apart.

import (
	"fmt"
	"strconv"
	"strings"

	"travel-route-planner/store"
)

// legAddress is a parsed `city` argument: which hub, and which visit of it.
type legAddress struct {
	hub string
	// visit is the 1-based visit number the caller named, or 0 for "not
	// stated". The distinction matters: computeTripLegs spells the first visit
	// bare and later ones "Paris#2", so a bare name is ambiguous exactly when
	// the hub occupies more than one run, and is refused there.
	visit int
}

// parseLegAddress splits computeTripLegs' revisit-key spelling into hub and
// visit number. "Paris#2" → {Paris, 2}; "Paris" → {Paris, 0}. A trailing "#"
// that isn't a positive integer is part of the name, not a suffix — no real
// city is spelled that way, but guessing is how a name gets mangled.
func parseLegAddress(city string) legAddress {
	s := strings.TrimSpace(city)
	i := strings.LastIndex(s, "#")
	if i <= 0 {
		return legAddress{hub: s}
	}
	n, err := strconv.Atoi(strings.TrimSpace(s[i+1:]))
	if err != nil || n < 1 {
		return legAddress{hub: s}
	}
	return legAddress{hub: strings.TrimSpace(s[:i]), visit: n}
}

// describeLegRuns lists the trip's city legs with the trip days each occupies,
// spelled the way this tool accepts them back — the self-correcting error
// payload, in the style of describeSections/legsSummary. Hubless runs are
// skipped: a leg with no city is not one this tool can address.
//
// Takes the runItem slice the runs index into: since the scope-'trip' guard
// landed, a hubRun is a half-open index RANGE rather than a carried item list,
// so a run and the list it was computed from travel together.
func describeLegRuns(runs []hubRun, rits []runItem) string {
	seen := map[string]int{}
	var parts []string
	for _, r := range runs {
		hub := strings.TrimSpace(r.Hub)
		if hub == "" {
			continue
		}
		k := strings.ToLower(foldHub(hub))
		seen[k]++
		label := hub
		if seen[k] > 1 {
			label = fmt.Sprintf("%s#%d", hub, seen[k])
		}
		if lo, hi, ok := dayRange(r.slice(rits)); ok {
			parts = append(parts, fmt.Sprintf("%s (trip days %d-%d)", label, lo, hi))
		} else {
			parts = append(parts, fmt.Sprintf("%s (no day numbers)", label))
		}
	}
	if len(parts) == 0 {
		return "no city legs"
	}
	return strings.Join(parts, ", ")
}

// selectLegRun resolves the addressed run among the trip's hub runs.
//
// A hub occupying two runs is NOT corruption — computeTripLegs supports genuine
// revisits (Paris → Rome → Paris), and planTripRepair goes out of its way to
// leave them alone. So a bare name that matches two runs is answered with a
// question, never with a guess: replacing the wrong Paris would delete places
// nobody asked about.
func selectLegRun(runs []hubRun, rits []runItem, addr legAddress) (int, error) {
	var matches []int
	for i, r := range runs {
		if strings.TrimSpace(r.Hub) != "" && sameHub(r.Hub, addr.hub) {
			matches = append(matches, i)
		}
	}
	if len(matches) == 0 {
		return 0, fmt.Errorf("no leg for %q in this trip, so nothing was changed. Its city legs, in order, are: %s. Use the city name exactly as it appears in the itinerary",
			addr.hub, describeLegRuns(runs, rits))
	}
	if addr.visit == 0 {
		if len(matches) > 1 {
			var spans []string
			for n, i := range matches {
				lo, hi, ok := dayRange(runs[i].slice(rits))
				if !ok {
					spans = append(spans, fmt.Sprintf("%s#%d (no day numbers)", runs[i].Hub, n+1))
					continue
				}
				spans = append(spans, fmt.Sprintf("%s#%d (trip days %d-%d)", runs[i].Hub, n+1, lo, hi))
			}
			return 0, fmt.Errorf("the itinerary visits %s %d times, so %q doesn't say which stay to replace and nothing was changed. Name one of: %s — ask the traveler if you can't tell which they mean",
				addr.hub, len(matches), addr.hub, strings.Join(spans, ", "))
		}
		return matches[0], nil
	}
	if addr.visit > len(matches) {
		return 0, fmt.Errorf("the itinerary visits %s %d time(s), so there is no visit #%d, and nothing was changed. Its city legs are: %s",
			addr.hub, len(matches), addr.visit, describeLegRuns(runs, rits))
	}
	return matches[addr.visit-1], nil
}

// legSplice is a swap expressed as data: the trip's COMPLETE new ordered
// location list, plus what the caller needs to report the change without
// re-deriving any of it.
type legSplice struct {
	// Locations is every place in the trip, in the new order, ready for the
	// dense 0-based reinsert replaceTripSection already performs.
	Locations []map[string]any
	// OldHub / NewHub are the hub labels as they appear in the itinerary. Equal
	// when the caller re-placed a city with itself.
	OldHub, NewHub string
	// FirstDay / LastDay are the preserved span [a..d]. Both are shared with a
	// neighbouring leg; they are reported so the caller can say what did NOT
	// move.
	FirstDay, LastDay int
	// Replaced is how many items the old leg held.
	Replaced int
	// Days is the trip-day number assigned to each place in Locations' leg
	// slice, in that order — derivation-visible so a test can pin the
	// assignment without re-reading the maps.
	Days []int
}

// SameCity reports whether the swap kept the city and only re-placed it. A
// same-city refill leaves the leg's stay, transport and checklist rows valid,
// so clearing them would be pure destruction.
func (s legSplice) SameCity() bool { return sameHub(s.OldHub, s.NewHub) }

// spliceLeg returns the trip's complete new ordered location list with ONE
// city leg's places replaced by `places`, in the order given.
//
// It preserves the replaced run's day span [a..d] exactly, which is what keeps
// every other city's rendered dates and night counts byte-identical. Because
// the span is preserved, the FIRST and LAST legs need no special handling
// either: computeTripLegs anchors the first leg's rendered start to the trip's
// start date (step 4) and the last leg's rendered end to the trip's end date
// (step 6), and neither anchor can move while a and d hold still.
//
// There is deliberately no start_date/end_date parameter, diverging from the
// plan artifact's sketched interface. Moving [a..d] cannot be made correct
// here: the neighbours' items still sit on the OLD boundary days, so a moved
// span leaves the previous city ending on day a while this leg starts on a'.
// computeTripLegs' arrival chain (step 5) then pulls the leg's rendered start
// back to the neighbour's end and the requested date never appears — unless the
// neighbour's items move too, which is set_leg_dates' previous-boundary
// extension, its gap/overlap/squeeze narration, and its stay and transport
// moves. Rebuilding that here would be a second writer of leg dates. So this
// tool answers WHAT is in a leg and set_leg_dates answers WHEN, and the tool
// description says to chain them.
func spliceLeg(existing []store.ItineraryItem, city, newCity string, places []map[string]any) (legSplice, error) {
	addr := parseLegAddress(city)
	if addr.hub == "" {
		return legSplice{}, fmt.Errorf("city is required — the city whose leg is being replaced, exactly as it appears in the itinerary. Nothing was changed")
	}
	// An empty list is a DELETE wearing the clothes of an edit, and nothing
	// downstream treats it as one — the same refusal update_itinerary_section
	// makes, for the same reason: removing a city's places removes the two
	// dated rows its calendar span hangs on, which silently re-chains every
	// leg after it.
	if len(places) == 0 {
		return legSplice{}, fmt.Errorf("places came back empty, so this call would DELETE the %s leg rather than replace it, and nothing was changed. Send the new city's places — at least the one they arrive at and one easy place for the day they move on", addr.hub)
	}

	// runItemsOfStored is the shared reduction the run classifier works over
	// (itinerary_runs.go). Computed once and carried alongside `runs`, because a
	// hubRun is an index RANGE into the list it was built from — `existing` and
	// `rits` are parallel, so a run's range slices either one.
	rits := runItemsOfStored(existing)
	runs := hubRuns(rits)
	idx, err := selectLegRun(runs, rits, addr)
	if err != nil {
		return legSplice{}, err
	}
	run := runs[idx]

	first, last, dated := dayRange(run.slice(rits))
	if !dated {
		return legSplice{}, fmt.Errorf("the %s leg's places carry no day numbers, so it has no span to preserve and replacing it would leave the new city's dates to be guessed. Nothing was changed — give %s's places day numbers with update_itinerary_section scope 'city' first, or set its dates with set_leg_dates",
			run.Hub, run.Hub)
	}

	newHub := strings.TrimSpace(newCity)
	if newHub == "" {
		newHub = strings.TrimSpace(run.Hub)
	}

	newLocs, err := legLocations(places, newHub, first, last)
	if err != nil {
		return legSplice{}, err
	}

	out := make([]map[string]any, 0, len(existing)-run.len()+len(newLocs))
	for i, r := range runs {
		if i == idx {
			out = append(out, newLocs...)
			continue
		}
		for _, it := range existing[r.Start:r.End] {
			out = append(out, locationFromItem(it))
		}
	}

	days := make([]int, len(newLocs))
	for i, loc := range newLocs {
		d, _ := loc["day"].(float64)
		days[i] = int(d)
	}
	return legSplice{
		Locations: out,
		OldHub:    strings.TrimSpace(run.Hub),
		NewHub:    newHub,
		FirstDay:  first,
		LastDay:   last,
		Replaced:  run.len(),
		Days:      days,
	}, nil
}

// legLocations turns the caller's places into the leg's new location maps:
// day numbers assigned from [first..last], hub inherited or enforced, and the
// two boundary days made to read like the arrival and the move-on they are.
func legLocations(places []map[string]any, newHub string, first, last int) ([]map[string]any, error) {
	out := make([]map[string]any, len(places))
	for i, loc := range places {
		cp := make(map[string]any, len(loc))
		for k, v := range loc {
			cp[k] = v
		}
		// The caller's `day` never gets a vote — dropped on the way in, so no
		// later branch can consult it even by accident. Not merely belt to the
		// unconditional assignment below: describeStrays reports the day a
		// rejected place carries, and quoting a number the server would have
		// ignored teaches the model that its day numbers mattered.
		delete(cp, "day")
		out[i] = cp
	}

	// Tolerant of omission, strict about contradiction — the ONE difference
	// between how a stored item and a submitted location are judged
	// (sectionKey.inheritUnset). A place carrying no city at all is plainly
	// meant for the city being placed; a place tagged with a DIFFERENT city
	// would start its own run inside this leg, which is the fragmentation this
	// tool exists to make unreachable.
	var strays []map[string]any
	for _, loc := range out {
		switch h := keyOfLocation(loc).Hub; {
		case h == "":
			loc["city"] = newHub
		case !sameHub(h, newHub):
			strays = append(strays, loc)
		}
	}
	if len(strays) > 0 {
		return nil, fmt.Errorf("%d of the %d places sent are not in %s: %s. replace_leg replaces ONE city's leg, so every place must be in %s — or be a day trip whose day_trip_from is %q (a nearby town they visit and return from the same day). Nothing was changed; resend just %s's places",
			len(strays), len(out), newHub, describeStrays(strays), newHub, newHub, newHub)
	}

	// The two boundary days are shared with the neighbouring cities, so one of
	// them cannot double as the other: a single place cannot sit on both the
	// arrival day and the day they move on. Without a place on the move-on day
	// the leg renders as though they left the day they arrived, and the NEXT
	// city swallows its nights (computeTripLegs step 5's zero-night collapse) —
	// the exact failure the spine rule in plan_handler.go's prompt is about.
	if first < last && len(out) < 2 {
		return nil, fmt.Errorf("the leg being replaced runs trip days %d-%d, and day %d is the day the traveler moves on to the next city — one place cannot sit on both ends, and nothing was changed. Send at least two places for %s: the one they arrive at on day %d, and one easy place near their lodging for day %d. The days in between are meant to stay empty until the traveler asks for that city",
			first, last, last, newHub, first, last)
	}

	for i, loc := range out {
		loc["day"] = float64(legDayFor(i, len(out), first, last))
	}

	// Make the shared days read like what they are. The server owns this for
	// the same reason it owns the day numbers: a model that gets it wrong puts
	// two cities' morning places on one calendar day, and no surface downstream
	// would say so. Only when the leg HAS two distinct ends — a zero-night stop
	// (first == last) has one day that is both, and forcing a part of the day
	// on it would be inventing a schedule.
	if first < last {
		if tod, _ := out[0]["time_of_day"].(string); tod != "afternoon" && tod != "evening" {
			out[0]["time_of_day"] = "afternoon"
		}
		out[len(out)-1]["time_of_day"] = "morning"
	}

	// Same in-block walking-distance cleanup the other itinerary writers get,
	// applied to THIS LEG's places only — the rest of the trip must come out of
	// a swap byte-identical. It permutes within a (day, time_of_day,
	// day_trip_from) block and never across one, so the boundary days keep
	// their coverage whatever it reorders.
	return reorderItineraryByDistance(out), nil
}

// legDayFor assigns the i-th of n places a trip day inside [first..last].
//
// Linear interpolation with round-half-up, which is the shortest expression of
// the three things that have to be true: the first place lands on `first`, the
// last on `last` (the two shared boundary days both get covered), and the
// sequence never runs backwards (item order is visit order). With the spine's
// two places it yields exactly [first, last] and leaves every middle day empty
// — a spine's empty middle days are the plan, not a gap.
func legDayFor(i, n, first, last int) int {
	if n < 2 || last <= first {
		return first
	}
	span := last - first
	return first + (i*span+(n-1)/2)/(n-1)
}
