package main

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// Integration tests for POST /api/v1/trips/import: fake Anthropic behind the
// ANTHROPIC_BASE_URL seam (forced-tool non-streaming turn) + fake Google Places
// behind a canned RoundTripper on a swapped placesService singleton.

// cannedPlacesTransport answers every text search with one hit echoing the
// query, except queries the miss predicate rejects (genuine ZERO_RESULTS) and
// queries the fail predicate breaks (transport-level outage — the case that
// must NOT read as "the place doesn't exist").
type cannedPlacesTransport struct {
	miss func(query string) bool
	fail func(query string) bool
}

func (c cannedPlacesTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	q := req.URL.Query().Get("query")
	if c.fail != nil && c.fail(q) {
		return nil, fmt.Errorf("dial tcp: connection refused")
	}
	body := fmt.Sprintf(
		`{"results":[{"place_id":"pl_test","name":%q,"formatted_address":"1 Test St","geometry":{"location":{"lat":38.7223,"lng":-9.1393}}}],"status":"OK"}`, q)
	if c.miss != nil && c.miss(q) {
		body = `{"results":[],"status":"ZERO_RESULTS"}`
	}
	return &http.Response{
		StatusCode: http.StatusOK,
		Header:     http.Header{"Content-Type": []string{"application/json"}},
		Body:       io.NopCloser(strings.NewReader(body)),
	}, nil
}

func swapCannedPlaces(t *testing.T, miss func(string) bool) {
	t.Helper()
	swapCannedPlacesFailing(t, miss, nil)
}

func swapCannedPlacesFailing(t *testing.T, miss, fail func(string) bool) {
	t.Helper()
	svc := NewGooglePlacesService()
	svc.APIKey = "places-test-key"
	svc.Client = &http.Client{Transport: cannedPlacesTransport{miss: miss, fail: fail}}
	swapPlacesService(t, svc)
}

const importHappyPayload = `{
	"title": "Lisbon Weekend",
	"summary": "Two days in Lisbon with a Sintra day trip.",
	"start_date": "2026-09-04",
	"end_date": "2026-09-05",
	"travel_mode": "flight",
	"locations": [
		{"name": "Belém Tower", "city": "Lisbon", "search_hint": "Belém Tower, Lisbon", "day": 1, "time_of_day": "morning", "category": "attraction"},
		{"name": "Time Out Market", "city": "Lisbon", "search_hint": "Time Out Market, Lisbon", "day": 1, "time_of_day": "evening", "category": "restaurant"},
		{"name": "Pena Palace", "city": "Sintra", "day_trip_from": "Lisbon", "search_hint": "Pena Palace, Sintra", "day": 2, "time_of_day": "afternoon", "category": "attraction"}
	]
}`

func TestImportTripHappyPath(t *testing.T) {
	resetDB(t)
	fake := newFakeAnthropic(t)
	fake.scriptNonStreamingTool(importToolName, importHappyPayload)
	swapCannedPlaces(t, nil)
	user, token := createTestUser(t, "importer@example.com")

	rec := doJSON(t, http.MethodPost, "/api/v1/trips/import", token,
		map[string]any{"text": "Day 1 Belém Tower... (pasted ChatGPT plan)", "source": "chatgpt"})
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, body %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	if body["title"] != "Lisbon Weekend" {
		t.Errorf("title = %v", body["title"])
	}
	if int(body["item_count"].(float64)) != 3 {
		t.Errorf("item_count = %v", body["item_count"])
	}
	if warns := body["warnings"].([]any); len(warns) != 0 {
		t.Errorf("warnings = %v, want none", warns)
	}

	tripID := uuid.MustParse(body["trip_id"].(string))
	q := store.New(dbPool)
	trip, err := q.GetTripByIDAndOwner(context.Background(), store.GetTripByIDAndOwnerParams{ID: tripID, UserID: user.ID})
	if err != nil {
		t.Fatalf("trip not persisted: %v", err)
	}
	if trip.ChatID == nil || !strings.HasPrefix(*trip.ChatID, "chat-") {
		t.Errorf("chat_id = %v, want chat-<token>", trip.ChatID)
	}
	if !trip.StartDate.Valid || trip.StartDate.Time.Format("2006-01-02") != "2026-09-04" {
		t.Errorf("start_date = %v", trip.StartDate)
	}
	if trip.TravelMode == nil || *trip.TravelMode != "flight" {
		t.Errorf("travel_mode = %v", trip.TravelMode)
	}

	items, err := q.GetItineraryItemsByTrip(context.Background(), tripID)
	if err != nil || len(items) != 3 {
		t.Fatalf("items = %d (%v), want 3", len(items), err)
	}
	var sintra *store.ItineraryItem
	for i := range items {
		it := items[i]
		if it.Latitude != 38.7223 || it.Longitude != -9.1393 {
			t.Errorf("%s: coords = (%v,%v), want Google-resolved", it.Name, it.Latitude, it.Longitude)
		}
		if it.PlaceID == nil || *it.PlaceID != "pl_test" {
			t.Errorf("%s: place_id = %v", it.Name, it.PlaceID)
		}
		if it.Day == nil || it.TimeOfDay == nil || it.City == nil {
			t.Errorf("%s: day/time_of_day/city not coerced (%v %v %v)", it.Name, it.Day, it.TimeOfDay, it.City)
		}
		if it.Name == "Pena Palace" {
			sintra = &items[i]
		}
	}
	if sintra == nil || sintra.DayTripFrom == nil || *sintra.DayTripFrom != "Lisbon" {
		t.Errorf("day_trip_from not carried through: %+v", sintra)
	}

	// Fresh lineage, no session row: the import must not surface in
	// resumable chats.
	chats := doJSON(t, http.MethodGet, "/api/v1/chats", token, nil)
	if chats.Code != http.StatusOK || strings.Contains(chats.Body.String(), *trip.ChatID) {
		t.Errorf("imported chat_id leaked into resumable chats: %s", chats.Body.String())
	}

	waitForEventCount(t, user.ID, "trip_created", 1)
	waitForEventCount(t, user.ID, "trip_imported", 1)
}

func TestImportTripApproximateAndDropped(t *testing.T) {
	resetDB(t)
	fake := newFakeAnthropic(t)
	fake.scriptNonStreamingTool(importToolName, `{
		"title": "Mixed Bag",
		"locations": [
			{"name": "Findable Cafe", "city": "Lisbon", "search_hint": "Findable Cafe, Lisbon", "day": 1},
			{"name": "Mystery Bar", "city": "Lisbon", "search_hint": "Mystery Bar, Lisbon", "day": 1, "latitude": 38.71, "longitude": -9.14},
			{"name": "Ghost Spot", "city": "Lisbon", "search_hint": "Ghost Spot, Lisbon", "day": 2}
		]
	}`)
	swapCannedPlaces(t, func(q string) bool {
		return strings.Contains(q, "Mystery") || strings.Contains(q, "Ghost")
	})
	_, token := createTestUser(t, "mixed@example.com")

	rec := doJSON(t, http.MethodPost, "/api/v1/trips/import", token, map[string]any{"text": "some plan"})
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, body %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	if int(body["item_count"].(float64)) != 2 {
		t.Errorf("item_count = %v, want 2 (Ghost Spot dropped)", body["item_count"])
	}
	warns := body["warnings"].([]any)
	if len(warns) != 2 {
		t.Fatalf("warnings = %v, want approximate + dropped", warns)
	}
	joined := fmt.Sprint(warns...)
	if !strings.Contains(joined, "Mystery Bar") || !strings.Contains(joined, "Ghost Spot") {
		t.Errorf("warnings must name the affected places: %v", warns)
	}

	tripID := uuid.MustParse(body["trip_id"].(string))
	items, _ := store.New(dbPool).GetItineraryItemsByTrip(context.Background(), tripID)
	byName := map[string]store.ItineraryItem{}
	for _, it := range items {
		byName[it.Name] = it
	}
	if it := byName["Mystery Bar"]; it.Latitude != 38.71 || it.Longitude != -9.14 {
		t.Errorf("Mystery Bar must keep the model's approximate coords, got (%v,%v)", it.Latitude, it.Longitude)
	}
	if _, ok := byName["Ghost Spot"]; ok {
		t.Error("Ghost Spot (no coords anywhere) must be dropped")
	}
}

// Degraded mode: no GOOGLE_PLACES_API_KEY. Locations with model coordinates
// ride the approximate tier under one aggregate warning; the rest drop.
func TestImportTripDegradedPlaces(t *testing.T) {
	resetDB(t)
	fake := newFakeAnthropic(t)
	fake.scriptNonStreamingTool(importToolName, `{
		"title": "No Places Key",
		"locations": [
			{"name": "Guessed Museum", "city": "Rome", "search_hint": "Guessed Museum, Rome", "latitude": 41.9, "longitude": 12.49},
			{"name": "Unknown Alley", "city": "Rome", "search_hint": "Unknown Alley, Rome"}
		]
	}`)
	svc := NewGooglePlacesService()
	svc.APIKey = ""
	swapPlacesService(t, svc)
	_, token := createTestUser(t, "degraded@example.com")

	rec := doJSON(t, http.MethodPost, "/api/v1/trips/import", token, map[string]any{"text": "roma plan"})
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, body %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	if int(body["item_count"].(float64)) != 1 {
		t.Errorf("item_count = %v, want 1", body["item_count"])
	}
	joined := fmt.Sprint(body["warnings"].([]any)...)
	if !strings.Contains(joined, "verification is unavailable") {
		t.Errorf("aggregate degraded warning missing: %v", joined)
	}
	if !strings.Contains(joined, "Unknown Alley") {
		t.Errorf("dropped place must be named: %v", joined)
	}
}

func TestImportTripNoTripFound(t *testing.T) {
	resetDB(t)
	fake := newFakeAnthropic(t)
	fake.scriptNonStreamingTool(importToolName, `{"title": "", "locations": []}`)
	swapCannedPlaces(t, nil)
	_, token := createTestUser(t, "notrip@example.com")

	rec := doJSON(t, http.MethodPost, "/api/v1/trips/import", token, map[string]any{"text": "a cookie recipe"})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422; body %s", rec.Code, rec.Body.String())
	}
	if n := countTrips(t); n != 0 {
		t.Errorf("trips created = %d, want 0", n)
	}
}

func TestImportTripValidation(t *testing.T) {
	resetDB(t)
	_, token := createTestUser(t, "valid@example.com")

	if rec := doJSON(t, http.MethodPost, "/api/v1/trips/import", token, map[string]any{"text": "   "}); rec.Code != http.StatusBadRequest {
		t.Errorf("empty text: status = %d, want 400", rec.Code)
	}
	if rec := doJSON(t, http.MethodPost, "/api/v1/trips/import", "", map[string]any{"text": "a plan"}); rec.Code != http.StatusUnauthorized {
		t.Errorf("anonymous: status = %d, want 401", rec.Code)
	}
}

func TestImportTripCapReached(t *testing.T) {
	resetDB(t)
	t.Setenv("MAX_TRIPS_PER_USER", "1")
	fake := newFakeAnthropic(t)
	fake.scriptNonStreamingTool(importToolName, importHappyPayload)
	swapCannedPlaces(t, nil)
	user, token := createTestUser(t, "capped@example.com")
	createTestTrip(t, user.ID, 1)

	rec := doJSON(t, http.MethodPost, "/api/v1/trips/import", token, map[string]any{"text": "another plan"})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422; body %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "trip limit") {
		t.Errorf("cap message missing: %s", rec.Body.String())
	}
	// The cap is pre-checked: a capped user must cost zero model spend.
	if n := len(fake.requestBodies()); n != 0 {
		t.Errorf("model calls = %d, want 0 (cap must precede extraction)", n)
	}
}

func TestImportTripDailyCapReached(t *testing.T) {
	resetDB(t)
	t.Setenv("FREE_IMPORTS_PER_DAY", "1")
	importCounter.resetAll()
	fake := newFakeAnthropic(t)
	fake.scriptNonStreamingTool(importToolName, importHappyPayload)
	swapCannedPlaces(t, nil)
	_, token := createTestUser(t, "daily@example.com")

	if rec := doJSON(t, http.MethodPost, "/api/v1/trips/import", token, map[string]any{"text": "plan one"}); rec.Code != http.StatusCreated {
		t.Fatalf("first import: status = %d, body %s", rec.Code, rec.Body.String())
	}
	rec := doJSON(t, http.MethodPost, "/api/v1/trips/import", token, map[string]any{"text": "plan two"})
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("second import: status = %d, want 429; body %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "import limit") {
		t.Errorf("daily-cap message missing: %s", rec.Body.String())
	}
	// The capped request must not reach the model.
	if n := len(fake.requestBodies()); n != 1 {
		t.Errorf("model calls = %d, want 1", n)
	}
}

// A Places outage (key configured, lookups erroring) with no model fallback
// coordinates must be a retryable 503 — never the user-blaming "couldn't
// locate any places" 422 — and no trip may be created.
func TestImportTripPlacesOutage(t *testing.T) {
	resetDB(t)
	fake := newFakeAnthropic(t)
	fake.scriptNonStreamingTool(importToolName, `{
		"title": "Outage Trip",
		"locations": [
			{"name": "Some Museum", "city": "Rome", "search_hint": "Some Museum, Rome", "day": 1},
			{"name": "Some Cafe", "city": "Rome", "search_hint": "Some Cafe, Rome", "day": 1}
		]
	}`)
	swapCannedPlacesFailing(t, nil, func(string) bool { return true })
	_, token := createTestUser(t, "outage@example.com")

	rec := doJSON(t, http.MethodPost, "/api/v1/trips/import", token, map[string]any{"text": "roma plan"})
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503; body %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "temporarily unavailable") {
		t.Errorf("retryable message missing: %s", rec.Body.String())
	}
	if n := countTrips(t); n != 0 {
		t.Errorf("trips created = %d, want 0", n)
	}
}

// Partial outage: failing lookups ride the approximate/dropped tiers under ONE
// aggregate warning — no per-place "couldn't be located" blame for places that
// were never actually searched.
func TestImportTripLookupFailureTiers(t *testing.T) {
	resetDB(t)
	fake := newFakeAnthropic(t)
	fake.scriptNonStreamingTool(importToolName, `{
		"title": "Partial Outage",
		"locations": [
			{"name": "Findable Cafe", "city": "Lisbon", "search_hint": "Findable Cafe, Lisbon", "day": 1},
			{"name": "Flaky Bar", "city": "Lisbon", "search_hint": "Flaky Bar, Lisbon", "day": 1, "latitude": 38.71, "longitude": -9.14},
			{"name": "Flaky Gallery", "city": "Lisbon", "search_hint": "Flaky Gallery, Lisbon", "day": 2}
		]
	}`)
	swapCannedPlacesFailing(t, nil, func(q string) bool { return strings.Contains(q, "Flaky") })
	_, token := createTestUser(t, "flaky@example.com")

	rec := doJSON(t, http.MethodPost, "/api/v1/trips/import", token, map[string]any{"text": "some plan"})
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, body %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	if int(body["item_count"].(float64)) != 2 {
		t.Errorf("item_count = %v, want 2 (Flaky Bar kept approximate, Flaky Gallery dropped)", body["item_count"])
	}
	joined := fmt.Sprint(body["warnings"].([]any)...)
	if !strings.Contains(joined, "verification is unavailable") {
		t.Errorf("aggregate outage warning missing: %v", joined)
	}
	if strings.Contains(joined, "Flaky") {
		t.Errorf("outage-affected places must not get per-place blame: %v", joined)
	}
}

// Extractions beyond importMaxLocations are capped with a visible warning —
// never a silent cut.
func TestImportTripCapsLocationCount(t *testing.T) {
	resetDB(t)
	var sb strings.Builder
	sb.WriteString(`{"title": "Mega Trip", "locations": [`)
	for i := 0; i < importMaxLocations+5; i++ {
		if i > 0 {
			sb.WriteString(",")
		}
		// Model coords on every location so the ones past the 50-lookup cap
		// ride the approximate tier instead of dropping.
		fmt.Fprintf(&sb, `{"name": "Place %d", "city": "Lisbon", "search_hint": "Place %d, Lisbon", "day": 1, "latitude": 38.7, "longitude": -9.1}`, i, i)
	}
	sb.WriteString(`]}`)
	fake := newFakeAnthropic(t)
	fake.scriptNonStreamingTool(importToolName, sb.String())
	swapCannedPlaces(t, nil)
	_, token := createTestUser(t, "mega@example.com")

	rec := doJSON(t, http.MethodPost, "/api/v1/trips/import", token, map[string]any{"text": "very long plan"})
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, body %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	if int(body["item_count"].(float64)) != importMaxLocations {
		t.Errorf("item_count = %v, want %d", body["item_count"], importMaxLocations)
	}
	joined := fmt.Sprint(body["warnings"].([]any)...)
	if !strings.Contains(joined, "5 more were left out") {
		t.Errorf("capped warning missing: %v", joined)
	}
}

// Oversized pastes must reach the model truncated head+tail, not rejected and
// not head-only.
func TestImportTripTruncatesOversizedPaste(t *testing.T) {
	resetDB(t)
	fake := newFakeAnthropic(t)
	fake.scriptNonStreamingTool(importToolName, importHappyPayload)
	swapCannedPlaces(t, nil)
	_, token := createTestUser(t, "long@example.com")

	text := "TRIP START Lisbon " + strings.Repeat("x", importMaxChars) + " TRIP END Sintra"
	rec := doJSON(t, http.MethodPost, "/api/v1/trips/import", token, map[string]any{"text": text})
	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, body %s", rec.Code, rec.Body.String())
	}
	bodies := fake.requestBodies()
	if len(bodies) != 1 {
		t.Fatalf("model calls = %d, want 1", len(bodies))
	}
	sent := string(bodies[0])
	if !strings.Contains(sent, "TRIP START Lisbon") || !strings.Contains(sent, "TRIP END Sintra") {
		t.Error("head and tail of the paste must both reach the model")
	}
	if !strings.Contains(sent, "truncated") {
		t.Error("truncation marker missing from the model request")
	}
}

func countTrips(t *testing.T) int {
	t.Helper()
	var n int
	if err := dbPool.QueryRow(context.Background(), `SELECT count(*) FROM trips`).Scan(&n); err != nil {
		t.Fatalf("countTrips: %v", err)
	}
	return n
}
