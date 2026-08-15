package main

import (
	"strings"
	"testing"
)

// spineLoc builds one create_itinerary location the way the JSON decoder hands
// it over — numbers as float64, which is what itemParamsFromLocation coerces.
func spineLoc(name, city string, day float64) map[string]any {
	loc := map[string]any{"name": name, "latitude": 1.0, "longitude": 2.0}
	if city != "" {
		loc["city"] = city
	}
	if day >= 1 {
		loc["day"] = day
	}
	return loc
}

// A well-formed spine — two places a city except the last, every place dated
// and tagged, both trip dates — writes without complaint. This is the case the
// whole feature produces, so it goes first.
func TestItineraryWriteRefusalAcceptsASpine(t *testing.T) {
	locs := []map[string]any{
		spineLoc("Time Out Market", "Lisbon", 1),
		spineLoc("Pastéis de Belém", "Lisbon", 4),
		spineLoc("Livraria Lello", "Porto", 4),
		spineLoc("Cais da Ribeira", "Porto", 6),
		spineLoc("Museo del Prado", "Madrid", 6),
	}
	if got := itineraryWriteRefusal("2026-09-01", "2026-09-08", locs); got != "" {
		t.Fatalf("a valid spine was refused: %s", got)
	}
}

// The refusal that matters most, because nothing downstream can repair it:
// persistTrip derives a missing end from the highest item day, which on a spine
// is the final city's ARRIVAL. Left alone, a 2026-09-01..09-08 trip saves as
// ending 09-06 and Madrid renders two nights short.
func TestItineraryWriteRefusalRequiresEndDate(t *testing.T) {
	locs := []map[string]any{spineLoc("Museo del Prado", "Madrid", 1)}
	got := itineraryWriteRefusal("2026-09-01", "", locs)
	if got == "" {
		t.Fatal("start_date without end_date was accepted")
	}
	if !strings.Contains(got, "end_date is required") {
		t.Fatalf("refusal does not name the missing field: %s", got)
	}
	// Self-correcting: it must say what the traveler would SEE, not just that a
	// field is missing — the errStraySectionItems shape.
	if !strings.Contains(got, "ARRIVAL day") {
		t.Fatalf("refusal does not explain the consequence: %s", got)
	}
	// An UNDATED draft is a legitimate shape ("Add your destinations" exists for
	// it) and must still write.
	if got := itineraryWriteRefusal("", "", locs); got != "" {
		t.Fatalf("an undated itinerary was refused: %s", got)
	}
}

// A dated trip with an undated place: that leg skips the item-day branch in
// computeTripLegs and falls to the weighted auto-allocation, whose weight is
// the item COUNT — identical for every city in a spine, so the traveler is
// shown an equal split of the trip as though it were the nights they agreed to.
func TestItineraryWriteRefusalRequiresDayOnADatedTrip(t *testing.T) {
	locs := []map[string]any{
		spineLoc("Time Out Market", "Lisbon", 1),
		spineLoc("Livraria Lello", "Porto", 0), // no day
	}
	got := itineraryWriteRefusal("2026-09-01", "2026-09-08", locs)
	if !strings.Contains(got, "Livraria Lello") {
		t.Fatalf("refusal does not name the undated place: %s", got)
	}
	if !strings.Contains(got, "equal share") {
		t.Fatalf("refusal does not explain the consequence: %s", got)
	}
	// Undated trip, undated places: nothing to date, nothing to lie about.
	if got := itineraryWriteRefusal("", "", locs); got != "" {
		t.Fatalf("undated places on an undated trip were refused: %s", got)
	}
}

// The MIX is the failure, not the absence. renderHubOf reads city/day_trip_from
// and parses no addresses, so an untagged place among tagged ones becomes its
// own "Other places" leg and splits the trip. An itinerary with no tags at all
// is one coherent unnamed run — which is what legacy and hand-built trips look
// like, and refusing those would be the over-broad rule.
func TestItineraryWriteRefusalRejectsAMixedHubTagging(t *testing.T) {
	mixed := []map[string]any{
		spineLoc("Time Out Market", "Lisbon", 1),
		spineLoc("Livraria Lello", "", 4), // untagged among tagged
	}
	got := itineraryWriteRefusal("2026-09-01", "2026-09-08", mixed)
	if !strings.Contains(got, "Livraria Lello") {
		t.Fatalf("refusal does not name the untagged place: %s", got)
	}
	if !strings.Contains(got, "its own leg") {
		t.Fatalf("refusal does not explain the consequence: %s", got)
	}

	none := []map[string]any{
		spineLoc("Time Out Market", "", 1),
		spineLoc("Livraria Lello", "", 4),
	}
	if got := itineraryWriteRefusal("2026-09-01", "2026-09-08", none); got != "" {
		t.Fatalf("a wholly untagged itinerary was refused: %s", got)
	}

	// A day trip carries day_trip_from instead of city and is tagged either way.
	dayTrip := []map[string]any{
		spineLoc("Time Out Market", "Lisbon", 1),
		{"name": "Sintra", "latitude": 1.0, "longitude": 2.0, "day": 2.0, "day_trip_from": "Lisbon"},
	}
	if got := itineraryWriteRefusal("2026-09-01", "2026-09-08", dayTrip); got != "" {
		t.Fatalf("a day trip was treated as untagged: %s", got)
	}
}

// The named list is capped so a forty-place payload still returns something a
// model can read, and it must say how many it left out rather than trailing off.
func TestItineraryWriteRefusalCapsTheNamedList(t *testing.T) {
	locs := make([]map[string]any, 0, 9)
	locs = append(locs, spineLoc("Anchor", "Lisbon", 1))
	for i := 0; i < 8; i++ {
		locs = append(locs, spineLoc(string(rune('A'+i))+" place", "Lisbon", 0))
	}
	got := itineraryWriteRefusal("2026-09-01", "2026-09-08", locs)
	if !strings.Contains(got, "and 3 more") {
		t.Fatalf("refusal did not cap and count the list: %s", got)
	}
}

// An unnamed place still has to be identifiable in the refusal, or the model is
// told something is wrong with nothing to act on.
func TestItineraryWriteRefusalNamesUnnamedPlacesByPosition(t *testing.T) {
	locs := []map[string]any{
		spineLoc("Time Out Market", "Lisbon", 1),
		{"latitude": 1.0, "longitude": 2.0, "city": "Porto"},
	}
	got := itineraryWriteRefusal("2026-09-01", "2026-09-08", locs)
	if !strings.Contains(got, "place 2") {
		t.Fatalf("refusal does not locate the unnamed place: %s", got)
	}
}
