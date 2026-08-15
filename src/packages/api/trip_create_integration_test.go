package main

// POST /trips — manual trip creation (specs/log-past-trip). The point of the
// feature is that a logged trip is an ORDINARY trip, so most of these assert
// the trip's shape *through GET /trips*: the cities/city_pins laterals are what
// the "Your travels" band reads, and a logged trip has to arrive there without
// any special-casing. The (0,0) no-location sentinel is pinned here too — a
// name-only destination must count as a city and never as a map pin.

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

// createTripBody is the minimal valid request; tests mutate a copy.
func createTripBody() map[string]any {
	return map[string]any{
		"title":      "Japan 2019",
		"start_date": "2019-03-03",
		"end_date":   "2019-03-17",
		"destinations": []map[string]any{
			{"name": "Kyoto", "place_id": "pid-kyoto", "address": "Kyoto, Japan",
				"latitude": 35.0116, "longitude": 135.7681},
			{"name": "Osaka", "latitude": 34.6937, "longitude": 135.5023},
		},
	}
}

// postTripExpect posts body and fails unless the status matches, returning the
// decoded body either way (error envelopes decode as a map too).
func postTripExpect(t *testing.T, token string, body any, want int) map[string]any {
	t.Helper()
	rec := doJSON(t, "POST", "/api/v1/trips", token, body)
	if rec.Code != want {
		t.Fatalf("POST /trips = %d, want %d: %s", rec.Code, want, rec.Body.String())
	}
	return decode(t, rec)
}

func TestCreateTripPersistsDestinationsAsItinerary(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "logger@example.com")

	got := postTripExpect(t, token, createTripBody(), http.StatusCreated)

	if got["title"] != "Japan 2019" {
		t.Errorf("title = %v, want Japan 2019", got["title"])
	}
	if got["start_date"] != "2019-03-03" || got["end_date"] != "2019-03-17" {
		t.Errorf("dates = %v..%v, want 2019-03-03..2019-03-17", got["start_date"], got["end_date"])
	}
	// No conversation produced this trip, so it starts no chat lineage.
	if _, ok := got["chat_id"]; ok {
		t.Errorf("chat_id = %v, want absent (a logged trip has no conversation)", got["chat_id"])
	}

	// The response states the post-state: real items, in order, with the
	// picked coordinates.
	items, _ := got["items"].([]any)
	if len(items) != 2 {
		t.Fatalf("items = %d, want 2: %v", len(items), got["items"])
	}
	first, _ := items[0].(map[string]any)
	if first["name"] != "Kyoto" || first["city"] != "Kyoto" {
		t.Errorf("item 0 name/city = %v/%v, want Kyoto/Kyoto", first["name"], first["city"])
	}
	if first["place_id"] != "pid-kyoto" || first["address"] != "Kyoto, Japan" {
		t.Errorf("item 0 place_id/address = %v/%v", first["place_id"], first["address"])
	}
	if lat, _ := first["latitude"].(float64); lat < 35.0 || lat > 35.1 {
		t.Errorf("item 0 latitude = %v, want ~35.01", first["latitude"])
	}
	// A logged trip records where, not a day-by-day plan.
	if _, ok := first["day"]; ok {
		t.Errorf("item 0 day = %v, want absent", first["day"])
	}
	if second, _ := items[1].(map[string]any); second["name"] != "Osaka" {
		t.Errorf("item 1 name = %v, want Osaka (destination order preserved)", second["name"])
	}

	// What the "Your travels" band actually reads.
	rows := listTrips(t, "/api/v1/trips", token)
	if len(rows) != 1 {
		t.Fatalf("GET /trips = %d rows, want 1", len(rows))
	}
	cities, _ := rows[0]["cities"].([]any)
	if len(cities) != 2 || cities[0] != "Kyoto" || cities[1] != "Osaka" {
		t.Errorf("cities = %v, want [Kyoto Osaka]", rows[0]["cities"])
	}
	pins, _ := rows[0]["city_pins"].([]any)
	if len(pins) != 2 {
		t.Fatalf("city_pins = %d, want 2: %v", len(pins), rows[0]["city_pins"])
	}
	pin, _ := pins[0].(map[string]any)
	if pin["city"] != "Kyoto" {
		t.Errorf("pin 0 city = %v, want Kyoto", pin["city"])
	}

	waitForEventCount(t, user.ID, "trip_created", 1)
}

func TestCreateTripNameOnlyDestinationIsCityWithoutPin(t *testing.T) {
	resetDB(t)
	_, token := createTestUser(t, "nameonly@example.com")

	body := createTripBody()
	body["destinations"] = []map[string]any{
		{"name": "Kyoto", "latitude": 35.0116, "longitude": 135.7681},
		{"name": "Grandma's village"}, // search found nothing; typed by hand
	}
	postTripExpect(t, token, body, http.StatusCreated)

	rows := listTrips(t, "/api/v1/trips", token)
	cities, _ := rows[0]["cities"].([]any)
	if len(cities) != 2 {
		t.Errorf("cities = %v, want both destinations", rows[0]["cities"])
	}
	// Coordinates are never invented: the unlocated hub counts as a city and
	// stays off the map rather than pinning at (0,0) in the Atlantic.
	pins, _ := rows[0]["city_pins"].([]any)
	if len(pins) != 1 {
		t.Fatalf("city_pins = %d, want 1: %v", len(pins), rows[0]["city_pins"])
	}
	if pin, _ := pins[0].(map[string]any); pin["city"] != "Kyoto" {
		t.Errorf("pin city = %v, want Kyoto", pin["city"])
	}
}

func TestCreateTripTitleFallsBackToFirstDestination(t *testing.T) {
	resetDB(t)
	_, token := createTestUser(t, "untitled@example.com")

	body := createTripBody()
	delete(body, "title")
	got := postTripExpect(t, token, body, http.StatusCreated)
	if got["title"] != "Trip to Kyoto" {
		t.Errorf("title = %v, want the persistTrip fallback 'Trip to Kyoto'", got["title"])
	}
}

func TestCreateTripValidation(t *testing.T) {
	resetDB(t)
	_, token := createTestUser(t, "invalid@example.com")

	tooMany := make([]map[string]any, maxLoggedDestinations+1)
	for i := range tooMany {
		tooMany[i] = map[string]any{"name": "Place"}
	}

	cases := []struct {
		name   string
		mutate func(map[string]any)
	}{
		{"no destinations", func(b map[string]any) { b["destinations"] = []map[string]any{} }},
		{"too many destinations", func(b map[string]any) { b["destinations"] = tooMany }},
		{"blank destination name", func(b map[string]any) {
			b["destinations"] = []map[string]any{{"name": "   "}}
		}},
		{"over-long destination name", func(b map[string]any) {
			b["destinations"] = []map[string]any{{"name": strings.Repeat("x", maxNameLen+1)}}
		}},
		{"over-long title", func(b map[string]any) { b["title"] = strings.Repeat("x", maxNameLen+1) }},
		{"latitude out of range", func(b map[string]any) {
			b["destinations"] = []map[string]any{{"name": "Nowhere", "latitude": 91.0, "longitude": 0.0}}
		}},
		{"missing start_date", func(b map[string]any) { delete(b, "start_date") }},
		{"missing end_date", func(b map[string]any) { b["end_date"] = "" }},
		{"malformed date", func(b map[string]any) { b["start_date"] = "03/03/2019" }},
		{"end before start", func(b map[string]any) { b["end_date"] = "2019-03-02" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body := createTripBody()
			tc.mutate(body)
			postTripExpect(t, token, body, http.StatusBadRequest)
		})
	}

	// Nothing was written by any of the rejected requests.
	if rows := listTrips(t, "/api/v1/trips", token); len(rows) != 0 {
		t.Errorf("GET /trips = %d rows after rejected creates, want 0", len(rows))
	}
}

func TestCreateTripRequiresAuth(t *testing.T) {
	resetDB(t)
	rec := doJSON(t, "POST", "/api/v1/trips", "", createTripBody())
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated POST /trips = %d, want 401: %s", rec.Code, rec.Body.String())
	}
}

func TestCreateTripAtTripCap(t *testing.T) {
	resetDB(t)
	t.Setenv("MAX_TRIPS_PER_USER", "1")
	user, token := createTestUser(t, "atcap@example.com")
	createTestTrip(t, user.ID, 1) // parks the user at the cap

	got := postTripExpect(t, token, createTripBody(), http.StatusUnprocessableEntity)
	// persistTrip's cap message is written for people — the handler passes it
	// through rather than replacing it with a generic failure.
	msg, _ := got["message"].(string)
	if !strings.Contains(msg, "trip limit reached") {
		t.Errorf("message = %q, want the human cap message", msg)
	}
}

// A logged trip is indistinguishable from any other trip afterwards: it can be
// fetched, patched and deleted through the ordinary trip endpoints.
func TestCreateTripProducesAnOrdinaryTrip(t *testing.T) {
	resetDB(t)
	_, token := createTestUser(t, "ordinary@example.com")

	created := postTripExpect(t, token, createTripBody(), http.StatusCreated)
	id, _ := created["id"].(string)
	if id == "" {
		t.Fatal("created trip has no id")
	}

	rec := doJSON(t, "GET", "/api/v1/trips/"+id, token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET /trips/%s = %d: %s", id, rec.Code, rec.Body.String())
	}
	var full map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &full); err != nil {
		t.Fatalf("decode trip: %v", err)
	}
	if items, _ := full["items"].([]any); len(items) != 2 {
		t.Errorf("full view items = %d, want 2", len(items))
	}

	rec = doJSON(t, "PATCH", "/api/v1/trips/"+id, token, map[string]any{"title": "Japan, actually"})
	if rec.Code != http.StatusOK {
		t.Fatalf("PATCH /trips/%s = %d: %s", id, rec.Code, rec.Body.String())
	}

	rec = doJSON(t, "DELETE", "/api/v1/trips/"+id, token, nil)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("DELETE /trips/%s = %d: %s", id, rec.Code, rec.Body.String())
	}
}
