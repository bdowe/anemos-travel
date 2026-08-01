package main

import "testing"

// The free/cheap flag is a name heuristic the traveler will see — these pin
// its behavior so keyword edits are deliberate.

func TestLooksFreeParking(t *testing.T) {
	cases := []struct {
		name string
		want bool
	}{
		{"Free Beach Parking", true},
		{"Playa Parking Gratis", true},
		{"Parcheggio Gratuito Lido", true},
		{"No Fee Public Lot", true},
		{"Street Parking Zone B", true},
		{"Central Parking Garage", false},
		{"Ocean View Lot", false},
		// Paid signal always wins, even next to a free word.
		{"Free Valet Parking", false},
		{"Premium Beach Parking - free entry", false},
		// Whole-token match only: no false positives from lookalike words.
		{"Freeport Marina Parking", false},
		{"Freeway Exit 12 Lot", false},
	}
	for _, c := range cases {
		if got := looksFreeParking(c.name); got != c.want {
			t.Errorf("looksFreeParking(%q) = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestIsParkingResult(t *testing.T) {
	cases := []struct {
		desc string
		r    PlaceSearchResult
		want bool
	}{
		{"google parking type", PlaceSearchResult{Name: "Interparking Centre", Types: []string{"parking", "point_of_interest"}}, true},
		{"name signal without type", PlaceSearchResult{Name: "Beachside Car Park", Types: []string{"point_of_interest"}}, true},
		{"spanish name signal", PlaceSearchResult{Name: "Aparcamiento Playa", Types: []string{"establishment"}}, true},
		// The free-text query loves returning the beach itself and hotels
		// advertising "free parking" as an amenity name-suffix-free.
		{"the beach itself", PlaceSearchResult{Name: "Barceloneta Beach", Types: []string{"natural_feature"}}, false},
		{"hotel noise", PlaceSearchResult{Name: "Hotel Miramar", Types: []string{"lodging"}}, false},
		{"bare garage excluded", PlaceSearchResult{Name: "The Garage Bar", Types: []string{"bar"}}, false},
	}
	for _, c := range cases {
		if got := isParkingResult(c.r); got != c.want {
			t.Errorf("%s: isParkingResult = %v, want %v", c.desc, got, c.want)
		}
	}
}

func TestRankParkingResults(t *testing.T) {
	beachLat, beachLng := 41.3784, 2.1925
	parking := func(id, name string, lat, lng float64) PlaceSearchResult {
		return PlaceSearchResult{PlaceID: id, Name: name, Types: []string{"parking"}, Latitude: lat, Longitude: lng}
	}

	freeQ := []PlaceSearchResult{
		parking("far-free", "Free Lot Far", 41.3950, 2.1925),  // free, ~1.8 km
		parking("dup", "Free Beach Parking", 41.3790, 2.1925), // also in generalQ
		{PlaceID: "beach", Name: "Barceloneta Beach", Types: []string{"natural_feature"}, Latitude: beachLat, Longitude: beachLng},
	}
	generalQ := []PlaceSearchResult{
		parking("dup", "Free Beach Parking", 41.3790, 2.1925), // dedupe: free-query entry wins
		parking("near-paid", "Central Parking", 41.3786, 2.1925),
		parking("near-free", "Gratis Parking Port", 41.3789, 2.1925),
	}

	got := rankParkingResults(freeQ, generalQ, beachLat, beachLng)

	var ids []string
	for _, r := range got {
		ids = append(ids, r.PlaceID)
	}
	// Free-flagged first (closest first within the group), then paid-looking;
	// the beach filtered out; "dup" present exactly once.
	want := []string{"near-free", "dup", "far-free", "near-paid"}
	if len(ids) != len(want) {
		t.Fatalf("ranked ids = %v, want %v", ids, want)
	}
	for i := range want {
		if ids[i] != want[i] {
			t.Fatalf("ranked ids = %v, want %v", ids, want)
		}
	}
	if !got[0].FreeListed || got[len(got)-1].FreeListed {
		t.Fatalf("free flags misassigned: %+v", got)
	}
	if got[0].DistanceMeters <= 0 || got[2].DistanceMeters < 1500 {
		t.Fatalf("distances implausible: near=%d far=%d", got[0].DistanceMeters, got[2].DistanceMeters)
	}
}

func TestRankParkingResultsCapsAtModelResultCap(t *testing.T) {
	var freeQ []PlaceSearchResult
	for i := 0; i < parkingModelResultCap+5; i++ {
		freeQ = append(freeQ, PlaceSearchResult{
			PlaceID: string(rune('a' + i)), Name: "Free Parking", Types: []string{"parking"},
			Latitude: 41.38, Longitude: 2.19,
		})
	}
	if got := rankParkingResults(freeQ, nil, 41.3784, 2.1925); len(got) != parkingModelResultCap {
		t.Fatalf("len = %d, want cap %d", len(got), parkingModelResultCap)
	}
}
