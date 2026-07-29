package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// runPlanHandlerFromIP posts like runPlanHandler but from a unique client IP,
// so these anonymous /plan tests never share the per-IP daily plan cap
// (abuse_caps.go, in-memory) with the rest of the suite.
func runPlanHandlerFromIP(t *testing.T, req PlanRequest) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	rec := httptest.NewRecorder()
	httpReq := httptest.NewRequest("POST", "/api/v1/plan", bytes.NewReader(body))
	httpReq.Header.Set("X-Forwarded-For", nextTestIP())
	planHandler(rec, httpReq)
	return rec
}

// Photo cards for chat recommendations: search_places must emit a `places`
// SSE side event (capped, gate-registered) while the model-facing tool_result
// stays free of photo refs.

// fakeSearchBodyWithPhotos builds a Text Search response with n results, each
// carrying photo_reference "REF-<i>".
func fakeSearchBodyWithPhotos(n int) string {
	var results []string
	for i := 0; i < n; i++ {
		results = append(results, fmt.Sprintf(
			`{"place_id":"p%d","name":"Taverna %d","formatted_address":"Athens %d","geometry":{"location":{"lat":37.9,"lng":23.7}},"types":["restaurant"],"rating":4.5,"price_level":2,"photos":[{"photo_reference":"REF-%d","html_attributions":["<a href=\"x\">Snapper %d</a>"]}]}`,
			i, i, i, i, i))
	}
	return `{"status":"OK","results":[` + strings.Join(results, ",") + `]}`
}

func TestPlanSearchPlacesEmitsCappedPlacesCards(t *testing.T) {
	fa := newFakeAnthropic(t,
		toolTurn("search_places", `{"query":"dinner in athens"}`),
		textTurn("Here are some tavernas."),
	)

	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: &countingTransport{body: fakeSearchBodyWithPhotos(10)}}
	swapPlacesService(t, svc)

	rec := runPlanHandlerFromIP(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "where should I eat in Athens?"},
	}})
	events := planEvents(t, rec.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	placesEvents := eventsOfType(events, "places")
	if len(placesEvents) != 1 {
		t.Fatalf("places events = %d, want 1", len(placesEvents))
	}
	data := eventData(placesEvents[0])
	if got := data["query"]; got != "dinner in athens" {
		t.Fatalf("query = %v", got)
	}
	cards, ok := data["places"].([]any)
	if !ok || len(cards) != planPlacesCardCap {
		t.Fatalf("cards = %T len %d, want %d (capped)", data["places"], len(cards), planPlacesCardCap)
	}
	first, _ := cards[0].(map[string]any)
	for _, key := range []string{"name", "place_id", "address", "lat", "lng", "rating", "price_level", "category", "photo_ref", "photo_attribution"} {
		if _, present := first[key]; !present {
			t.Fatalf("card missing %q: %v", key, first)
		}
	}
	if first["category"] != "restaurant" {
		t.Fatalf("category = %v, want restaurant", first["category"])
	}
	if first["photo_ref"] != "REF-0" || first["photo_attribution"] != "Snapper 0" {
		t.Fatalf("photo fields = %v / %v", first["photo_ref"], first["photo_attribution"])
	}

	// Emitted refs are servable; the ninth result fell outside the cap, so its
	// ref was never handed to a client and must stay gated.
	if !placesService.photoRefAllowed("REF-0") || !placesService.photoRefAllowed("REF-7") {
		t.Fatal("emitted card refs not registered with the photo gate")
	}
	if placesService.photoRefAllowed("REF-8") {
		t.Fatal("ref beyond the card cap must not be gate-registered")
	}

	// The model's tool_result (second Anthropic request carries it) must not
	// contain photo refs — they are client-only payload.
	bodies := fa.requestBodies()
	if len(bodies) != 2 {
		t.Fatalf("anthropic calls = %d, want 2", len(bodies))
	}
	if strings.Contains(string(bodies[1]), "REF-0") || strings.Contains(string(bodies[1]), "photo_ref") {
		t.Fatalf("tool_result leaks photo refs to the model")
	}
	// The full (uncapped) result list still reaches the model.
	if !strings.Contains(string(bodies[1]), "Taverna 9") {
		t.Fatalf("tool_result missing uncapped results")
	}
}

func TestPlanSearchPlacesEmptyResultsNoPlacesEvent(t *testing.T) {
	newFakeAnthropic(t,
		toolTurn("search_places", `{"query":"nothing here"}`),
		textTurn("I found nothing."),
	)

	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: &countingTransport{body: `{"status":"OK","results":[]}`}}
	swapPlacesService(t, svc)

	rec := runPlanHandlerFromIP(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "food on the moon?"},
	}})
	events := planEvents(t, rec.Body.String())
	if got := eventsOfType(events, "places"); len(got) != 0 {
		t.Fatalf("places events for empty results = %d, want 0", len(got))
	}
}
