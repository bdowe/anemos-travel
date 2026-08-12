package main

import (
	"context"
	"testing"
)

func f64(v float64) *float64 { return &v }

func strp(s string) *string { return &s }

// TestOptimizeRoutePreserveOrder verifies that with PreserveOrder set, the route
// keeps the caller-supplied order (no NN/2-opt reshuffle) while still populating
// per-leg travel timings. Locations carry coordinates so no Places API is hit.
func TestOptimizeRoutePreserveOrder(t *testing.T) {
	ro := NewRouteOptimizer(nil)

	// Three points laid out so that the nearest-neighbor optimum would NOT match
	// input order: A and C are close together, B is far away in the middle.
	req := RouteRequest{
		PreserveOrder: true,
		Locations: []Location{
			{ID: "a", Name: "A", Latitude: f64(40.7128), Longitude: f64(-74.0060)},  // NYC
			{ID: "b", Name: "B", Latitude: f64(34.0522), Longitude: f64(-118.2437)}, // LA (far)
			{ID: "c", Name: "C", Latitude: f64(40.7138), Longitude: f64(-74.0050)},  // ~NYC
		},
	}

	resp := ro.OptimizeRoute(context.Background(), req)

	if resp.Status != "success" {
		t.Fatalf("expected success, got %q", resp.Status)
	}
	if resp.Algorithm != "preserve-order" {
		t.Errorf("expected algorithm %q, got %q", "preserve-order", resp.Algorithm)
	}

	gotOrder := []string{}
	for _, loc := range resp.OptimizedRoute {
		gotOrder = append(gotOrder, loc.ID)
	}
	wantOrder := []string{"a", "b", "c"}
	for i := range wantOrder {
		if gotOrder[i] != wantOrder[i] {
			t.Fatalf("order not preserved: want %v, got %v", wantOrder, gotOrder)
		}
	}

	if len(resp.LocationTimings) != 3 {
		t.Fatalf("expected 3 timings, got %d", len(resp.LocationTimings))
	}
	// Legs leaving A and B must have positive distance/time; the last item has none.
	for i := 0; i < 2; i++ {
		if resp.LocationTimings[i].TravelToNextMin <= 0 {
			t.Errorf("timing[%d].TravelToNextMin = %d, want > 0", i, resp.LocationTimings[i].TravelToNextMin)
		}
		if resp.LocationTimings[i].TravelToNextKm <= 0 {
			t.Errorf("timing[%d].TravelToNextKm = %f, want > 0", i, resp.LocationTimings[i].TravelToNextKm)
		}
	}
	if resp.LocationTimings[2].TravelToNextMin != 0 {
		t.Errorf("last leg TravelToNextMin = %d, want 0", resp.LocationTimings[2].TravelToNextMin)
	}
}
