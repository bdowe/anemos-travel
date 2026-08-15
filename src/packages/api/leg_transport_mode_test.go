package main

import (
	"testing"

	"travel-route-planner/store"
)

// Real coordinates, so the fixture table below is a claim about the world and
// not about arithmetic. Each is the city centre to 4dp.
var testCityCoords = map[string][2]float64{
	"Rome":         {41.9028, 12.4964},
	"Florence":     {43.7696, 11.2558},
	"Venice":       {45.4408, 12.3155},
	"Milan":        {45.4642, 9.1900},
	"Naples":       {40.8518, 14.2681},
	"Palermo":      {38.1157, 13.3615},
	"Catania":      {37.5079, 15.0830},
	"Capri":        {40.5532, 14.2222},
	"Madrid":       {40.4168, -3.7038},
	"Barcelona":    {41.3851, 2.1734},
	"Palma":        {39.5696, 2.6502},
	"London":       {51.5074, -0.1278},
	"Paris":        {48.8566, 2.3522},
	"Amsterdam":    {52.3676, 4.9041},
	"Berlin":       {52.5200, 13.4050},
	"Munich":       {48.1351, 11.5820},
	"Dublin":       {53.3498, -6.2603},
	"Belfast":      {54.5973, -5.9301},
	"Tokyo":        {35.6762, 139.6503},
	"Kyoto":        {35.0116, 135.7681},
	"Athens":       {37.9838, 23.7275},
	"Thessaloniki": {40.6401, 22.9444},
	"Santorini":    {36.3932, 25.4615},
	"Corfu":        {39.6243, 19.9217},
	"Bari":         {41.1171, 16.8719},
	"New York":     {40.7128, -74.0060},
	"Los Angeles":  {34.0522, -118.2437},
}

func testEndpoint(t *testing.T, label string) legEndpoint {
	t.Helper()
	c, ok := testCityCoords[label]
	if !ok {
		t.Fatalf("no test coordinates for %q", label)
	}
	lat, lng := c[0], c[1]
	return legEndpoint{Label: label, Lat: &lat, Lng: &lng}
}

// TestGeoLegMode pins what geography alone says about a leg. "" means "no
// opinion", which resolveLegMode turns into the flight default — so every ""
// row here is a leg that behaves exactly as it did before 00068.
func TestGeoLegMode(t *testing.T) {
	cases := []struct {
		origin, dest string
		want         string
		why          string
	}{
		// Short hops inside a rail region.
		{"Rome", "Florence", "train", "the reported bug: 1h35 by Frecciarossa"},
		{"Florence", "Venice", "train", ""},
		{"Rome", "Venice", "train", ""},
		{"Rome", "Milan", "train", "477km, inside the 550 threshold"},
		{"Naples", "Rome", "train", ""},
		{"Madrid", "Barcelona", "train", "505km, just inside"},
		{"Munich", "Berlin", "train", "504km, just inside"},
		{"London", "Paris", "train", "Great Britain is not an island group: Eurostar"},
		{"Paris", "Amsterdam", "train", ""},
		{"Athens", "Thessaloniki", "train", "Greek mainland pair is not a ferry"},
		{"Tokyo", "Kyoto", "train", "the second rail region"},
		{"Palermo", "Catania", "train", "same island, so ground is fine"},
		{"Dublin", "Belfast", "train", "same island, so ground is fine"},

		// Too far: the threshold is deliberately conservative.
		{"Amsterdam", "Berlin", "", "577km, over the threshold"},
		{"New York", "Los Angeles", "", "no rail region"},

		// Sea crossings: exactly one endpoint on an island, or two islands.
		{"Rome", "Palermo", "", "Sicily is not reachable by road"},
		{"Naples", "Capri", "", "a crossing we cannot route: not a Greek port"},
		{"Barcelona", "Palma", "", "the Balearics"},
		{"London", "Dublin", "", "different islands"},
		{"Corfu", "Bari", "", "Greek island to the Italian mainland"},
	}
	for _, tc := range cases {
		t.Run(tc.origin+"->"+tc.dest, func(t *testing.T) {
			got := geoLegMode(testEndpoint(t, tc.origin), testEndpoint(t, tc.dest))
			if got != tc.want {
				t.Errorf("geoLegMode(%s, %s) = %q, want %q (%s)", tc.origin, tc.dest, got, tc.want, tc.why)
			}
			// Geography is symmetric; a leg home must read like the leg out.
			if back := geoLegMode(testEndpoint(t, tc.dest), testEndpoint(t, tc.origin)); back != got {
				t.Errorf("not symmetric: %s->%s = %q but %s->%s = %q",
					tc.origin, tc.dest, got, tc.dest, tc.origin, back)
			}
		})
	}
}

// TestGeoLegModeNeedsBothCoordinates is the home-leg case: an endpoint that is
// an airport code or free text has no coordinate, so geography stays silent and
// the leg keeps the flight default. Losing this is how "EWR → Amsterdam" would
// become a train.
func TestGeoLegModeNeedsBothCoordinates(t *testing.T) {
	amsterdam := testEndpoint(t, "Amsterdam")
	for _, tc := range []struct {
		name         string
		origin, dest legEndpoint
	}{
		{"no origin coords", legEndpoint{Label: "EWR"}, amsterdam},
		{"no destination coords", amsterdam, legEndpoint{Label: "EWR"}},
		{"neither", legEndpoint{Label: "EWR"}, legEndpoint{Label: "ALB"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := geoLegMode(tc.origin, tc.dest); got != "" {
				t.Errorf("geoLegMode = %q, want \"\" (no coordinates, no opinion)", got)
			}
		})
	}
}

// TestResolveLegModeLadder pins the precedence between the rungs — which is
// the part a later reader is most likely to get backwards.
func TestResolveLegModeLadder(t *testing.T) {
	trip := func(travelMode string) store.Trip {
		if travelMode == "" {
			return store.Trip{}
		}
		return store.Trip{TravelMode: &travelMode}
	}
	cases := []struct {
		name         string
		trip         store.Trip
		origin, dest string
		override     *string
		want         string
	}{
		{"geography fills the old flight default", trip(""), "Rome", "Florence", nil, "train"},
		{"an override beats geography", trip(""), "Rome", "Florence", ptrTo("car"), "car"},
		{"an override beats a ferry pair", trip(""), "Athens", "Santorini", ptrTo("flight"), "flight"},
		{"a bookable ferry pair beats a stated car trip", trip("car"), "Athens", "Santorini", nil, "ferry"},
		{"a stated car trip beats geography", trip("car"), "Rome", "Florence", nil, "car"},
		{"a stated flight trip beats geography", trip("flight"), "Rome", "Florence", nil, "flight"},
		{"'mixed' is not a mode, so geography answers", trip("mixed"), "Rome", "Florence", nil, "train"},
		{"'mixed' with nothing to say still flies", trip("mixed"), "New York", "Los Angeles", nil, "flight"},
		{"an unknown override is ignored", trip(""), "Rome", "Florence", ptrTo("teleport"), "train"},
		{"the floor is still flight", trip(""), "New York", "Los Angeles", nil, "flight"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := resolveLegMode(tc.trip, testEndpoint(t, tc.origin), testEndpoint(t, tc.dest), tc.override)
			if got != tc.want {
				t.Errorf("resolveLegMode = %q, want %q", got, tc.want)
			}
			if !allowedLegModes[got] {
				t.Errorf("resolveLegMode returned %q, which is not an allowed leg mode", got)
			}
		})
	}
}

// TestResolveLegModeHomeLegStaysAFlight is the whole-ladder version of the
// coordinate rule: the two derived home legs must survive this feature
// unchanged, because their outer endpoint is an airport.
func TestResolveLegModeHomeLegStaysAFlight(t *testing.T) {
	got := resolveLegMode(store.Trip{}, legEndpoint{Label: "EWR"}, testEndpoint(t, "Rome"), nil)
	if got != "flight" {
		t.Errorf("home leg resolved to %q, want flight", got)
	}
}

// TestIsGreekFerryPairNeedsBothPorts documents the AND, and that the set is
// ferryPortCode's — the ports we can actually build a route link for. The OR
// version of this test in checkTransit called Athens → Rome a ferry.
func TestIsGreekFerryPairNeedsBothPorts(t *testing.T) {
	cases := []struct {
		origin, dest string
		want         bool
	}{
		{"Athens", "Santorini", true},
		{"Santorini", "Naxos", true},
		{"Santorini, Greece", "Mykonos", true},
		{"Athens", "Rome", false},
		{"Athens", "Thessaloniki", false},
		{"Rome", "Florence", false},
	}
	for _, tc := range cases {
		if got := isGreekFerryPair(tc.origin, tc.dest); got != tc.want {
			t.Errorf("isGreekFerryPair(%q, %q) = %v, want %v", tc.origin, tc.dest, got, tc.want)
		}
	}
}

// TestIslandGroup covers the matcher, including the ", Country" suffix form
// every other label matcher here accepts.
func TestIslandGroup(t *testing.T) {
	cases := []struct{ label, want string }{
		{"Palermo", "sicily"},
		{"Catania, Italy", "sicily"},
		{"  DUBLIN  ", "ireland"},
		{"Belfast", "ireland"},
		{"Palma de Mallorca", "balearics"},
		{"Rome", ""},
		{"London", ""},
		{"", ""},
	}
	for _, tc := range cases {
		if got := islandGroup(tc.label); got != tc.want {
			t.Errorf("islandGroup(%q) = %q, want %q", tc.label, got, tc.want)
		}
	}
}

// TestLegCoordIndex pins the two rules a caller depends on: labels are matched
// case-insensitively, and a revisited city (Rome … Florence … Rome) resolves to
// its first leg rather than shadowing it.
func TestLegCoordIndex(t *testing.T) {
	lat1, lng1 := 41.9028, 12.4964
	lat2, lng2 := 43.7696, 11.2558
	lat3, lng3 := 41.0, 12.0
	idx := legCoordIndex([]RenderLeg{
		{Key: "Rome", Label: "Rome", Lat: &lat1, Lng: &lng1},
		{Key: "Florence", Label: "Florence", Lat: &lat2, Lng: &lng2},
		{Key: "Rome#2", Label: "Rome", Lat: &lat3, Lng: &lng3},
		{Key: "Other places", Label: "Other places"}, // no coords: skipped
	})
	if len(idx) != 2 {
		t.Fatalf("indexed %d labels, want 2", len(idx))
	}
	got := legEndpointFrom("rome", idx)
	if got.Lat == nil || *got.Lat != lat1 {
		t.Errorf("revisited city resolved to %v, want the first leg's %v", got.Lat, lat1)
	}
	if e := legEndpointFrom("Nowhere", idx); e.Lat != nil {
		t.Errorf("unknown label got coordinates: %v", e.Lat)
	}
}
