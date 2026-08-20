package main

// spliceLeg's whole job is to hold ONE invariant: the replaced leg keeps the
// trip-day span it had, because both ends of that span are SHARED with the
// neighbouring cities and are what date them. Everything here is a way of
// asking whether it still does.
//
// Pure, so none of it needs Postgres — the discipline planTripRepair follows.
// The end-to-end assertions (dates and night counts of every other city,
// byte-identical, before and after a real swap) live in
// replace_leg_integration_test.go, which also runs the SAME swap through the
// pre-replace_leg path so the regression this tool exists to fix is visible
// failing rather than asserted from memory.

import (
	"fmt"
	"strings"
	"testing"

	"travel-route-planner/store"
)

// rlSeed is one stored itinerary item, spelled short.
type rlSeed struct {
	name        string
	city        string
	dayTripFrom string
	timeOfDay   string
	day         int
}

func rlItems(seeds ...rlSeed) []store.ItineraryItem {
	out := make([]store.ItineraryItem, len(seeds))
	for i, s := range seeds {
		it := store.ItineraryItem{
			Position: int32(i),
			Name:     s.name,
			// Distinct coordinates per item: reorderItineraryByDistance keeps
			// Claude's order for coordinate-less blocks, and a test that only
			// passes because the optimizer bailed out is not a test.
			Latitude:  50 + float64(i)*0.01,
			Longitude: 10 + float64(i)*0.01,
		}
		if s.city != "" {
			c := s.city
			it.City = &c
		}
		if s.dayTripFrom != "" {
			h := s.dayTripFrom
			it.DayTripFrom = &h
		}
		if s.timeOfDay != "" {
			tod := s.timeOfDay
			it.TimeOfDay = &tod
		}
		if s.day > 0 {
			d := int32(s.day)
			it.Day = &d
		}
		out[i] = it
	}
	return out
}

// place builds one submitted location. `extra` lets a case add the fields the
// server is supposed to ignore or enforce.
func rlPlace(name string, extra map[string]any) map[string]any {
	loc := map[string]any{"name": name, "latitude": 44.8, "longitude": 20.4}
	for k, v := range extra {
		loc[k] = v
	}
	return loc
}

// locDay / locHub / locTOD read a spliced location back.
func locDay(loc map[string]any) int {
	d, _ := loc["day"].(float64)
	return int(d)
}

func locHub(loc map[string]any) string { return keyOfLocation(loc).Hub }

func locTOD(loc map[string]any) string {
	s, _ := loc["time_of_day"].(string)
	return s
}

// names lists a spliced list's place names, in order.
func locNames(locs []map[string]any) []string {
	out := make([]string, len(locs))
	for i, l := range locs {
		out[i], _ = l["name"].(string)
	}
	return out
}

// europeTrip is the shape the 2026-08-20 dogfood failure happened on, cut down
// to four cities: a spine, two dated places per city, and the move day shared
// between neighbours (the leaving city's morning place and the arriving city's
// afternoon place carry the SAME day number).
//
//	Amsterdam  days 1-4      Copenhagen days 4-7
//	Oslo       days 7-10     Stockholm  days 10-12
func europeTrip() []store.ItineraryItem {
	return rlItems(
		rlSeed{name: "Rijksmuseum", city: "Amsterdam", day: 1, timeOfDay: "afternoon"},
		rlSeed{name: "Jordaan walk", city: "Amsterdam", day: 4, timeOfDay: "morning"},
		rlSeed{name: "Nyhavn", city: "Copenhagen", day: 4, timeOfDay: "evening"},
		rlSeed{name: "Torvehallerne", city: "Copenhagen", day: 7, timeOfDay: "morning"},
		rlSeed{name: "Opera House", city: "Oslo", day: 7, timeOfDay: "evening"},
		rlSeed{name: "Vigeland Park", city: "Oslo", day: 10, timeOfDay: "morning"},
		rlSeed{name: "Vasa Museum", city: "Stockholm", day: 10, timeOfDay: "evening"},
		rlSeed{name: "Gamla Stan", city: "Stockholm", day: 12, timeOfDay: "morning"},
	)
}

// belgrade is the replacement payload a well-behaved model sends: two places,
// visit order, no day numbers.
func belgrade() []map[string]any {
	return []map[string]any{
		rlPlace("Kalemegdan", map[string]any{"city": "Belgrade"}),
		rlPlace("Skadarlija", map[string]any{"city": "Belgrade"}),
	}
}

func TestParseLegAddress(t *testing.T) {
	cases := []struct {
		in        string
		wantHub   string
		wantVisit int
	}{
		{"Copenhagen", "Copenhagen", 0},
		{"  Copenhagen  ", "Copenhagen", 0},
		{"Paris#2", "Paris", 2},
		{"Paris #2", "Paris", 2},
		{"Paris#1", "Paris", 1},
		// Not a visit suffix: leave the name alone rather than mangle it.
		{"Paris#", "Paris#", 0},
		{"Paris#0", "Paris#0", 0},
		{"Paris#x", "Paris#x", 0},
		{"#2", "#2", 0},
	}
	for _, tc := range cases {
		got := parseLegAddress(tc.in)
		if got.hub != tc.wantHub || got.visit != tc.wantVisit {
			t.Errorf("parseLegAddress(%q) = %+v, want {%q %d}", tc.in, got, tc.wantHub, tc.wantVisit)
		}
	}
}

// The day assignment, on its own. The two things that must hold for ANY input
// are that the first place lands on the arrival day and the last on the move-on
// day — those are the two days shared with the neighbours — and that the
// sequence never runs backwards.
func TestLegDayFor(t *testing.T) {
	cases := []struct {
		n, first, last int
		want           []int
	}{
		// The spine: two places, both boundary days covered, middle empty.
		{2, 4, 7, []int{4, 7}},
		{1, 4, 4, []int{4}},
		// A zero-night stop: one day is both ends.
		{3, 6, 6, []int{6, 6, 6}},
		{3, 4, 7, []int{4, 6, 7}},
		{4, 4, 7, []int{4, 5, 6, 7}},
		{5, 4, 5, []int{4, 4, 5, 5, 5}},
		{8, 4, 7, []int{4, 4, 5, 5, 6, 6, 7, 7}},
		{2, 1, 12, []int{1, 12}},
	}
	for _, tc := range cases {
		got := make([]int, tc.n)
		for i := range got {
			got[i] = legDayFor(i, tc.n, tc.first, tc.last)
		}
		if fmt.Sprint(got) != fmt.Sprint(tc.want) {
			t.Errorf("legDayFor n=%d [%d..%d] = %v, want %v", tc.n, tc.first, tc.last, got, tc.want)
		}
		if got[0] != tc.first {
			t.Errorf("n=%d [%d..%d]: first place on day %d, not the arrival day", tc.n, tc.first, tc.last, got[0])
		}
		if got[len(got)-1] != tc.last {
			t.Errorf("n=%d [%d..%d]: last place on day %d, not the move-on day", tc.n, tc.first, tc.last, got[len(got)-1])
		}
		for i := 1; i < len(got); i++ {
			if got[i] < got[i-1] {
				t.Errorf("n=%d [%d..%d]: days run backwards at %d: %v", tc.n, tc.first, tc.last, i, got)
			}
		}
	}
}

// The headline case, at splice level: Copenhagen out, Belgrade in, and NOTHING
// else in the list moves — same names, same positions, same day numbers for
// every other city.
func TestSpliceLegReplacesRunInPlace(t *testing.T) {
	items := europeTrip()
	got, err := spliceLeg(items, "Copenhagen", "Belgrade", belgrade())
	if err != nil {
		t.Fatalf("spliceLeg: %v", err)
	}
	if got.FirstDay != 4 || got.LastDay != 7 {
		t.Fatalf("span = %d-%d, want 4-7 (the days Copenhagen held)", got.FirstDay, got.LastDay)
	}
	if got.OldHub != "Copenhagen" || got.NewHub != "Belgrade" || got.SameCity() {
		t.Fatalf("hubs = %q -> %q (same=%v)", got.OldHub, got.NewHub, got.SameCity())
	}
	if got.Replaced != 2 {
		t.Fatalf("Replaced = %d, want 2", got.Replaced)
	}
	wantNames := []string{
		"Rijksmuseum", "Jordaan walk", "Kalemegdan", "Skadarlija",
		"Opera House", "Vigeland Park", "Vasa Museum", "Gamla Stan",
	}
	if fmt.Sprint(locNames(got.Locations)) != fmt.Sprint(wantNames) {
		t.Fatalf("order = %v, want %v", locNames(got.Locations), wantNames)
	}
	// Every neighbouring place keeps the exact day it had. This is the
	// assertion the whole tool exists for.
	wantDays := map[string]int{
		"Rijksmuseum": 1, "Jordaan walk": 4,
		"Kalemegdan": 4, "Skadarlija": 7,
		"Opera House": 7, "Vigeland Park": 10,
		"Vasa Museum": 10, "Gamla Stan": 12,
	}
	for _, loc := range got.Locations {
		name, _ := loc["name"].(string)
		if d := locDay(loc); d != wantDays[name] {
			t.Errorf("%s on day %d, want %d", name, d, wantDays[name])
		}
	}
	// The shared days read like what they are: the arrival is afternoon or
	// evening (beside Amsterdam's morning place on day 4), the move-on is
	// morning (beside Oslo's evening arrival on day 7).
	if tod := locTOD(got.Locations[2]); tod != "afternoon" && tod != "evening" {
		t.Errorf("arrival place time_of_day = %q, want afternoon/evening", tod)
	}
	if tod := locTOD(got.Locations[3]); tod != "morning" {
		t.Errorf("move-on place time_of_day = %q, want morning", tod)
	}
}

// The model is told the server assigns days. It will send them anyway — its
// habit from create_itinerary and update_itinerary_section is to author every
// one. Accepting them is the bug this tool was built to remove, so the day
// values here are deliberately WRONG (a whole-trip renumber of the kind that
// moved two legs on 2026-08-20) and must have no effect whatsoever.
func TestSpliceLegIgnoresCallerDays(t *testing.T) {
	items := europeTrip()
	places := []map[string]any{
		rlPlace("Kalemegdan", map[string]any{"city": "Belgrade", "day": float64(1)}),
		rlPlace("Skadarlija", map[string]any{"city": "Belgrade", "day": float64(99)}),
	}
	got, err := spliceLeg(items, "Copenhagen", "Belgrade", places)
	if err != nil {
		t.Fatalf("spliceLeg: %v", err)
	}
	if fmt.Sprint(got.Days) != fmt.Sprint([]int{4, 7}) {
		t.Fatalf("days = %v, want [4 7] — the caller's 1 and 99 were used", got.Days)
	}
	// And the caller's own maps are not mutated: spliceLeg is pure, and a
	// caller that retries after an error must send the same thing twice.
	if places[0]["day"] != float64(1) || places[1]["day"] != float64(99) {
		t.Fatalf("caller's places were mutated: %v", places)
	}
}

// A hub in two runs is a genuine revisit, not corruption (planTripRepair goes
// out of its way to say so). #2 addresses the second one and the first must
// come through untouched.
func TestSpliceLegAddressesTheRequestedVisit(t *testing.T) {
	items := rlItems(
		rlSeed{name: "Louvre", city: "Paris", day: 1},
		rlSeed{name: "Marais", city: "Paris", day: 3},
		rlSeed{name: "Colosseum", city: "Rome", day: 3},
		rlSeed{name: "Trastevere", city: "Rome", day: 6},
		rlSeed{name: "Sacre-Coeur", city: "Paris", day: 6},
		rlSeed{name: "Rue Cler", city: "Paris", day: 8},
	)
	got, err := spliceLeg(items, "Paris#2", "Lyon", []map[string]any{
		rlPlace("Vieux Lyon", map[string]any{"city": "Lyon"}),
		rlPlace("Les Halles", map[string]any{"city": "Lyon"}),
	})
	if err != nil {
		t.Fatalf("spliceLeg: %v", err)
	}
	wantNames := []string{"Louvre", "Marais", "Colosseum", "Trastevere", "Vieux Lyon", "Les Halles"}
	if fmt.Sprint(locNames(got.Locations)) != fmt.Sprint(wantNames) {
		t.Fatalf("order = %v, want %v — the wrong Paris was replaced", locNames(got.Locations), wantNames)
	}
	if got.FirstDay != 6 || got.LastDay != 8 {
		t.Fatalf("span = %d-%d, want 6-8", got.FirstDay, got.LastDay)
	}
	// #1 is accepted for symmetry even though computeTripLegs spells the first
	// visit bare — a model that learned "#2" from an error message will try it.
	first, err := spliceLeg(items, "Paris#1", "Lyon", []map[string]any{
		rlPlace("Vieux Lyon", map[string]any{"city": "Lyon"}),
		rlPlace("Les Halles", map[string]any{"city": "Lyon"}),
	})
	if err != nil {
		t.Fatalf("spliceLeg #1: %v", err)
	}
	if first.FirstDay != 1 || first.LastDay != 3 {
		t.Fatalf("#1 span = %d-%d, want 1-3", first.FirstDay, first.LastDay)
	}
}

// A bare name that matches two runs is answered with a question, never a guess:
// replacing the wrong Paris deletes places nobody asked about.
func TestSpliceLegRefusesAmbiguousRevisit(t *testing.T) {
	items := rlItems(
		rlSeed{name: "Louvre", city: "Paris", day: 1},
		rlSeed{name: "Marais", city: "Paris", day: 3},
		rlSeed{name: "Colosseum", city: "Rome", day: 3},
		rlSeed{name: "Trastevere", city: "Rome", day: 6},
		rlSeed{name: "Sacre-Coeur", city: "Paris", day: 6},
		rlSeed{name: "Rue Cler", city: "Paris", day: 8},
	)
	_, err := spliceLeg(items, "Paris", "Lyon", belgrade())
	if err == nil {
		t.Fatal("an ambiguous city was accepted")
	}
	for _, want := range []string{"visits Paris 2 times", "Paris#1", "Paris#2", "trip days 1-3", "trip days 6-8", "nothing was changed"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error missing %q: %s", want, err)
		}
	}
}

// The first and last legs need no special handling, and this is the test that
// says why: computeTripLegs anchors the first leg's rendered start to the
// trip's start date and the last leg's rendered end to the trip's end date, and
// neither anchor can move while the leg's own day span holds still. So the only
// thing to assert is that the span is preserved there too.
func TestSpliceLegPreservesSpanOnFirstAndLastLegs(t *testing.T) {
	items := europeTrip()
	for _, tc := range []struct {
		city                string
		wantFirst, wantLast int
	}{
		{"Amsterdam", 1, 4},
		{"Stockholm", 10, 12},
	} {
		got, err := spliceLeg(items, tc.city, "Belgrade", belgrade())
		if err != nil {
			t.Fatalf("%s: %v", tc.city, err)
		}
		if got.FirstDay != tc.wantFirst || got.LastDay != tc.wantLast {
			t.Fatalf("%s: span = %d-%d, want %d-%d", tc.city, got.FirstDay, got.LastDay, tc.wantFirst, tc.wantLast)
		}
		if fmt.Sprint(got.Days) != fmt.Sprint([]int{tc.wantFirst, tc.wantLast}) {
			t.Fatalf("%s: days = %v, want [%d %d]", tc.city, got.Days, tc.wantFirst, tc.wantLast)
		}
		if len(got.Locations) != len(items) {
			t.Fatalf("%s: %d locations, want %d", tc.city, len(got.Locations), len(items))
		}
	}
}

// A last leg whose only dated day is its arrival (the spine's shape — the day
// they fly home carries nothing) is the one case where ONE place is enough.
func TestSpliceLegSinglePlaceOnSingleDayLeg(t *testing.T) {
	items := rlItems(
		rlSeed{name: "Rijksmuseum", city: "Amsterdam", day: 1, timeOfDay: "afternoon"},
		rlSeed{name: "Jordaan walk", city: "Amsterdam", day: 4, timeOfDay: "morning"},
		rlSeed{name: "Nyhavn", city: "Copenhagen", day: 4, timeOfDay: "evening"},
	)
	got, err := spliceLeg(items, "Copenhagen", "Belgrade", []map[string]any{
		rlPlace("Kalemegdan", map[string]any{"city": "Belgrade", "time_of_day": "evening"}),
	})
	if err != nil {
		t.Fatalf("spliceLeg: %v", err)
	}
	if got.FirstDay != 4 || got.LastDay != 4 || fmt.Sprint(got.Days) != fmt.Sprint([]int{4}) {
		t.Fatalf("span = %d-%d days=%v, want 4-4 [4]", got.FirstDay, got.LastDay, got.Days)
	}
	// A one-day leg has no separate move-on day, so nothing is forced onto it:
	// inventing "morning" there would be inventing a schedule.
	if tod := locTOD(got.Locations[2]); tod != "evening" {
		t.Fatalf("time_of_day = %q, want the caller's 'evening' left alone", tod)
	}
}

// A leg with two distinct ends cannot be covered by one place: without a place
// on the move-on day the leg renders as though they left the day they arrived,
// and the NEXT city swallows its nights (computeTripLegs' zero-night collapse).
func TestSpliceLegRefusesOnePlaceOnMultiDayLeg(t *testing.T) {
	_, err := spliceLeg(europeTrip(), "Copenhagen", "Belgrade", []map[string]any{
		rlPlace("Kalemegdan", map[string]any{"city": "Belgrade"}),
	})
	if err == nil {
		t.Fatal("a single place covered a 4-day leg")
	}
	for _, want := range []string{"trip days 4-7", "day 7 is the day the traveler moves on", "at least two places", "nothing was changed"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error missing %q: %s", want, err)
		}
	}
}

// A day trip rides its hub: day_trip_from names the new city, so the place
// belongs to the new run even though its own city is somewhere else.
func TestSpliceLegKeepsDayTripsInsideTheRun(t *testing.T) {
	got, err := spliceLeg(europeTrip(), "Copenhagen", "Belgrade", []map[string]any{
		rlPlace("Kalemegdan", map[string]any{"city": "Belgrade"}),
		rlPlace("Petrovaradin Fortress", map[string]any{"city": "Novi Sad", "day_trip_from": "Belgrade"}),
		rlPlace("Skadarlija", map[string]any{"city": "Belgrade"}),
	})
	if err != nil {
		t.Fatalf("spliceLeg: %v", err)
	}
	// hubRuns groups on day_trip_from ?? city, so all three must land in ONE
	// run — a day trip that split the run would fragment the leg, which is the
	// failure this tool makes unreachable.
	runs := hubRuns(runItemsOfLocations(got.Locations))
	var hubs []string
	for _, r := range runs {
		hubs = append(hubs, r.Hub)
	}
	if fmt.Sprint(hubs) != fmt.Sprint([]string{"Amsterdam", "Belgrade", "Oslo", "Stockholm"}) {
		t.Fatalf("runs = %v, want one Belgrade run between Amsterdam and Oslo", hubs)
	}
	if fmt.Sprint(got.Days) != fmt.Sprint([]int{4, 6, 7}) {
		t.Fatalf("days = %v, want [4 6 7]", got.Days)
	}
	// The day trip's own city tag survives — the itinerary still says the
	// fortress is in Novi Sad.
	if locHub(got.Locations[3]) != "Belgrade" {
		t.Fatalf("day trip hub = %q, want Belgrade", locHub(got.Locations[3]))
	}
	if c, _ := got.Locations[3]["city"].(string); c != "Novi Sad" {
		t.Fatalf("day trip city = %q, want Novi Sad", c)
	}
}

// A place tagged with a DIFFERENT city would start its own run inside the leg —
// the fragmentation this tool exists to make unreachable. Rejected, with the
// day-trip escape named, and nothing spliced.
func TestSpliceLegRefusesPlacesFromAnotherCity(t *testing.T) {
	_, err := spliceLeg(europeTrip(), "Copenhagen", "Belgrade", []map[string]any{
		rlPlace("Kalemegdan", map[string]any{"city": "Belgrade"}),
		rlPlace("Rila Monastery", map[string]any{"city": "Sofia", "day": float64(5)}),
		rlPlace("Skadarlija", map[string]any{"city": "Belgrade"}),
	})
	if err == nil {
		t.Fatal("a place from another city was accepted into the leg")
	}
	for _, want := range []string{"1 of the 3 places", "not in Belgrade", "Rila Monastery", "day_trip_from", "Nothing was changed"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error missing %q: %s", want, err)
		}
	}
	// The stray is described as having "no day", not as having the day the
	// model sent. This is where dropping the caller's `day` up front becomes
	// observable: quoting a number the server would have ignored anyway teaches
	// the model that its day numbers mattered, which is the belief this whole
	// tool exists to stop it acting on.
	if !strings.Contains(err.Error(), "(Sofia, no day)") {
		t.Fatalf("stray described with a day the server ignores: %s", err)
	}
}

// A place carrying no city at all is plainly meant for the city being placed —
// tolerant of omission, strict about contradiction, the ONE difference between
// how a stored item and a submitted location are judged.
func TestSpliceLegInheritsMissingCity(t *testing.T) {
	got, err := spliceLeg(europeTrip(), "Copenhagen", "Belgrade", []map[string]any{
		rlPlace("Kalemegdan", nil),
		rlPlace("Skadarlija", nil),
	})
	if err != nil {
		t.Fatalf("spliceLeg: %v", err)
	}
	for _, i := range []int{2, 3} {
		if locHub(got.Locations[i]) != "Belgrade" {
			t.Fatalf("location %d hub = %q, want Belgrade", i, locHub(got.Locations[i]))
		}
	}
}

// Omitting new_city re-places the city with itself. The leg keeps its span and
// its identity, and SameCity is what tells the tool not to clear a stay that is
// still perfectly valid.
func TestSpliceLegSameCityRefill(t *testing.T) {
	got, err := spliceLeg(europeTrip(), "Copenhagen", "", []map[string]any{
		rlPlace("Nyhavn", map[string]any{"city": "Copenhagen"}),
		rlPlace("Tivoli", map[string]any{"city": "Copenhagen"}),
		rlPlace("Torvehallerne", map[string]any{"city": "Copenhagen"}),
	})
	if err != nil {
		t.Fatalf("spliceLeg: %v", err)
	}
	if !got.SameCity() || got.NewHub != "Copenhagen" {
		t.Fatalf("SameCity=%v NewHub=%q, want true/Copenhagen", got.SameCity(), got.NewHub)
	}
	if fmt.Sprint(got.Days) != fmt.Sprint([]int{4, 6, 7}) {
		t.Fatalf("days = %v, want [4 6 7]", got.Days)
	}
}

func TestSpliceLegRefusals(t *testing.T) {
	items := europeTrip()
	cases := []struct {
		name          string
		city, newCity string
		places        []map[string]any
		wants         []string
	}{
		{
			name: "hub not found names the real legs",
			city: "Copenhagn", newCity: "Belgrade", places: belgrade(),
			wants: []string{`no leg for "Copenhagn"`, "Amsterdam (trip days 1-4)", "Copenhagen (trip days 4-7)", "Stockholm (trip days 10-12)", "nothing was changed"},
		},
		{
			name: "visit number past the end",
			city: "Copenhagen#3", newCity: "Belgrade", places: belgrade(),
			wants: []string{"visits Copenhagen 1 time(s)", "no visit #3", "nothing was changed"},
		},
		{
			name: "empty places is a delete wearing an edit's clothes",
			city: "Copenhagen", newCity: "Belgrade", places: nil,
			wants: []string{"would DELETE the Copenhagen leg", "nothing was changed"},
		},
		{
			name: "no city",
			city: "  ", newCity: "Belgrade", places: belgrade(),
			wants: []string{"city is required"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := spliceLeg(items, tc.city, tc.newCity, tc.places)
			if err == nil {
				t.Fatalf("accepted; got %d locations", len(got.Locations))
			}
			if got.Locations != nil {
				t.Fatalf("a refusal returned locations: %v", locNames(got.Locations))
			}
			for _, want := range tc.wants {
				if !strings.Contains(err.Error(), want) {
					t.Fatalf("error missing %q: %s", want, err)
				}
			}
		})
	}
}

// A leg whose places carry no day numbers has no span to preserve, so replacing
// it would hand the new city a GUESSED range (computeTripLegs' auto allocation)
// that reads exactly like a real one. Refuse and say which tool fixes it.
func TestSpliceLegRefusesUndatedLeg(t *testing.T) {
	items := rlItems(
		rlSeed{name: "Rijksmuseum", city: "Amsterdam", day: 1},
		rlSeed{name: "Jordaan walk", city: "Amsterdam", day: 4},
		rlSeed{name: "Nyhavn", city: "Copenhagen"},
	)
	_, err := spliceLeg(items, "Copenhagen", "Belgrade", belgrade())
	if err == nil {
		t.Fatal("an undated leg was replaced")
	}
	for _, want := range []string{"carry no day numbers", "no span to preserve", "set_leg_dates", "Nothing was changed"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error missing %q: %s", want, err)
		}
	}
}

// Replacing a city with one the trip ALREADY visits next door merges the two
// runs — the traveler now spends both stretches there, which is what they
// asked for. Pinned so it reads as a decision rather than an accident: the
// merged leg spans both, and the city AFTER it still does not move.
func TestSpliceLegMergesIntoAnAdjacentSameCity(t *testing.T) {
	got, err := spliceLeg(europeTrip(), "Copenhagen", "Oslo", []map[string]any{
		rlPlace("Akershus Fortress", map[string]any{"city": "Oslo"}),
		rlPlace("Aker Brygge", map[string]any{"city": "Oslo"}),
	})
	if err != nil {
		t.Fatalf("spliceLeg: %v", err)
	}
	rits := runItemsOfLocations(got.Locations)
	runs := hubRuns(rits)
	var hubs []string
	for _, r := range runs {
		hubs = append(hubs, r.Hub)
	}
	if fmt.Sprint(hubs) != fmt.Sprint([]string{"Amsterdam", "Oslo", "Stockholm"}) {
		t.Fatalf("runs = %v, want the two Oslo stretches merged into one", hubs)
	}
	// The merged run runs from the old Copenhagen arrival through Oslo's own
	// move-on day, and Stockholm's boundary day (10) is untouched.
	lo, hi, ok := dayRange(runs[1].slice(rits))
	if !ok || lo != 4 || hi != 10 {
		t.Fatalf("merged Oslo run spans days %d-%d (ok=%v), want 4-10", lo, hi, ok)
	}
	lo, hi, _ = dayRange(runs[2].slice(rits))
	if lo != 10 || hi != 12 {
		t.Fatalf("Stockholm moved: days %d-%d, want 10-12", lo, hi)
	}
}
