package main

import (
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// item builds a stored itinerary row the way GetItineraryItemsByTrip returns
// it. day 0 means unscheduled (nil); city/dayTripFrom "" mean unset.
func item(name string, day int, city, dayTripFrom string) store.ItineraryItem {
	it := store.ItineraryItem{Name: name, Latitude: 1, Longitude: 1}
	if day > 0 {
		d := int32(day)
		it.Day = &d
	}
	if city != "" {
		it.City = &city
	}
	if dayTripFrom != "" {
		it.DayTripFrom = &dayTripFrom
	}
	return it
}

func intPtr(v int) *int { return &v }

func itemNames(locs []map[string]any) []string {
	out := make([]string, len(locs))
	for i, l := range locs {
		out[i], _ = l["name"].(string)
	}
	return out
}

func assertOrder(t *testing.T, got []map[string]any, want []string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("order = %v, want %v", itemNames(got), want)
	}
	for i, n := range itemNames(got) {
		if n != want[i] {
			t.Fatalf("order = %v, want %v", itemNames(got), want)
		}
	}
}

// --- hubOfItem ---

func TestHubOfItemPrefersDayTripHub(t *testing.T) {
	if h := hubOfItem(item("Versailles", 2, "Versailles", "Paris")); h != "Paris" {
		t.Fatalf("hub = %q, want Paris", h)
	}
	if h := hubOfItem(item("Louvre", 1, "Paris", "")); h != "Paris" {
		t.Fatalf("hub = %q, want Paris", h)
	}
	if h := hubOfItem(item("Mystery", 0, "", "")); h != "" {
		t.Fatalf("hub = %q, want empty", h)
	}
}

func TestHubOfItemTrimsWhitespace(t *testing.T) {
	if h := hubOfItem(item("x", 1, " Lisbon ", "")); h != "Lisbon" {
		t.Fatalf("hub = %q, want Lisbon", h)
	}
}

// --- insertPositionForDay ---

func TestInsertPositionForDay(t *testing.T) {
	items := []store.ItineraryItem{
		item("a", 1, "Paris", ""),
		item("b", 1, "Paris", ""),
		item("c", 2, "Paris", ""),
		item("u", 0, "", ""), // unscheduled tail
	}
	cases := []struct {
		name string
		day  *int
		want int
	}{
		{"nil day appends", nil, 4},
		{"end of day 1", intPtr(1), 2},
		{"end of day 2 before unscheduled", intPtr(2), 3},
		{"day past end lands after last dated item", intPtr(9), 3},
	}
	for _, c := range cases {
		if got := insertPositionForDay(items, c.day); got != c.want {
			t.Fatalf("%s: pos = %d, want %d", c.name, got, c.want)
		}
	}
}

func TestInsertPositionForDayEmptyTrip(t *testing.T) {
	if got := insertPositionForDay(nil, intPtr(1)); got != 0 {
		t.Fatalf("pos = %d, want 0", got)
	}
	if got := insertPositionForDay(nil, nil); got != 0 {
		t.Fatalf("pos = %d, want 0", got)
	}
}

// --- spliceSection ---

func parisRome() []store.ItineraryItem {
	return []store.ItineraryItem{
		item("Louvre", 1, "Paris", ""),
		item("Orsay", 1, "Paris", ""),
		item("Versailles", 2, "Versailles", "Paris"),
		item("Colosseum", 3, "Rome", ""),
		item("Forum", 3, "Rome", ""),
	}
}

func TestSpliceSectionDayKeepsOtherDays(t *testing.T) {
	repl := []map[string]any{{"name": "Pompidou", "latitude": 1.0, "longitude": 1.0}}
	got, err := spliceSection(parisRome(), sectionSelector{Scope: "day", Day: intPtr(1)}, repl)
	if err != nil {
		t.Fatal(err)
	}
	assertOrder(t, got, []string{"Pompidou", "Versailles", "Colosseum", "Forum"})
}

func TestSpliceSectionCityFoldsDayTrips(t *testing.T) {
	// City scope on the hub removes its day trips too (Versailles → Paris hub).
	repl := []map[string]any{{"name": "Montmartre", "latitude": 1.0, "longitude": 1.0}}
	got, err := spliceSection(parisRome(), sectionSelector{Scope: "city", City: "paris"}, repl)
	if err != nil {
		t.Fatal(err)
	}
	assertOrder(t, got, []string{"Montmartre", "Colosseum", "Forum"})
}

func TestSpliceSectionDayWithCityDisambiguator(t *testing.T) {
	// Legacy trips can repeat day numbers across cities: two "day 1" blocks.
	items := []store.ItineraryItem{
		item("Louvre", 1, "Paris", ""),
		item("Colosseum", 1, "Rome", ""),
	}
	repl := []map[string]any{{"name": "Pantheon", "latitude": 1.0, "longitude": 1.0}}
	got, err := spliceSection(items, sectionSelector{Scope: "day", Day: intPtr(1), City: "Rome"}, repl)
	if err != nil {
		t.Fatal(err)
	}
	assertOrder(t, got, []string{"Louvre", "Pantheon"})
}

func TestSpliceSectionTripReplacesEverything(t *testing.T) {
	repl := []map[string]any{{"name": "Only", "latitude": 1.0, "longitude": 1.0}}
	got, err := spliceSection(parisRome(), sectionSelector{Scope: "trip"}, repl)
	if err != nil {
		t.Fatal(err)
	}
	assertOrder(t, got, []string{"Only"})
}

func TestSpliceSectionMissErrorsWithValidOptions(t *testing.T) {
	_, err := spliceSection(parisRome(), sectionSelector{Scope: "day", Day: intPtr(9)}, nil)
	if err == nil {
		t.Fatal("expected error for unmatched day")
	}
	for _, want := range []string{"day 9", "Paris", "Rome"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error %q should mention %q", err, want)
		}
	}
	if _, err := spliceSection(parisRome(), sectionSelector{Scope: "city", City: "Lisbon"}, nil); err == nil {
		t.Fatal("expected error for unmatched city")
	}
}

// --- section-membership guard ---

// loc builds an agent replacement location. city/dayTripFrom "" and day 0 mean
// the model left the field out — the common shape from create_itinerary.
func loc(name string, day int, city, dayTripFrom string) map[string]any {
	m := map[string]any{"name": name, "latitude": 1.0, "longitude": 1.0}
	if day > 0 {
		m["day"] = float64(day)
	}
	if city != "" {
		m["city"] = city
	}
	if dayTripFrom != "" {
		m["day_trip_from"] = dayTripFrom
	}
	return m
}

func pragueKrakow() []store.ItineraryItem {
	return []store.ItineraryItem{
		item("Charles Bridge", 1, "Prague", ""),
		item("Old Town Square", 2, "Prague", ""),
		item("Wawel Castle", 3, "Krakow", ""),
		item("Rynek Glowny", 4, "Krakow", ""),
	}
}

// The reported bug, verbatim: asked to swap two cities, the model sends both
// cities' places under a single-city selector. Krakow survives in `out` AND
// arrives in newLocs, so the old code emitted it twice.
func TestSpliceSectionRejectsForeignCityUnderCityScope(t *testing.T) {
	repl := []map[string]any{
		loc("Wawel Castle", 1, "Krakow", ""),
		loc("Rynek Glowny", 2, "Krakow", ""),
		loc("Charles Bridge", 3, "Prague", ""),
		loc("Old Town Square", 4, "Prague", ""),
	}
	_, err := spliceSection(pragueKrakow(), sectionSelector{Scope: "city", City: "Prague"}, repl)
	if err == nil {
		t.Fatal("a city rewrite carrying another city's places must be rejected")
	}
	for _, want := range []string{"Krakow", "scope 'trip'", "Wawel Castle", "nothing was changed"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error %q should mention %q", err, want)
		}
	}
}

func TestSpliceSectionRejectsForeignDayUnderDayScope(t *testing.T) {
	repl := []map[string]any{loc("Pompidou", 1, "Paris", ""), loc("Colosseum", 3, "Rome", "")}
	_, err := spliceSection(parisRome(), sectionSelector{Scope: "day", Day: intPtr(1)}, repl)
	if err == nil {
		t.Fatal("a day rewrite carrying another day's places must be rejected")
	}
	if !strings.Contains(err.Error(), "day 3") {
		t.Fatalf("error %q should name the stray's own day", err)
	}
}

// City scope spans days, so re-dating within the city is a legitimate edit the
// guard must not block.
func TestSpliceSectionCityScopeAllowsDayRewrite(t *testing.T) {
	repl := []map[string]any{
		loc("Louvre", 4, "Paris", ""),
		loc("Orsay", 5, "Paris", ""),
		loc("Versailles", 6, "Versailles", "Paris"),
	}
	if _, err := spliceSection(parisRome(), sectionSelector{Scope: "city", City: "Paris"}, repl); err != nil {
		t.Fatalf("re-dating within a city is legitimate: %v", err)
	}
}

func TestSpliceSectionCityScopeAllowsDayTripByHub(t *testing.T) {
	ok := []map[string]any{loc("Versailles", 2, "Versailles", "Paris")}
	if _, err := spliceSection(parisRome(), sectionSelector{Scope: "city", City: "Paris"}, ok); err != nil {
		t.Fatalf("a day trip belongs to its hub: %v", err)
	}
	// Same place without the hub tag reads as another city — rejected, and the
	// error must name the field that fixes it.
	bad := []map[string]any{loc("Versailles", 2, "Versailles", "")}
	err := spliceSection2Err(t, parisRome(), sectionSelector{Scope: "city", City: "Paris"}, bad)
	if !strings.Contains(err.Error(), "day_trip_from") {
		t.Fatalf("error %q should point at day_trip_from", err)
	}
}

// The shape every existing caller sends: no city, no day. Omission is not
// evidence of anything, so these must pass under both scopes.
func TestSpliceSectionAcceptsUnspecifiedCityAndDay(t *testing.T) {
	repl := []map[string]any{loc("Pompidou", 0, "", "")}
	if _, err := spliceSection(parisRome(), sectionSelector{Scope: "day", Day: intPtr(1)}, repl); err != nil {
		t.Fatalf("day scope, unspecified loc: %v", err)
	}
	if _, err := spliceSection(parisRome(), sectionSelector{Scope: "city", City: "Paris"}, repl); err != nil {
		t.Fatalf("city scope, unspecified loc: %v", err)
	}
}

func TestSpliceSectionFoldsDiacritics(t *testing.T) {
	items := []store.ItineraryItem{item("Wawel Castle", 1, "Kraków", "")}
	repl := []map[string]any{loc("Sukiennice", 1, "Krakow", "")}
	got, err := spliceSection(items, sectionSelector{Scope: "city", City: "KRAKOW"}, repl)
	if err != nil {
		t.Fatalf("Kraków and Krakow are one city: %v", err)
	}
	assertOrder(t, got, []string{"Sukiennice"})
}

// scope 'trip' is the escape hatch the rejection points at, so it must stay
// unguarded — it replaces everything and cannot duplicate.
func TestSpliceSectionTripScopeAcceptsAnyCity(t *testing.T) {
	repl := []map[string]any{loc("Wawel Castle", 1, "Krakow", ""), loc("Charles Bridge", 2, "Prague", "")}
	got, err := spliceSection(pragueKrakow(), sectionSelector{Scope: "trip"}, repl)
	if err != nil {
		t.Fatal(err)
	}
	assertOrder(t, got, []string{"Wawel Castle", "Charles Bridge"})
}

// keyOfLocation must coerce `day` exactly as the writer does, or the guard could
// reject on a value itemParamsFromLocation would have ignored.
func TestKeyOfLocationMatchesWriterDayCoercion(t *testing.T) {
	for _, raw := range []any{float64(0), float64(-1), "3", nil} {
		if k := keyOfLocation(map[string]any{"day": raw}); k.Day != nil {
			t.Fatalf("day %#v should read as unspecified, got %d", raw, *k.Day)
		}
		p := itemParamsFromLocation(uuid.New(), 0, map[string]any{"name": "x", "day": raw})
		if p.Day != nil {
			t.Fatalf("writer kept day %#v; guard and writer disagree", raw)
		}
	}
	if k := keyOfLocation(map[string]any{"day": float64(2)}); k.Day == nil || *k.Day != 2 {
		t.Fatal("day 2 should read as 2")
	}
}

func spliceSection2Err(t *testing.T, items []store.ItineraryItem, sel sectionSelector, locs []map[string]any) error {
	t.Helper()
	_, err := spliceSection(items, sel, locs)
	if err == nil {
		t.Fatal("expected a rejection")
	}
	return err
}

func TestSpliceSectionValidatesSelector(t *testing.T) {
	if _, err := spliceSection(parisRome(), sectionSelector{Scope: "day"}, nil); err == nil {
		t.Fatal("scope day without day number should error")
	}
	if _, err := spliceSection(parisRome(), sectionSelector{Scope: "city"}, nil); err == nil {
		t.Fatal("scope city without city should error")
	}
	if _, err := spliceSection(parisRome(), sectionSelector{Scope: "week"}, nil); err == nil {
		t.Fatal("unknown scope should error")
	}
}

func TestSpliceSectionKeptItemsPreserveTags(t *testing.T) {
	cat, tod := "attraction", "morning"
	items := parisRome()
	items[3].Category = &cat
	items[3].TimeOfDay = &tod
	got, err := spliceSection(items, sectionSelector{Scope: "day", Day: intPtr(1)},
		[]map[string]any{{"name": "Pompidou", "latitude": 1.0, "longitude": 1.0}})
	if err != nil {
		t.Fatal(err)
	}
	var colosseum map[string]any
	for _, l := range got {
		if l["name"] == "Colosseum" {
			colosseum = l
		}
	}
	if colosseum == nil {
		t.Fatal("Colosseum missing from spliced result")
	}
	if colosseum["category"] != "attraction" || colosseum["time_of_day"] != "morning" ||
		colosseum["city"] != "Rome" || colosseum["day"] != float64(3) {
		t.Fatalf("kept item lost tags: %+v", colosseum)
	}
}

// Round-trip: locationFromItem output must coerce back losslessly.
func TestLocationFromItemRoundTrip(t *testing.T) {
	src := item("Versailles", 2, "Versailles", "Paris")
	pid, addr := "pid-1", "Place d'Armes"
	src.PlaceID = &pid
	src.Address = &addr
	params := itemParamsFromLocation(src.TripID, 0, locationFromItem(src))
	if params.Name != "Versailles" || params.PlaceID == nil || *params.PlaceID != "pid-1" ||
		params.Address == nil || *params.Address != addr ||
		params.City == nil || *params.City != "Versailles" ||
		params.DayTripFrom == nil || *params.DayTripFrom != "Paris" ||
		params.Day == nil || *params.Day != 2 {
		t.Fatalf("round trip lost fields: %+v", params)
	}
}

// Attribution snapshots must survive a section rewrite: locationFromItem
// carries them and itemParamsFromLocation coerces them back (specs/add-to-itinerary).
func TestLocationFromItemRoundTripsAttribution(t *testing.T) {
	src := item("Tasca da Ana", 1, "Lisbon", "")
	name := "Ana"
	src.LocalSourceName = &name
	recID := uuid.MustParse("6ba7b810-9dad-11d1-80b4-00c04fd430c8")
	src.LocalRecommendationID = pgtype.UUID{Bytes: recID, Valid: true}

	params := itemParamsFromLocation(src.TripID, 0, locationFromItem(src))
	if params.LocalSourceName == nil || *params.LocalSourceName != "Ana" {
		t.Fatalf("local_source_name lost: %+v", params.LocalSourceName)
	}
	if !params.LocalRecommendationID.Valid || params.LocalRecommendationID.Bytes != recID {
		t.Fatalf("local_recommendation_id lost: %+v", params.LocalRecommendationID)
	}

	// Unattributed items stay unattributed (no empty-string snapshots).
	plain := itemParamsFromLocation(src.TripID, 0, locationFromItem(item("Louvre", 1, "Paris", "")))
	if plain.LocalSourceName != nil || plain.LocalRecommendationID.Valid {
		t.Fatalf("plain item grew attribution: %+v %+v", plain.LocalSourceName, plain.LocalRecommendationID)
	}
}
