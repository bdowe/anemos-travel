package main

// Free/cheap parking near beaches for the /plan agent's find_parking tool
// (specs/find-parking-near-beach). Unlike the provider files
// (ferry_service.go, events_service.go) there is deliberately no singleton
// here: parking has no external provider, key, or config of its own — it
// orchestrates placesService Text Search and layers a free/cheap name
// heuristic on top. The heuristics are pure functions so they test without
// Google.

import (
	"context"
	"log"
	"math"
	"sort"
	"strings"
	"unicode"
)

// parkingModelResultCap bounds the tool_result list handed to the model; the
// SSE card payload is separately capped at planPlacesCardCap.
const parkingModelResultCap = 12

// The free/cheap signal is a heuristic read of the place listing's NAME, not
// verified pricing — every surface that shows it says "listed as free, verify
// locally". Phrases match by substring; single words match whole tokens only
// (so "freeway"/"Freeport" never flag). A paid signal always wins.
var (
	freeParkingPhrases = []string{"free parking", "parking free", "no fee", "street parking"}
	freeParkingWords   = []string{"free", "gratis", "gratuito", "gratuita", "gratuit"}
	paidParkingSignals = []string{"valet", "paid", "premium", "de pago", "fee required"}
)

// parkingNameSignals marks a result as parking-shaped when Google's types
// don't (the free-text queries can return the beach itself, or hotels
// advertising "free parking"). Bare "garage" is excluded on purpose — too many
// bars/venues use it.
var parkingNameSignals = []string{
	"parking", "car park", "parcheggio", "aparcamiento", "estacionamiento",
	"parkplatz", "parkhaus",
}

// parkingResult is one ranked spot. Embedding PlaceSearchResult keeps its
// photo fields json:"-", so marshalling results for the model's tool_result
// stays photo-free for free.
type parkingResult struct {
	PlaceSearchResult
	FreeListed     bool `json:"free_listed"`
	DistanceMeters int  `json:"distance_meters"`
}

// looksFreeParking reports whether the listing name suggests free parking.
func looksFreeParking(name string) bool {
	n := strings.ToLower(name)
	for _, sig := range paidParkingSignals {
		if strings.Contains(n, sig) {
			return false
		}
	}
	for _, phrase := range freeParkingPhrases {
		if strings.Contains(n, phrase) {
			return true
		}
	}
	tokens := strings.FieldsFunc(n, func(r rune) bool {
		return !unicode.IsLetter(r) && !unicode.IsNumber(r)
	})
	for _, tok := range tokens {
		for _, word := range freeParkingWords {
			if tok == word {
				return true
			}
		}
	}
	return false
}

// isParkingResult filters the Text Search results down to parking-shaped
// places.
func isParkingResult(r PlaceSearchResult) bool {
	for _, t := range r.Types {
		if t == "parking" {
			return true
		}
	}
	n := strings.ToLower(r.Name)
	for _, sig := range parkingNameSignals {
		if strings.Contains(n, sig) {
			return true
		}
	}
	return false
}

// haversineMeters is the standalone counterpart of RouteOptimizer's km-based
// haversineDistance (route_optimizer.go) for callers with no optimizer in
// hand.
func haversineMeters(lat1, lng1, lat2, lng2 float64) float64 {
	const earthRadiusMeters = 6371000.0
	lat1Rad := lat1 * math.Pi / 180
	lat2Rad := lat2 * math.Pi / 180
	dLat := (lat2 - lat1) * math.Pi / 180
	dLng := (lng2 - lng1) * math.Pi / 180
	a := math.Sin(dLat/2)*math.Sin(dLat/2) +
		math.Cos(lat1Rad)*math.Cos(lat2Rad)*math.Sin(dLng/2)*math.Sin(dLng/2)
	return earthRadiusMeters * 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
}

// rankParkingResults merges the free-focused and general query results
// (free-query first so its entries win the dedupe), drops non-parking noise,
// and sorts free-flagged spots ahead of paid-looking ones, closest first
// within each group. The Places radius is only a bias, so DistanceMeters is
// computed here rather than trusted from the query.
func rankParkingResults(freeQuery, generalQuery []PlaceSearchResult, beachLat, beachLng float64) []parkingResult {
	seen := make(map[string]bool)
	var out []parkingResult
	for _, r := range append(append([]PlaceSearchResult{}, freeQuery...), generalQuery...) {
		if r.PlaceID == "" || seen[r.PlaceID] {
			continue
		}
		seen[r.PlaceID] = true
		if !isParkingResult(r) {
			continue
		}
		out = append(out, parkingResult{
			PlaceSearchResult: r,
			FreeListed:        looksFreeParking(r.Name),
			DistanceMeters:    int(math.Round(haversineMeters(beachLat, beachLng, r.Latitude, r.Longitude))),
		})
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].FreeListed != out[j].FreeListed {
			return out[i].FreeListed
		}
		return out[i].DistanceMeters < out[j].DistanceMeters
	})
	if len(out) > parkingModelResultCap {
		out = out[:parkingModelResultCap]
	}
	return out
}

// findParkingNearBeach runs the two biased Text Search queries and ranks the
// merged results. ZERO_RESULTS counts as an empty list, not a failure (the
// free-focused query is often empty); a genuine failure of one query is
// tolerated as long as the other answered.
func findParkingNearBeach(ctx context.Context, beachName string, lat, lng float64) ([]parkingResult, error) {
	freeResults, freeErr := placesService.SearchParkingNearby(ctx, "free parking near "+beachName, lat, lng)
	generalResults, generalErr := placesService.SearchParkingNearby(ctx, "parking near "+beachName, lat, lng)
	if isPlacesZeroResults(freeErr) {
		freeErr = nil
	}
	if isPlacesZeroResults(generalErr) {
		generalErr = nil
	}
	if freeErr != nil && generalErr != nil {
		return nil, generalErr
	}
	if freeErr != nil {
		log.Printf("find_parking: free-parking query failed, continuing with general results: %v", freeErr)
	}
	if generalErr != nil {
		log.Printf("find_parking: general parking query failed, continuing with free results: %v", generalErr)
	}
	return rankParkingResults(freeResults, generalResults, lat, lng), nil
}
