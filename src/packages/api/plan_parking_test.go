package main

import (
	"fmt"
	"net/http"
	"strings"
	"testing"
)

// find_parking (specs/find-parking-near-beach): two biased type=parking Text
// Searches per call, a name-heuristic free flag that must reach the client's
// `parking` cards but be framed as unverified for the model, and a geocode
// fallback so the model never invents coordinates.

// fakeParkingBody builds a Text Search response with n parking results (even
// index → free-named, odd → paid-looking) plus the beach itself as noise the
// post-filter must drop.
func fakeParkingBody(n int) string {
	results := []string{
		`{"place_id":"beach","name":"Barceloneta Beach","formatted_address":"Barcelona","geometry":{"location":{"lat":41.3784,"lng":2.1925}},"types":["natural_feature"]}`,
	}
	for i := 0; i < n; i++ {
		name := fmt.Sprintf("Central Parking %d", i)
		if i%2 == 0 {
			name = fmt.Sprintf("Free Beach Parking %d", i)
		}
		results = append(results, fmt.Sprintf(
			`{"place_id":"pk%d","name":"%s","formatted_address":"Barcelona %d","geometry":{"location":{"lat":41.379,"lng":2.192}},"types":["parking"],"photos":[{"photo_reference":"PARK-REF-%d","html_attributions":["<a href=\"x\">Snapper</a>"]}]}`,
			i, name, i, i))
	}
	return `{"status":"OK","results":[` + strings.Join(results, ",") + `]}`
}

func TestPlanFindParkingEmitsParkingCards(t *testing.T) {
	fa := newFakeAnthropic(t,
		toolTurn("find_parking", `{"beach_name":"Barceloneta Beach","latitude":41.3784,"longitude":2.1925}`),
		textTurn("Here's where you can park — the flagged ones are listed as free, verify locally."),
	)

	rt := &urlRecordingTransport{body: fakeParkingBody(10)}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: rt}
	swapPlacesService(t, svc)

	rec := runPlanHandlerFromIP(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "We're driving — where can we park near Barceloneta Beach?"},
	}})
	events := planEvents(t, rec.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	// Coords were provided, so exactly the two biased parking queries hit
	// Google — no geocode call.
	if len(rt.urls) != 2 {
		t.Fatalf("Google called %d times, want 2: %v", len(rt.urls), rt.urls)
	}
	sawFreeQuery := false
	for _, u := range rt.urls {
		if !strings.Contains(u, "location=41.3784%2C2.1925") || !strings.Contains(u, "radius=2000") || !strings.Contains(u, "type=parking") {
			t.Fatalf("upstream URL missing parking bias params: %s", u)
		}
		if strings.Contains(u, "free+parking") {
			sawFreeQuery = true
		}
	}
	if !sawFreeQuery {
		t.Fatalf("no free-parking query issued: %v", rt.urls)
	}

	// One `parking` event: capped cards, beach label, free flags, photo refs
	// registered with the /places/photo gate.
	parkingEvents := eventsOfType(events, "parking")
	if len(parkingEvents) != 1 {
		t.Fatalf("parking events = %d, want 1", len(parkingEvents))
	}
	data := eventData(parkingEvents[0])
	if got := data["beach"]; got != "Barceloneta Beach" {
		t.Fatalf("beach = %v", got)
	}
	cards, ok := data["spots"].([]any)
	if !ok || len(cards) != planPlacesCardCap {
		t.Fatalf("spots = %T len %d, want %d (capped)", data["spots"], len(cards), planPlacesCardCap)
	}
	first := cards[0].(map[string]any)
	if first["free_listed"] != true {
		t.Fatalf("first card not free-flagged (free-first ranking): %v", first)
	}
	if first["category"] != "parking" {
		t.Fatalf("card category = %v, want parking", first["category"])
	}
	for _, c := range cards {
		if name, _ := c.(map[string]any)["name"].(string); strings.Contains(name, "Beach") && !strings.Contains(name, "Parking") {
			t.Fatalf("beach noise survived the post-filter: %v", c)
		}
	}
	if !placesService.photoRefAllowed("PARK-REF-0") {
		t.Fatal("emitted card ref not registered with the photo gate")
	}

	// The model's tool_result: photo-free, disclaimer-prefixed.
	bodies := fa.requestBodies()
	if len(bodies) != 2 {
		t.Fatalf("anthropic calls = %d, want 2", len(bodies))
	}
	toolResult := string(bodies[1])
	if strings.Contains(toolResult, "photo_ref") || strings.Contains(toolResult, "PARK-REF") {
		t.Fatalf("tool_result leaks photo refs to the model")
	}
	if !strings.Contains(toolResult, "listed as free, verify locally") {
		t.Fatalf("tool_result missing the heuristic disclaimer")
	}
	if !strings.Contains(toolResult, "free_listed") || !strings.Contains(toolResult, "distance_meters") {
		t.Fatalf("tool_result missing ranked-result fields")
	}
}

func TestPlanFindParkingGeocodesWhenCoordsMissing(t *testing.T) {
	newFakeAnthropic(t,
		toolTurn("find_parking", `{"beach_name":"Barceloneta Beach"}`),
		textTurn("Here's where you can park."),
	)

	rt := &urlRecordingTransport{body: fakeParkingBody(4)}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: rt}
	swapPlacesService(t, svc)

	rec := runPlanHandlerFromIP(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "where can we park near Barceloneta beach? we have a car"},
	}})
	events := planEvents(t, rec.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	// Geocode first (plain Text Search, no type=parking), then the two biased
	// parking queries.
	if len(rt.urls) != 3 {
		t.Fatalf("Google called %d times, want 3 (geocode + 2 parking): %v", len(rt.urls), rt.urls)
	}
	if strings.Contains(rt.urls[0], "type=parking") {
		t.Fatalf("geocode call unexpectedly typed: %s", rt.urls[0])
	}
	for _, u := range rt.urls[1:] {
		if !strings.Contains(u, "type=parking") {
			t.Fatalf("parking call missing type=parking: %s", u)
		}
	}
	if len(eventsOfType(events, "parking")) != 1 {
		t.Fatal("expected one parking event after geocode fallback")
	}
}

func TestPlanFindParkingMissingBeachName(t *testing.T) {
	fa := newFakeAnthropic(t,
		toolTurn("find_parking", `{"beach_name":"  "}`),
		textTurn("Which beach did you mean?"),
	)

	rt := &countingTransport{body: fakeParkingBody(2)}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: rt}
	swapPlacesService(t, svc)

	rec := runPlanHandlerFromIP(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "find parking"},
	}})
	events := planEvents(t, rec.Body.String())

	// No Google spend, no parking event; the model gets an error tool_result.
	if rt.calls != 0 {
		t.Fatalf("Google called %d times for blank beach_name, want 0", rt.calls)
	}
	if got := eventsOfType(events, "parking"); len(got) != 0 {
		t.Fatalf("parking events = %d, want 0", len(got))
	}
	bodies := fa.requestBodies()
	if len(bodies) != 2 {
		t.Fatalf("anthropic calls = %d, want 2", len(bodies))
	}
	if !strings.Contains(string(bodies[1]), "Missing beach_name") {
		t.Fatalf("tool_result missing beach_name error")
	}
}
