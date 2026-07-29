package main

import (
	"context"
	"net/http"
	"strings"
	"testing"
)

// Venue-photo enrichment of the local_recs SSE event (chat photo cards):
// recs with a place_id get photo_ref/photo_attribution resolved via a
// fields=photo details lookup; recs without stay bare; the public browse
// endpoint never carries photo fields. DB-gated (TEST_DATABASE_URL).

func seedAthensRecs(t *testing.T) {
	t.Helper()
	mustExec := func(sql string, args ...any) {
		t.Helper()
		if _, err := dbPool.Exec(context.Background(), sql, args...); err != nil {
			t.Fatalf("seed: %v (%s)", err, sql)
		}
	}
	mustExec(`INSERT INTO local_sources (name) VALUES ('Eleni the Guide')`)
	mustExec(`INSERT INTO local_recommendations (source_id, city, name, status, place_id, latitude, longitude)
	          SELECT id, 'Athens', 'Ta Karamanlidika', 'published', 'p-venue-1', 37.98, 23.72 FROM local_sources LIMIT 1`)
	mustExec(`INSERT INTO local_recommendations (source_id, city, name, status, latitude, longitude)
	          SELECT id, 'Athens', 'No-PlaceID Spot', 'published', 37.97, 23.73 FROM local_sources LIMIT 1`)
}

func TestPlanLocalRecsEnrichedWithVenuePhotos(t *testing.T) {
	resetDB(t)
	seedAthensRecs(t)

	rt := &countingTransport{body: fakePhotoDetailsJSON}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: rt}
	swapPlacesService(t, svc)

	newFakeAnthropic(t,
		toolTurn("search_local_recommendations", `{"city":"Athens"}`),
		textTurn("Locals love these."),
	)
	rec := runPlanHandlerFromIP(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "local food tips for Athens?"},
	}})
	events := planEvents(t, rec.Body.String())
	if errs := eventsOfType(events, "error"); len(errs) != 0 {
		t.Fatalf("unexpected error events: %v", errs)
	}

	recsEvents := eventsOfType(events, "local_recs")
	if len(recsEvents) != 1 {
		t.Fatalf("local_recs events = %d, want 1", len(recsEvents))
	}
	recs, _ := eventData(recsEvents[0])["recommendations"].([]any)
	if len(recs) != 2 {
		t.Fatalf("recs = %d, want 2", len(recs))
	}
	byName := map[string]map[string]any{}
	for _, r := range recs {
		m := r.(map[string]any)
		byName[m["name"].(string)] = m
	}
	withID := byName["Ta Karamanlidika"]
	if withID["photo_ref"] != "PHOTOREF-venue" || withID["photo_attribution"] != "Local Snapper" {
		t.Fatalf("place_id rec not enriched: %v", withID)
	}
	bare := byName["No-PlaceID Spot"]
	if _, present := bare["photo_ref"]; present {
		t.Fatalf("rec without place_id grew a photo_ref: %v", bare)
	}
	if rt.calls != 1 {
		t.Fatalf("photo lookups = %d, want 1 (only the place_id rec)", rt.calls)
	}
	// The resolved ref must be servable by /places/photo.
	if !placesService.photoRefAllowed("PHOTOREF-venue") {
		t.Fatal("enriched ref not registered with the photo gate")
	}

	// Second turn: the 24h photoRefCache absorbs the lookup — zero new calls.
	newFakeAnthropic(t,
		toolTurn("search_local_recommendations", `{"city":"Athens"}`),
		textTurn("Same picks."),
	)
	runPlanHandlerFromIP(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: "again please"},
	}})
	if rt.calls != 1 {
		t.Fatalf("photo lookups after second turn = %d, want 1 (cached)", rt.calls)
	}
}

// The public browse endpoint never enriches: its JSON must stay byte-free of
// photo fields (omitempty contract).
func TestPublicLocalBrowseUnchangedByPhotoFields(t *testing.T) {
	resetDB(t)
	seedAthensRecs(t)

	rec := doJSON(t, "GET", "/api/v1/local/recommendations?city=Athens", "", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if body := rec.Body.String(); strings.Contains(body, "photo_ref") || strings.Contains(body, "photo_attribution") {
		t.Fatalf("public browse response leaks photo fields: %s", body)
	}
}
