package main

// The ONE answer to "how does this trip get from A to B".
//
// Before this file a leg's mode was implicit in its `provider` column — a
// lossy reverse map where `rome2rio` could mean car, train or bus and only
// trips.travel_mode broke the tie (transportSlotMode) — and the fallback at
// every rung was "flight". That is how an Italy trip's Rome → Florence row
// offered a Google Flights link for a 1h35 train: nothing anywhere consulted
// geography, even though every itinerary item carries coordinates (00003, NOT
// NULL) and computeTripLegs already hands each leg a representative one.
//
// Both halves of the fix are here: resolveLegMode is the ladder every consumer
// calls (the booking-todo sync, Trip Health's checkTransit, the model-facing
// leg summary, the set_leg_transport_mode tool), and geoLegMode is its pure
// geographic rung, whose every "no opinion" answer lands on the previous
// behaviour. See docs/zen.md — the mode is now a resolved value with one
// implementation, not a convention spread across a provider string.

import (
	"strings"

	"travel-route-planner/store"
)

// legEndpoint is one end of a transport leg: the label the row shows and the
// leg's representative coordinate (RenderLeg.Lat/Lng). Lat/Lng are nil when
// unknown — the two home legs' outer endpoints are an IATA code or free text
// and have none, which is precisely why they keep the flight default.
type legEndpoint struct {
	Label    string
	Lat, Lng *float64
}

// legEndpointFrom builds an endpoint from a label and the coordinate lookup a
// caller derived from computeTripLegs. A label with no leg (a home airport, a
// hub with only manually-added places) yields a coordinate-less endpoint.
func legEndpointFrom(label string, coords map[string]legEndpoint) legEndpoint {
	if e, ok := coords[strings.ToLower(strings.TrimSpace(label))]; ok {
		return legEndpoint{Label: label, Lat: e.Lat, Lng: e.Lng}
	}
	return legEndpoint{Label: label}
}

// legCoordIndex indexes a trip's rendered legs by lowercased label so a
// transport row's endpoint strings can find their coordinates. Revisited
// cities share a label (their keys differ), so first-in wins — they are the
// same place.
func legCoordIndex(legs []RenderLeg) map[string]legEndpoint {
	out := make(map[string]legEndpoint, len(legs))
	for _, leg := range legs {
		if leg.Lat == nil || leg.Lng == nil {
			continue
		}
		key := strings.ToLower(strings.TrimSpace(leg.Label))
		if key == "" {
			continue
		}
		if _, seen := out[key]; seen {
			continue
		}
		out[key] = legEndpoint{Label: leg.Label, Lat: leg.Lat, Lng: leg.Lng}
	}
	return out
}

// resolveLegMode resolves how a trip moves between two places, highest rung
// first:
//
//  1. override — booking_todos.mode: a choice the traveler made in the row's
//     mode menu, or the planner made with set_leg_transport_mode. Always wins.
//  2. a ferry route we can actually book — two Greek ports (see below).
//     Above the trip's own mode because you cannot drive between islands;
//     trip_review.go has always said exactly this.
//  3. trips.travel_mode when it names a mode — "we're driving", "we're
//     flying". 'mixed' is not a mode, it is the statement that legs differ,
//     so it falls through to geography, which is the whole point of it.
//  4. geography — geoLegMode.
//  5. "flight" — the long-haul default, unchanged.
//
// Every rung except the last is a fact somebody asserted or a coordinate; the
// result is always one of allowedLegModes.
func resolveLegMode(trip store.Trip, origin, dest legEndpoint, override *string) string {
	if m := strings.TrimSpace(strPtrVal(override)); allowedLegModes[m] {
		return m
	}
	if isGreekFerryPair(origin.Label, dest.Label) {
		return "ferry"
	}
	if m := strings.TrimSpace(strPtrVal(trip.TravelMode)); allowedLegModes[m] {
		return m
	}
	if m := geoLegMode(origin, dest); m != "" {
		return m
	}
	return "flight"
}

// isGreekFerryPair reports whether BOTH endpoints resolve to Ferryhopper port
// codes. Deliberately not isGreekLocation, which covers every Greek city the
// events flow knows: Athens → Thessaloniki is a train, not a ferry, and the
// OR-not-AND version of this test in checkTransit called Athens → Rome one
// too. Tying the claim to ferryPortCode also keeps the mode honest about the
// link behind it — outside this set ferryhopperURL degrades to a landing page,
// so a "ferry" we cannot route is worse for the traveler than a flight search.
func isGreekFerryPair(origin, dest string) bool {
	return ferryPortCode(origin) != "" && ferryPortCode(dest) != ""
}

// railRegion is a coarse box where rail (or a short drive) beats flying for a
// hop, with the distance under which we say so. Data, not branches: covering
// another network later is a row here plus a fixture, never a new code path.
// Boxes are deliberately coarse — a false positive costs a Rome2Rio link
// instead of a flight search on a leg one tap fixes, while every miss keeps
// today's behaviour exactly.
type railRegion struct {
	name           string
	minLat, maxLat float64
	minLng, maxLng float64
	maxKm          float64
}

// railRegions: continental Europe + Great Britain, and Japan. 550 km is the
// threshold both were tuned to — it takes Rome → Milan (477), Madrid →
// Barcelona (505) and Munich → Berlin (504), and leaves Amsterdam → Berlin
// (577) a flight. Both endpoints must sit in the SAME region.
var railRegions = []railRegion{
	{name: "europe", minLat: 35, maxLat: 61, minLng: -10, maxLng: 32, maxKm: 550},
	{name: "japan", minLat: 30, maxLat: 46, minLng: 128, maxLng: 146, maxKm: 550},
}

// islandGroups maps a place label to the landmass it sits on, for places NOT
// reachable from the mainland by road or rail. Two endpoints in the SAME group
// can still be a train or a drive (Palermo → Catania, Dublin → Belfast); one
// endpoint inside a group and the other outside it is a sea crossing, and
// geography then has no opinion at all.
//
// Two deliberate absences. Great Britain is not a group — the Channel Tunnel
// makes London → Paris a train. And a sea crossing is never answered with
// "ferry": outside the Greek ports of isGreekFerryPair we cannot build a real
// ferry route link, so Naples → Capri keeps the flight default rather than
// handing the traveler a booking site's front page.
var islandGroups = map[string]string{
	// Italy
	"sicily": "sicily", "sicilia": "sicily", "palermo": "sicily",
	"catania": "sicily", "taormina": "sicily", "syracuse": "sicily",
	"siracusa": "sicily", "agrigento": "sicily", "cefalu": "sicily",
	"cefalù": "sicily", "trapani": "sicily", "ragusa": "sicily",
	"noto": "sicily", "messina": "sicily",
	"sardinia": "sardinia", "sardegna": "sardinia", "cagliari": "sardinia",
	"olbia": "sardinia", "alghero": "sardinia", "sassari": "sardinia",
	"capri": "capri", "anacapri": "capri",
	"ischia": "ischia", "procida": "procida",
	"elba": "elba", "portoferraio": "elba",
	// France
	"corsica": "corsica", "corse": "corsica", "ajaccio": "corsica",
	"bastia": "corsica", "calvi": "corsica", "bonifacio": "corsica",
	// Spain
	"mallorca": "balearics", "majorca": "balearics", "palma": "balearics",
	"palma de mallorca": "balearics", "ibiza": "balearics",
	"eivissa": "balearics", "menorca": "balearics", "minorca": "balearics",
	"mahon": "balearics", "formentera": "balearics",
	// Malta
	"malta": "malta", "valletta": "malta", "gozo": "malta", "sliema": "malta",
	// Ireland (one island: Dublin → Belfast is a train)
	"ireland": "ireland", "dublin": "ireland", "cork": "ireland",
	"galway": "ireland", "limerick": "ireland", "killarney": "ireland",
	"kilkenny": "ireland", "belfast": "ireland", "derry": "ireland",
	"northern ireland": "ireland",
	// Nordics / Baltic
	"gotland": "gotland", "visby": "gotland",
	"bornholm": "bornholm", "ronne": "bornholm",
	"aland": "aland", "åland": "aland", "mariehamn": "aland",
	// Greek islands, one group each: a Greek pair is answered by
	// isGreekFerryPair long before geography, so these only matter for the
	// mixed legs it does not catch (Corfu → Bari is a crossing, not a train).
	"santorini": "santorini", "thira": "santorini", "fira": "santorini",
	"oia":     "santorini",
	"mykonos": "mykonos", "naxos": "naxos", "paros": "paros", "ios": "ios",
	"milos": "milos", "syros": "syros", "tinos": "tinos",
	"folegandros": "folegandros",
	"crete":       "crete", "heraklion": "crete", "chania": "crete",
	"rethymno": "crete",
	"rhodes":   "rhodes", "kos": "kos", "corfu": "corfu",
	"kefalonia": "kefalonia", "zakynthos": "zakynthos", "lefkada": "lefkada",
	"skiathos": "skiathos", "skopelos": "skopelos", "samos": "samos",
	"chios": "chios", "lesbos": "lesbos", "mytilene": "lesbos",
	"karpathos": "karpathos", "symi": "symi", "hydra": "hydra",
	"spetses": "spetses", "aegina": "aegina",
}

// islandGroup resolves a label to its landmass group, "" for the mainland.
// Matches the whole label and the part before a comma, like ferryPortCode and
// isGreekLocation — "Palma, Spain" is Palma.
func islandGroup(label string) string {
	n := strings.ToLower(strings.TrimSpace(label))
	if n == "" {
		return ""
	}
	if g, ok := islandGroups[n]; ok {
		return g
	}
	if i := strings.IndexByte(n, ','); i > 0 {
		if g, ok := islandGroups[strings.TrimSpace(n[:i])]; ok {
			return g
		}
	}
	return ""
}

// geoLegMode is what geography alone implies for a leg: "train" for a short
// hop inside one rail region, "" when it has no opinion. "" is the important
// half of the contract — it is what leaves the leg on the flight default, so
// every gap in the region table or the island map costs nothing versus the
// behaviour before this file.
func geoLegMode(origin, dest legEndpoint) string {
	if origin.Lat == nil || origin.Lng == nil || dest.Lat == nil || dest.Lng == nil {
		return ""
	}
	// A sea crossing: exactly one endpoint on an island, or two different
	// islands. Same island is fine — Palermo → Catania is a train.
	if islandGroup(origin.Label) != islandGroup(dest.Label) {
		return ""
	}
	region, ok := sharedRailRegion(*origin.Lat, *origin.Lng, *dest.Lat, *dest.Lng)
	if !ok {
		return ""
	}
	if haversineMeters(*origin.Lat, *origin.Lng, *dest.Lat, *dest.Lng)/1000 > region.maxKm {
		return ""
	}
	return "train"
}

// sharedRailRegion returns the first region containing BOTH points.
func sharedRailRegion(lat1, lng1, lat2, lng2 float64) (railRegion, bool) {
	for _, r := range railRegions {
		if r.contains(lat1, lng1) && r.contains(lat2, lng2) {
			return r, true
		}
	}
	return railRegion{}, false
}

func (r railRegion) contains(lat, lng float64) bool {
	return lat >= r.minLat && lat <= r.maxLat && lng >= r.minLng && lng <= r.maxLng
}
