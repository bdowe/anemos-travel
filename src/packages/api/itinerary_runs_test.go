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
	// The real 2026-08-20 shape (so the verdict compared is a REJECTION, not
	// just two matching "fine"s), plus a day trip so the reducers' day_trip_from
	// folding is part of what has to agree. Days 1,2,3,4,3,4 — the stale Krakow
	// run carries its pre-swap days, which is what breaks the order.
	items := []store.ItineraryItem{
		item("Wawel Castle", 1, "Krakow", ""),
		item("Rynek Glowny", 2, "Krakow", ""),
		item("Charles Bridge", 3, "Prague", ""),
		item("Kutna Hora", 4, "Kutna Hora", "Prague"),
		item("Wawel Castle", 3, "Krakow", ""), // stale
		item("Rynek Glowny", 4, "Krakow", ""), // stale
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
	if stored.fragmentationRejects() != submitted.fragmentationRejects() || stored.ok() != submitted.ok() {
		t.Fatalf("verdicts differ: stored ok=%v fragRejects=%v, submitted ok=%v fragRejects=%v",
			stored.ok(), stored.fragmentationRejects(), submitted.ok(), submitted.fragmentationRejects())
	}
	// Compared on a shape that actually REJECTS, so agreement is asserted on a
	// real verdict rather than on two matching "fine"s.
	if stored.ok() {
		t.Fatal("this fixture is the corruption shape; it must be rejected")
	}
	if len(stored.Runs) != 3 {
		t.Fatalf("Kutna Hora folds into the Prague run: expected 3 runs, got %d", len(stored.Runs))
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

// THE measured false positive, and the reason the guard composes the two checks
// rather than rejecting on fragmentation alone.
//
// A genuine revisit whose return run REPEATS a place satisfies the classifier's
// predicate outright — run B's identities are a SUBSET of run A's, and the day
// ranges differ. Nothing about it is corrupt: the traveler went back to the
// Louvre. Rejecting it would be a REGRESSION (it writes fine on main) and,
// because a scope-'trip' payload is always the complete itinerary, it would
// block every whole-trip edit on that trip forever.
//
// Both halves are asserted on purpose. The classifier must STILL flag it — the
// repair tool depends on that and its verdicts are pinned byte-identical — while
// the guard must NOT reject it. That split is the whole design; a test that
// checked only one half would let the other drift.
func TestFragmentationAloneDoesNotRejectAGenuineRevisit(t *testing.T) {
	locs := []map[string]any{
		rl("Louvre", 1, "Paris", ""),
		rl("Orsay", 2, "Paris", ""),
		rl("Colosseum", 3, "Rome", ""),
		rl("Forum", 4, "Rome", ""),
		rl("Louvre", 5, "Paris", ""), // same place, genuinely revisited
	}
	v := inspectLocs(locs)
	if len(v.Fragmented) != 1 {
		t.Fatalf("the classifier must still flag it (repair depends on that), got %v", fragmentedHubs(v))
	}
	if len(v.Breaks) != 0 {
		t.Fatalf("a genuine revisit's days run forwards; got breaks %+v", v.Breaks)
	}
	if v.fragmentationRejects() {
		t.Fatal("fragmentation with no day break must not reject a write")
	}
	if !v.ok() {
		t.Fatal("a genuine revisit that repeats a place must be writable")
	}
}

// The shape that decides whether a "return must be separated in time" rule would
// be safe — it would not. A genuine revisit can ARRIVE on a shared transition
// day: Rome that morning, back in Paris that same evening, both day 4. Legal,
// and it has no gap between the runs at all.
func TestClassifyAllowsRevisitArrivingOnATransitionDay(t *testing.T) {
	assertNotFlagged(t, "revisit arriving on a transition day", []map[string]any{
		rl("Louvre", 1, "Paris", ""),
		rl("Orsay", 2, "Paris", ""),
		rl("Colosseum", 3, "Rome", ""),
		rl("Forum", 4, "Rome", ""),
		rl("Gare du Nord", 4, "Paris", ""), // same day 4, back in Paris
		rl("Montmartre", 5, "Paris", ""),
	})
}

// The measured gap, pinned so it is a known quantity rather than a surprise.
//
// An interleaved transition day — the ARRIVING city's item emitted before the
// DEPARTING city's morning item — fragments the trip while leaving the days
// non-decreasing, so neither check fires. It passed before this guard existed
// too, so it is a gap and not a regression.
//
// The candidate for closing it was a run-interleaving test (A,B,A,B). It has
// since been RUN against an enumerated corpus rather than a self-authored one
// (itinerary_shape_corpus_test.go) and it FAILED: 138 false rejections on 563
// shapes it was not fitted to, because A,B,A,B is Paris → Rome → Paris → Rome
// and every one of those is a stay that began after the one before it ended.
// So this gap is now a gap by DECISION, not by deferral, and closing it needs
// a signal the payload does not currently carry — see
// TestTheInterleaveClauseRejectsLegalItineraries.
func TestInterleavedTransitionDayIsAKnownGap(t *testing.T) {
	v := inspectLocs([]map[string]any{
		rl("Charles Bridge", 5, "Prague", ""),
		rl("Wawel", 6, "Krakow", ""),       // arriving city, afternoon
		rl("Old Town Sq", 6, "Prague", ""), // departing city, morning — emitted AFTER
		rl("Rynek", 7, "Krakow", ""),
	})
	if len(v.Runs) != 4 {
		t.Fatalf("this shape renders as four legs, got %d runs", len(v.Runs))
	}
	if len(v.Breaks) != 0 {
		t.Fatalf("documenting the gap: days 5,6,6,7 do not run backwards; got %+v", v.Breaks)
	}
	if !v.ok() {
		t.Fatal("documenting the gap: this is NOT caught today. If this now fails, " +
			"the interleave rule landed — delete this test and assert the rejection instead")
	}
}

// The cheapest available check that the guard is not rejecting real edits: the
// payload from PR #523's TestWholeTripRewriteMovesOtherLegsDates, run DIRECTLY
// through the guard rather than assumed to pass. That test drives a legitimate
// whole-trip rewrite — four cities, every day number re-authored by the model —
// through this exact path, and it is the only whole-trip payload in the tree
// that came from somewhere other than this arc.
//
// Said plainly because it would otherwise be over-read: the payload is A,B,C,D,
// so it CANNOT discriminate the interleave clause — the clause accepts it too.
// It is evidence about the shipped guard, and nothing more.
func TestPR523WholeTripRewriteIsAccepted(t *testing.T) {
	locs := []map[string]any{
		rl("Rijksmuseum", 1, "Amsterdam", ""),
		rl("Jordaan walk", 2, "Amsterdam", ""),
		rl("Kalemegdan Fortress", 3, "Belgrade", ""),
		rl("Skadarlija", 4, "Belgrade", ""),
		rl("Opera House", 5, "Oslo", ""),
		rl("Vigeland Park", 6, "Oslo", ""),
		rl("Vasa Museum", 7, "Stockholm", ""),
		rl("Gamla Stan", 8, "Stockholm", ""),
	}
	if err := errInvalidTripScopePayload(locs); err != nil {
		t.Fatalf("the guard rejects PR #523's legitimate whole-trip rewrite: %v", err)
	}
	assertNotFlagged(t, "PR #523's whole-trip rewrite", locs)
}
