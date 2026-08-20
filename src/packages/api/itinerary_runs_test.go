package main

import (
	"strings"
	"testing"

	"travel-route-planner/store"
)

// --- fixture helpers ---

// rl builds one payload location. day 0 means the model left `day` out;
// city/dayTripFrom "" mean the field is absent. Coordinates default to a
// per-place value derived from the name, because identityOf keys on lat/lng and
// a shared default would make every place a content duplicate of every other —
// which would make the "different content" fixtures pass for the wrong reason.
func rl(name string, day int, city, dayTripFrom string) map[string]any {
	m := loc(name, day, city, dayTripFrom)
	var h float64
	for _, r := range name {
		h = h*31 + float64(r)
	}
	m["latitude"] = 10 + float64(int64(h)%1000)/1000
	m["longitude"] = 20 + float64(int64(h)%997)/1000
	return m
}

func inspectLocs(locs []map[string]any) tripScopeVerdict {
	return inspectTripScope(runItemsOfLocations(locs))
}

func fragmentedHubs(v tripScopeVerdict) []string {
	out := make([]string, 0, len(v.Fragmented))
	for _, f := range v.Fragmented {
		out = append(out, f.Hub)
	}
	return out
}

func assertNotFlagged(t *testing.T, why string, locs []map[string]any) tripScopeVerdict {
	t.Helper()
	v := inspectLocs(locs)
	if len(v.Fragmented) > 0 {
		t.Fatalf("%s: must not read as fragmented, got %v (%s)", why, fragmentedHubs(v), describeFragments(v))
	}
	if len(v.Breaks) > 0 {
		t.Fatalf("%s: must not read as a day-order break, got %+v", why, v.Breaks)
	}
	if !v.ok() {
		t.Fatalf("%s: verdict should be ok", why)
	}
	return v
}

// --- the shapes that must NOT flag (ticket 1's table) ---

// A trip that genuinely revisits a city renders as two legs on purpose.
// planTripRepair's own comment: "computeTripLegs supports genuine revisits… and
// those must be left alone."
func TestClassifyAllowsGenuineRevisit(t *testing.T) {
	v := assertNotFlagged(t, "Paris → Rome → Paris", []map[string]any{
		rl("Louvre", 1, "Paris", ""),
		rl("Orsay", 2, "Paris", ""),
		rl("Colosseum", 3, "Rome", ""),
		rl("Forum", 4, "Rome", ""),
		rl("Sacre-Coeur", 5, "Paris", ""),
		rl("Montmartre", 6, "Paris", ""),
	})
	if len(v.Runs) != 3 {
		t.Fatalf("a revisit is three runs, got %d", len(v.Runs))
	}
	if len(v.Skipped) == 0 {
		t.Fatal("a skipped revisit should say why")
	}
}

// The day a traveler moves between cities carries the SAME day number in both —
// itineraryLocationSchema's `day` description. Two hubs on one day is the
// design, so the day check compares strictly `<`.
func TestClassifyAllowsSharedTransitionDay(t *testing.T) {
	assertNotFlagged(t, "shared transition day", []map[string]any{
		rl("Louvre", 1, "Paris", ""),
		rl("Orsay", 2, "Paris", ""),
		rl("Sainte-Chapelle", 3, "Paris", ""),  // morning of the move day
		rl("Trastevere dinner", 3, "Rome", ""), // evening of the SAME day, in Rome
		rl("Colosseum", 4, "Rome", ""),
	})
}

// A day trip belongs to its hub's run: renderHubOf resolves day_trip_from ?? city,
// so Versailles inside a Paris stay is one run, not three.
func TestClassifyFoldsDayTripIntoItsHubRun(t *testing.T) {
	v := assertNotFlagged(t, "Versailles inside Paris", []map[string]any{
		rl("Louvre", 1, "Paris", ""),
		rl("Versailles", 2, "Versailles", "Paris"),
		rl("Orsay", 3, "Paris", ""),
	})
	if len(v.Runs) != 1 {
		t.Fatalf("a day trip does not split its hub's run, got %d runs", len(v.Runs))
	}
}

// hubRuns skips empty hubs; computeTripLegs groups hubless items into "Other
// places". A hubless item between two runs of one city must not read as
// fragmentation, and repeated HUBLESS runs must never be classified at all.
func TestClassifySkipsHublessRuns(t *testing.T) {
	assertNotFlagged(t, "hubless item between two Paris runs", []map[string]any{
		rl("Louvre", 1, "Paris", ""),
		rl("Somewhere", 2, "", ""),
		rl("Orsay", 3, "Paris", ""),
	})
	// The sharper case: two hubless runs holding the SAME place on different
	// days. Were hubless runs classified, this is exactly the fragmented shape —
	// so this fixture fails the moment the empty-hub skip is dropped.
	assertNotFlagged(t, "duplicate hubless runs", []map[string]any{
		rl("Mystery stop", 1, "", ""),
		rl("Louvre", 2, "Paris", ""),
		rl("Mystery stop", 3, "", ""),
	})
}

// A spine is a complete valid itinerary whose middle days are deliberately empty
// (create_itinerary's description). Sparse days are not corruption, and the gaps
// must not read as a backwards step.
func TestClassifyAllowsSpineWithEmptyMiddleDays(t *testing.T) {
	assertNotFlagged(t, "spine", []map[string]any{
		rl("Arrive Paris", 1, "Paris", ""),
		rl("Leave Paris", 4, "Paris", ""),
		rl("Arrive Rome", 4, "Rome", ""),
		rl("Leave Rome", 8, "Rome", ""),
	})
}

// Undated places are an absence of evidence, not a violation: an unscheduled
// tail is legitimate and must not read as day 0 running backwards.
func TestClassifyIgnoresUndatedPlaces(t *testing.T) {
	assertNotFlagged(t, "unscheduled tail", []map[string]any{
		rl("Louvre", 1, "Paris", ""),
		rl("Orsay", 2, "Paris", ""),
		rl("Maybe: Pompidou", 0, "Paris", ""),
	})
}

// --- the true positive ---

// The 2026-08-20 corruption, verbatim from itinerary_repair.go's header: the
// city appears twice, once with its dates and once collapsed to the pre-edit
// days. Prague(d1-2) → Krakow(d3-4), asked to swap, spliced Krakow in twice.
func TestClassifyFlagsDuplicateRunsDisagreeingOnDates(t *testing.T) {
	v := inspectLocs([]map[string]any{
		rl("Wawel Castle", 1, "Krakow", ""),
		rl("Rynek Glowny", 2, "Krakow", ""),
		rl("Charles Bridge", 3, "Prague", ""),
		rl("Old Town Square", 4, "Prague", ""),
		rl("Wawel Castle", 3, "Krakow", ""), // stale: pre-swap days
		rl("Rynek Glowny", 4, "Krakow", ""), // stale
	})
	if got := fragmentedHubs(v); len(got) != 1 || got[0] != "Krakow" {
		t.Fatalf("the stale Krakow run must be flagged, got %v", got)
	}
	if v.ok() {
		t.Fatal("verdict must not be ok")
	}
	d := describeFragments(v)
	for _, want := range []string{"Krakow", "days 1-2", "days 3-4", "Wawel Castle"} {
		if !strings.Contains(d, want) {
			t.Fatalf("description %q should name %q", d, want)
		}
	}
}

// Twin runs holding the same places on the same days aren't the splice bug —
// whatever produced them, the classifier must not guess.
func TestClassifySkipsIdenticalDayRanges(t *testing.T) {
	v := inspectLocs([]map[string]any{
		rl("Charles Bridge", 1, "Prague", ""),
		rl("Wawel Castle", 3, "Krakow", ""),
		rl("Charles Bridge", 1, "Prague", ""),
	})
	if len(v.Fragmented) != 0 {
		t.Fatalf("identical day ranges must be skipped, got %v", fragmentedHubs(v))
	}
	if len(v.Skipped) == 0 {
		t.Fatal("a skip should say why")
	}
}

// --- day monotonicity ---

func TestDayOrderBreaksNamesTheBackwardStep(t *testing.T) {
	fwd := runItemsOfLocations([]map[string]any{
		rl("a", 1, "X", ""), rl("b", 2, "X", ""), rl("c", 3, "X", ""),
	})
	if n := dayOrderViolations(fwd); n != 0 {
		t.Fatalf("ascending days have no violations, got %d", n)
	}
	back := runItemsOfLocations([]map[string]any{
		rl("a", 3, "X", ""), rl("b", 1, "X", ""), rl("c", 2, "X", ""),
	})
	breaks := dayOrderBreaks(back)
	if len(breaks) != 1 {
		t.Fatalf("one backward step, got %d", len(breaks))
	}
	if breaks[0].Name != "b" || breaks[0].Day != 1 || breaks[0].Prev != 3 {
		t.Fatalf("break should name b (day 1 after day 3), got %+v", breaks[0])
	}
	if dayOrderViolations(back) != len(breaks) {
		t.Fatal("the count and the names must never disagree")
	}
}

// --- the two reducers must agree ---

// The audit reads stored rows; the guard reads submitted locations. If those two
// reductions disagreed, the audit's prediction would not be about the guard's
// behaviour at all — which is the whole failure the shared classifier exists to
// prevent. locationFromItem is the round-trip the write path itself performs.
func TestStoredAndSubmittedReduceIdentically(t *testing.T) {
	items := []store.ItineraryItem{
		item("Wawel Castle", 1, "Krakow", ""),
		item("Rynek Glowny", 2, "Krakow", ""),
		item("Charles Bridge", 3, "Prague", ""),
		item("Versailles", 3, "Versailles", "Prague"),
		item("Wawel Castle", 3, "Krakow", ""),
		item("Rynek Glowny", 4, "Krakow", ""),
	}
	locs := make([]map[string]any, len(items))
	for i, it := range items {
		locs[i] = locationFromItem(it)
	}
	stored, submitted := inspectTripScope(runItemsOfStored(items)), inspectLocs(locs)
	if len(stored.Runs) != len(submitted.Runs) {
		t.Fatalf("runs differ: %d stored vs %d submitted", len(stored.Runs), len(submitted.Runs))
	}
	if fs, fl := fragmentedHubs(stored), fragmentedHubs(submitted); strings.Join(fs, ",") != strings.Join(fl, ",") {
		t.Fatalf("fragmentation differs: stored %v vs submitted %v", fs, fl)
	}
	if len(stored.Breaks) != len(submitted.Breaks) {
		t.Fatalf("day breaks differ: %d stored vs %d submitted", len(stored.Breaks), len(submitted.Breaks))
	}
	if stored.ok() || submitted.ok() {
		t.Fatal("this fixture is the corruption shape; both sides must flag it")
	}
}

func TestHubRunsFoldCase(t *testing.T) {
	runs := hubRuns(runItemsOfLocations([]map[string]any{
		rl("a", 1, "Krakow", ""),
		rl("b", 2, "krakow", ""),
		rl("c", 3, "Prague", ""),
	}))
	if len(runs) != 2 {
		t.Fatalf("mixed case is one hub run, got %d runs", len(runs))
	}
	if runs[0].len() != 2 {
		t.Fatalf("first run should hold both Krakow items, got %d", runs[0].len())
	}
}

// Kraków and Krakow are one hub, so a run split on spelling alone would report a
// revisit that isn't one.
func TestHubRunsFoldDiacritics(t *testing.T) {
	runs := hubRuns(runItemsOfLocations([]map[string]any{
		rl("a", 1, "Kraków", ""),
		rl("b", 2, "Krakow", ""),
	}))
	if len(runs) != 1 {
		t.Fatalf("Kraków and Krakow are one run, got %d", len(runs))
	}
}

func TestInspectTripScopeEmptyPayload(t *testing.T) {
	if v := inspectTripScope(nil); !v.ok() || len(v.Runs) != 0 {
		t.Fatalf("an empty list has nothing to flag, got %+v", v)
	}
}

// KNOWN LIMITATION, deliberately pinned rather than fixed here.
//
// A genuine revisit whose return run REPEATS a place from the first run is
// flagged: run B's identities are a subset of run A's, and the day ranges
// differ, which is the whole predicate. Nothing about this shape is corrupt —
// the traveler simply ate at the same bistro on the way home.
//
// It is left flagged because ticket 1 may not change what repair-sections
// decides, and because the fix is a predicate change that belongs to whoever
// owns the audit's result, not to the extraction. Note that such a shape has NO
// day-order break (its days run 1…7 forwards), whereas the 2026-08-20
// corruption always has one — so `fragmented && a day break` separates them
// exactly. If this test ever starts failing, it is because that tightening
// landed, and the fixture should become an assertNotFlagged.
func TestClassifyFlagsPartiallyRepeatedRevisit_KnownLimitation(t *testing.T) {
	v := inspectLocs([]map[string]any{
		rl("Louvre", 1, "Paris", ""),
		rl("Orsay", 2, "Paris", ""),
		rl("Colosseum", 3, "Rome", ""),
		rl("Forum", 4, "Rome", ""),
		rl("Louvre", 5, "Paris", ""), // same place, genuinely revisited
	})
	if len(v.Fragmented) != 1 {
		t.Fatalf("documenting today's behaviour: expected Paris flagged, got %v", fragmentedHubs(v))
	}
	if len(v.Breaks) != 0 {
		t.Fatalf("a genuine revisit's days run forwards; got breaks %+v", v.Breaks)
	}
}
