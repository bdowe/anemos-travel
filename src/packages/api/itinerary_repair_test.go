package main

import (
	"testing"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// ritem builds a stored row with an id and position, which planTripRepair needs
// and the section tests' `item` helper doesn't set.
func ritem(pos int, name string, day int, city string) store.ItineraryItem {
	it := item(name, day, city, "")
	it.ID = uuid.New()
	it.Position = int32(pos)
	return it
}

func deletedNames(items []store.ItineraryItem, plan repairPlan) []string {
	byID := map[uuid.UUID]string{}
	for _, it := range items {
		byID[it.ID] = it.Name
	}
	out := make([]string, 0, len(plan.DeleteIDs))
	for _, id := range plan.DeleteIDs {
		out = append(out, byID[id])
	}
	return out
}

func assertDeleted(t *testing.T, items []store.ItineraryItem, plan repairPlan, want ...string) {
	t.Helper()
	got := deletedNames(items, plan)
	if len(got) != len(want) {
		t.Fatalf("deleted %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("deleted %v, want %v", got, want)
		}
	}
}

// The exact output of the old splice. Trip was Prague(d1-2) → Krakow(d3-4); the
// model was asked to swap them and sent BOTH cities under scope city="Prague".
// spliceSection kept Krakow in `out` (still on days 3-4) and appended it after
// the model's replacement list, so Krakow ends up in two runs — the fresh copy
// on days 1-2 and a stale trailing copy on days 3-4.
func TestPlanTripRepairCollapsesStaleTrailingRun(t *testing.T) {
	items := []store.ItineraryItem{
		ritem(0, "Wawel Castle", 1, "Krakow"),
		ritem(1, "Rynek Glowny", 2, "Krakow"),
		ritem(2, "Charles Bridge", 3, "Prague"),
		ritem(3, "Old Town Square", 4, "Prague"),
		ritem(4, "Wawel Castle", 3, "Krakow"), // stale: pre-swap days
		ritem(5, "Rynek Glowny", 4, "Krakow"), // stale
	}
	plan := planTripRepair(items)
	assertDeleted(t, items, plan, "Wawel Castle", "Rynek Glowny")
	if len(plan.After) != 4 {
		t.Fatalf("expected 4 surviving items, got %d", len(plan.After))
	}
}

// The mirror, from the SAME user action: had the model targeted city="Krakow"
// instead, `out` would hold Prague and insertAt would land after it, so the
// stale copy leads. This is the case that proves "keep the first occurrence"
// would be wrong half the time — the keep/drop call has to come from day order.
func TestPlanTripRepairCollapsesStaleLeadingRun(t *testing.T) {
	items := []store.ItineraryItem{
		ritem(0, "Charles Bridge", 1, "Prague"),  // stale: pre-swap days
		ritem(1, "Old Town Square", 2, "Prague"), // stale
		ritem(2, "Wawel Castle", 1, "Krakow"),
		ritem(3, "Rynek Glowny", 2, "Krakow"),
		ritem(4, "Charles Bridge", 3, "Prague"),
		ritem(5, "Old Town Square", 4, "Prague"),
	}
	plan := planTripRepair(items)
	assertDeleted(t, items, plan, "Charles Bridge", "Old Town Square")
	if len(plan.After) != 4 {
		t.Fatalf("expected 4 surviving items, got %d", len(plan.After))
	}
}

// A trip that genuinely revisits a city must be left completely alone —
// computeTripLegs renders those as two legs on purpose.
func TestPlanTripRepairSkipsLegitimateRevisit(t *testing.T) {
	items := []store.ItineraryItem{
		ritem(0, "Louvre", 1, "Paris"),
		ritem(1, "Orsay", 2, "Paris"),
		ritem(2, "Colosseum", 3, "Rome"),
		ritem(3, "Forum", 4, "Rome"),
		ritem(4, "Sacre-Coeur", 5, "Paris"),
		ritem(5, "Montmartre", 6, "Paris"),
	}
	plan := planTripRepair(items)
	if !plan.empty() {
		t.Fatalf("a real revisit must not be repaired, got %v", deletedNames(items, plan))
	}
	if len(plan.Skipped) == 0 {
		t.Fatal("a skipped revisit should say why")
	}
}

// Two runs holding the same places on the same days aren't the splice bug —
// whatever produced them, this tool must not guess.
func TestPlanTripRepairSkipsIdenticalDayRanges(t *testing.T) {
	items := []store.ItineraryItem{
		ritem(0, "Charles Bridge", 1, "Prague"),
		ritem(1, "Old Town Square", 2, "Prague"),
		ritem(2, "Wawel Castle", 3, "Krakow"),
		ritem(3, "Charles Bridge", 1, "Prague"),
		ritem(4, "Old Town Square", 2, "Prague"),
	}
	if plan := planTripRepair(items); !plan.empty() {
		t.Fatalf("identical day ranges must be skipped, got %v", deletedNames(items, plan))
	}
}

func TestPlanTripRepairSkipsPartialOverlap(t *testing.T) {
	items := []store.ItineraryItem{
		ritem(0, "Charles Bridge", 1, "Prague"),
		ritem(1, "Old Town Square", 2, "Prague"),
		ritem(2, "Wawel Castle", 3, "Krakow"),
		ritem(3, "Charles Bridge", 5, "Prague"),
		ritem(4, "Petrin Tower", 6, "Prague"), // not in the first run
	}
	if plan := planTripRepair(items); !plan.empty() {
		t.Fatalf("partial overlap must be skipped, got %v", deletedNames(items, plan))
	}
}

func TestPlanTripRepairIgnoresTinyTrips(t *testing.T) {
	items := []store.ItineraryItem{
		ritem(0, "Charles Bridge", 1, "Prague"),
		ritem(1, "Wawel Castle", 2, "Krakow"),
		ritem(2, "Charles Bridge", 1, "Prague"),
	}
	if plan := planTripRepair(items); !plan.empty() {
		t.Fatal("a 3-item trip is too small to classify")
	}
}

func TestHubRunsFoldCase(t *testing.T) {
	runs := hubRuns([]store.ItineraryItem{
		ritem(0, "a", 1, "Krakow"),
		ritem(1, "b", 2, "krakow"),
		ritem(2, "c", 3, "Prague"),
	})
	if len(runs) != 2 {
		t.Fatalf("mixed case is one hub run, got %d runs", len(runs))
	}
	if len(runs[0].Items) != 2 {
		t.Fatalf("first run should hold both Krakow items, got %d", len(runs[0].Items))
	}
}

func TestDayOrderViolationsCountsBackwardSteps(t *testing.T) {
	fwd := []store.ItineraryItem{ritem(0, "a", 1, "X"), ritem(1, "b", 2, "X"), ritem(2, "c", 3, "X")}
	if n := dayOrderViolations(fwd); n != 0 {
		t.Fatalf("ascending days have no violations, got %d", n)
	}
	back := []store.ItineraryItem{ritem(0, "a", 3, "X"), ritem(1, "b", 1, "X"), ritem(2, "c", 2, "X")}
	if n := dayOrderViolations(back); n != 1 {
		t.Fatalf("one backward step, got %d", n)
	}
}
