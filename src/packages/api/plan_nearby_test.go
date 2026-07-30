package main

import (
	"net/http"
	"strings"
	"testing"
)

// search_nearby ("what's near me"): a location-biased search_places sibling.
// It must reuse the same `places` SSE side event (so the client photo strip
// works unchanged), keep photo refs out of the model's tool_result, and reject
// junk coordinates before spending a Google call.

func TestPlanSearchNearbyEmitsPlacesCardsWithLocationBias(t *testing.T) {
	fa := newFakeAnthropic(t,
		toolTurn("search_nearby", `{"query":"coffee","latitude":37.98381,"longitude":23.72757}`),
		textTurn("Closest good coffee is two blocks away."),
	)

	rt := &urlRecordingTransport{body: fakeSearchBodyWithPhotos(10)}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: rt}
	swapPlacesService(t, svc)

	rec := runPlanHandlerFromIP(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "My current location is latitude 37.98381, longitude 23.72757. What's good near me?"},
	}})
	events := planEvents(t, rec.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	// The upstream call carries the rounded location bias.
	if len(rt.urls) != 1 {
		t.Fatalf("Google called %d times, want 1", len(rt.urls))
	}
	if !strings.Contains(rt.urls[0], "location=37.9838%2C23.7276") || !strings.Contains(rt.urls[0], "radius=3000") {
		t.Fatalf("upstream URL missing location bias: %s", rt.urls[0])
	}

	// Same client contract as search_places: one capped `places` event with
	// gate-registered photo refs.
	placesEvents := eventsOfType(events, "places")
	if len(placesEvents) != 1 {
		t.Fatalf("places events = %d, want 1", len(placesEvents))
	}
	data := eventData(placesEvents[0])
	if got := data["query"]; got != "coffee" {
		t.Fatalf("query = %v", got)
	}
	cards, ok := data["places"].([]any)
	if !ok || len(cards) != planPlacesCardCap {
		t.Fatalf("cards = %T len %d, want %d (capped)", data["places"], len(cards), planPlacesCardCap)
	}
	if !placesService.photoRefAllowed("REF-0") {
		t.Fatal("emitted card ref not registered with the photo gate")
	}

	// tool_result stays photo-free for the model.
	bodies := fa.requestBodies()
	if len(bodies) != 2 {
		t.Fatalf("anthropic calls = %d, want 2", len(bodies))
	}
	if strings.Contains(string(bodies[1]), "photo_ref") {
		t.Fatalf("tool_result leaks photo refs to the model")
	}
}

func TestPlanSearchNearbyRejectsInvalidCoordinates(t *testing.T) {
	fa := newFakeAnthropic(t,
		toolTurn("search_nearby", `{"query":"coffee","latitude":0,"longitude":0}`),
		textTurn("Where are you right now?"),
	)

	rt := &countingTransport{body: fakeSearchBodyWithPhotos(1)}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: rt}
	swapPlacesService(t, svc)

	rec := runPlanHandlerFromIP(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "what's near me?"},
	}})
	events := planEvents(t, rec.Body.String())

	// No Google spend, no places event; the model gets an error tool_result
	// telling it to ask for a location.
	if rt.calls != 0 {
		t.Fatalf("Google called %d times for (0,0), want 0", rt.calls)
	}
	if got := eventsOfType(events, "places"); len(got) != 0 {
		t.Fatalf("places events = %d, want 0", len(got))
	}
	bodies := fa.requestBodies()
	if len(bodies) != 2 {
		t.Fatalf("anthropic calls = %d, want 2", len(bodies))
	}
	if !strings.Contains(string(bodies[1]), "Invalid coordinates") {
		t.Fatalf("tool_result missing invalid-coordinates error")
	}
}
