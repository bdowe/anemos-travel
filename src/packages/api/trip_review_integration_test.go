package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"travel-route-planner/store"
)

// Postgres-backed tests for GET /trips/{id}/review. A deliberately-broken trip
// must surface the expected finding categories; a clean trip returns none; and
// a non-owner is 404'd (owner-or-editor scoping via editableTrip).

// reviewCategories drives the review endpoint and returns the set of categories
// present in the findings.
func reviewCategories(t *testing.T, id, token string) map[string]bool {
	t.Helper()
	rec := doJSON(t, "GET", "/api/v1/trips/"+id+"/review", token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET review = %d: %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	found := map[string]bool{}
	for _, f := range listOf(t, body, "findings") {
		if c, ok := f["category"].(string); ok {
			found[c] = true
		}
	}
	return found
}

func TestTripReview_BrokenTrip(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	// Two items, both day=nil (unscheduled).
	trip := createTestTrip(t, owner.ID, 2)
	id := trip.ID.String()

	// Date the trip (dates alone unlock the lodging night-walk).
	rec := doJSON(t, "PATCH", "/api/v1/trips/"+id, ownerToken, map[string]any{
		"start_date": "2026-08-01", "end_date": "2026-08-04",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("patch trip = %d: %s", rec.Code, rec.Body.String())
	}

	// An unbooked flight segment.
	rec = doJSON(t, "POST", "/api/v1/trips/"+id+"/segments", ownerToken, map[string]any{
		"mode": "flight", "origin": "JFK", "destination": "CDG",
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("add segment = %d: %s", rec.Code, rec.Body.String())
	}

	// Budget target 100 with a single 150 expense → over budget.
	rec = doJSON(t, "PUT", "/api/v1/trips/"+id+"/budget", ownerToken, map[string]any{"target_amount": 100})
	if rec.Code != http.StatusOK {
		t.Fatalf("put budget = %d: %s", rec.Code, rec.Body.String())
	}
	rec = doJSON(t, "POST", "/api/v1/trips/"+id+"/budget/expenses", ownerToken, map[string]any{
		"label": "Hotel", "amount": 150, "category": "lodging",
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("add expense = %d: %s", rec.Code, rec.Body.String())
	}

	got := reviewCategories(t, id, ownerToken)
	for _, want := range []string{"unscheduled", "lodging", "bookings", "budget"} {
		if !got[want] {
			t.Errorf("expected a %q finding, got categories %v", want, got)
		}
	}
}

func TestTripReview_CleanTrip(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	// No itinerary items → nothing unscheduled, no density/transit gaps.
	trip := createTestTrip(t, owner.ID, 0)
	id := trip.ID.String()

	rec := doJSON(t, "PATCH", "/api/v1/trips/"+id, ownerToken, map[string]any{
		"start_date": "2026-08-01", "end_date": "2026-08-04",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("patch trip = %d: %s", rec.Code, rec.Body.String())
	}

	// A stay covering every night (08-01..08-03, checkout 08-04 exclusive).
	rec = doJSON(t, "POST", "/api/v1/trips/"+id+"/accommodations", ownerToken, map[string]any{
		"name": "Grand Hotel", "check_in": "2026-08-01", "check_out": "2026-08-04",
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("add stay = %d: %s", rec.Code, rec.Body.String())
	}
	stayID := decode(t, rec)["id"].(string)
	// Mark it booked so no bookings finding.
	rec = doJSON(t, "PATCH", "/api/v1/trips/"+id+"/accommodations/"+stayID, ownerToken, map[string]any{"booked": true})
	if rec.Code != http.StatusOK {
		t.Fatalf("book stay = %d: %s", rec.Code, rec.Body.String())
	}

	// A comfortable budget (no expenses) → within budget.
	rec = doJSON(t, "PUT", "/api/v1/trips/"+id+"/budget", ownerToken, map[string]any{"target_amount": 1000})
	if rec.Code != http.StatusOK {
		t.Fatalf("put budget = %d: %s", rec.Code, rec.Body.String())
	}

	rec = doJSON(t, "GET", "/api/v1/trips/"+id+"/review", ownerToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET review = %d: %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	if fs := listOf(t, body, "findings"); len(fs) != 0 {
		t.Fatalf("clean trip should have no findings, got %v", fs)
	}
	// This fixture's dates are in the past, which pins the next-step past-trip
	// gate: no step, no progress (omitted, not all_set).
	if body["next_step"] != nil || body["plan_progress"] != nil {
		t.Fatalf("past trip should omit next_step/plan_progress, got %v / %v",
			body["next_step"], body["plan_progress"])
	}
}

// TestTripReview_NextStepPayload pins the Next Step CTA contract on a future-
// dated trip: the JSON keys, the ladder pick, prefix progress, the canonical-
// English seed, and the check_hours invariance (both cache variants must agree
// on the step).
func TestTripReview_NextStepPayload(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 2) // two items, both day=nil
	id := trip.ID.String()

	// Future dates keep the trip ahead of `now` whenever this test runs.
	start := time.Now().UTC().AddDate(0, 0, 30).Format("2006-01-02")
	end := time.Now().UTC().AddDate(0, 0, 33).Format("2006-01-02")
	rec := doJSON(t, "PATCH", "/api/v1/trips/"+id, ownerToken, map[string]any{
		"start_date": start, "end_date": end,
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("patch trip = %d: %s", rec.Code, rec.Body.String())
	}

	stepKind := func(query string) (string, map[string]any) {
		rec := doJSON(t, "GET", "/api/v1/trips/"+id+"/review"+query, ownerToken, nil)
		if rec.Code != http.StatusOK {
			t.Fatalf("GET review%s = %d: %s", query, rec.Code, rec.Body.String())
		}
		body := decode(t, rec)
		step, ok := body["next_step"].(map[string]any)
		if !ok {
			t.Fatalf("next_step missing: %v", body)
		}
		kind, _ := step["kind"].(string)
		return kind, body
	}

	// Both items are unscheduled → phase 2, plan_itinerary.
	kind, body := stepKind("")
	if kind != "plan_itinerary" {
		t.Fatalf("kind = %q, want plan_itinerary", kind)
	}
	step := body["next_step"].(map[string]any)
	if title, _ := step["title"].(string); title == "" {
		t.Fatalf("localized title missing: %v", step)
	}
	if seed, _ := step["seed_prompt"].(string); !strings.Contains(seed, "update_itinerary_section") {
		t.Fatalf("seed_prompt off: %v", step)
	}
	progress, ok := body["plan_progress"].(map[string]any)
	if !ok || progress["done"] != float64(1) || progress["total"] != float64(6) {
		t.Fatalf("plan_progress = %v, want 1/6", body["plan_progress"])
	}

	// check_hours must not change the step (deterministic across variants).
	hoursKind, _ := stepKind("?check_hours=true")
	if hoursKind != kind {
		t.Fatalf("check_hours variant diverged: %q vs %q", hoursKind, kind)
	}
}

// TestTripReview_NextStepWalkIntegration drives phase 3 through the real
// stack: the client syncs its derived checklist, and the card must name the
// OUTBOUND FLIGHT before any stay — then advance to that city's stay the
// moment the leg's checkbox is ticked, with no accommodation or segment row
// ever created (specs/next-step-cta v2).
func TestTripReview_NextStepWalkIntegration(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	id := trip.ID.String()

	start := time.Now().UTC().AddDate(0, 0, 30)
	end := start.AddDate(0, 0, 3)
	day := func(d string) string { return d }
	rec := doJSON(t, "PATCH", "/api/v1/trips/"+id, ownerToken, map[string]any{
		"start_date": start.Format("2006-01-02"), "end_date": end.Format("2006-01-02"),
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("patch trip = %d: %s", rec.Code, rec.Body.String())
	}

	// Two scheduled city days so the ladder clears phases 2 and 4.
	q := store.New(dbPool)
	cities := []struct {
		name, city string
		day        int32
	}{{"Louvre", "Paris", 1}, {"Musée d'Orsay", "Paris", 2},
		{"Vieux Lyon", "Lyon", 3}, {"Parc de la Tête d'Or", "Lyon", 4}}
	for i, c := range cities {
		city, d := c.city, c.day
		if _, err := q.CreateItineraryItem(context.Background(), store.CreateItineraryItemParams{
			TripID: trip.ID, Position: int32(i), Name: c.name,
			Latitude: 48.86, Longitude: 2.34, City: &city, Day: &d,
		}); err != nil {
			t.Fatalf("create item %s: %v", c.name, err)
		}
	}

	// The client's derived checklist, in _deriveTodos order.
	sync := doJSON(t, "PUT", "/api/v1/trips/"+id+"/booking-todos", ownerToken, []map[string]any{
		{"kind": "transport", "todo_key": "transport:ewr>>paris", "title": "EWR → Paris",
			"provider": "google_flights", "position": 0, "origin": "EWR", "destination": "Paris",
			"depart_date": day(start.Format("2006-01-02")), "passengers": 1},
		{"kind": "stay", "todo_key": "stay:paris", "title": "Stay in Paris",
			"provider": "airbnb", "position": 1, "destination": "Paris",
			"depart_date": day(start.Format("2006-01-02")),
			"return_date": day(start.AddDate(0, 0, 2).Format("2006-01-02")), "guests": 1},
	})
	if sync.Code != http.StatusOK {
		t.Fatalf("sync booking-todos = %d: %s", sync.Code, sync.Body.String())
	}
	var todos []map[string]any
	if err := json.Unmarshal(sync.Body.Bytes(), &todos); err != nil {
		t.Fatalf("decode todos: %v (%s)", err, sync.Body.String())
	}
	if len(todos) != 2 {
		t.Fatalf("synced %d todos, want 2: %s", len(todos), sync.Body.String())
	}

	step := func(t *testing.T) map[string]any {
		t.Helper()
		rec := doJSON(t, "GET", "/api/v1/trips/"+id+"/review", ownerToken, nil)
		if rec.Code != http.StatusOK {
			t.Fatalf("GET review = %d: %s", rec.Code, rec.Body.String())
		}
		body := decode(t, rec)
		s, ok := body["next_step"].(map[string]any)
		if !ok {
			t.Fatalf("next_step missing: %v", body)
		}
		progress, ok := body["plan_progress"].(map[string]any)
		if !ok || progress["done"] != float64(2) || progress["total"] != float64(6) {
			t.Fatalf("plan_progress = %v, want 2/6", body["plan_progress"])
		}
		return s
	}

	// The flight comes first, even though every night is also unbooked.
	first := step(t)
	if kind, _ := first["kind"].(string); kind != "add_transport" {
		t.Fatalf("kind = %q, want add_transport (the outbound flight): %v", kind, first)
	}
	if title, _ := first["title"].(string); title != "Book your flight to Paris" {
		t.Fatalf("title = %q, want the mode-aware flight title", title)
	}

	// Tick the leg's checkbox — no segment row is created — and the card moves
	// to that city's stay.
	legID, _ := todos[0]["id"].(string)
	if rec := doJSON(t, "PATCH", "/api/v1/trips/"+id+"/booking-todos/"+legID, ownerToken,
		map[string]any{"booked": true}); rec.Code != http.StatusOK {
		t.Fatalf("patch todo booked = %d: %s", rec.Code, rec.Body.String())
	}
	second := step(t)
	if kind, _ := second["kind"].(string); kind != "add_lodging" {
		t.Fatalf("kind = %q, want add_lodging after the leg is booked: %v", kind, second)
	}
	if title, _ := second["title"].(string); title != "Book your stay in Paris" {
		t.Fatalf("title = %q, want the per-city stay title", title)
	}
}

func TestTripReview_NonOwner404(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "owner@example.com")
	_, strangerToken := createTestUser(t, "stranger@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	id := trip.ID.String()

	rec := doJSON(t, "GET", "/api/v1/trips/"+id+"/review", strangerToken, nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("non-owner review = %d, want 404: %s", rec.Code, rec.Body.String())
	}
}

// TestTripReview_HoursFindings drives the ?check_hours=true path against a fake
// Google Places double: a place scheduled to a weekday it's closed on surfaces
// an "hours" finding, and the check does not run without the query flag.
func TestTripReview_HoursFindings(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	id := trip.ID.String()

	// 2026-08-03 is a Monday; the place is "Closed" on Mondays in the double.
	rec := doJSON(t, "PATCH", "/api/v1/trips/"+id, ownerToken, map[string]any{
		"start_date": "2026-08-03", "end_date": "2026-08-05",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("patch trip = %d: %s", rec.Code, rec.Body.String())
	}

	// An item with a place_id, scheduled to Day 1 (the Monday).
	pid := "p1"
	day := int32(1)
	if _, err := store.New(dbPool).CreateItineraryItem(context.Background(), store.CreateItineraryItemParams{
		TripID: trip.ID, Position: 0, Name: "Musée Rodin", PlaceID: &pid,
		Latitude: 48.85, Longitude: 2.31, Day: &day,
	}); err != nil {
		t.Fatalf("insert item: %v", err)
	}

	// Point the shared Places singleton at the closed-Monday double.
	svc, _ := placesDouble(t, closedMondayDetailsJSON)
	prev := placesService
	placesService = svc
	t.Cleanup(func() { placesService = prev })

	// Without the flag: no hours check.
	if got := reviewCategories(t, id, ownerToken); got["hours"] {
		t.Fatalf("hours finding present without ?check_hours: %v", got)
	}

	// With the flag: the closed-weekday warning appears.
	rec = doJSON(t, "GET", "/api/v1/trips/"+id+"/review?check_hours=true", ownerToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET review = %d: %s", rec.Code, rec.Body.String())
	}
	var gotHours bool
	for _, f := range listOf(t, decode(t, rec), "findings") {
		if f["category"] == "hours" {
			gotHours = true
		}
	}
	if !gotHours {
		t.Fatalf("expected an hours finding with ?check_hours=true: %s", rec.Body.String())
	}
}

// TestTripReview_WeatherFindings exercises the always-on weather check against a
// rainy forecast double: an outdoor item on a rainy trip day yields a weather
// finding.
func TestTripReview_WeatherFindings(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	id := trip.ID.String()

	// Near-future dates so the forecast (not archive) path runs and its dates
	// line up exactly with the trip days.
	start := time.Now().AddDate(0, 0, 3)
	rec := doJSON(t, "PATCH", "/api/v1/trips/"+id, ownerToken, map[string]any{
		"start_date": start.Format(dateLayout),
		"end_date":   start.AddDate(0, 0, 1).Format(dateLayout),
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("patch trip = %d: %s", rec.Code, rec.Body.String())
	}

	// An outdoor attraction in Paris on Day 1.
	city := "Paris"
	category := "attraction"
	day := int32(1)
	if _, err := store.New(dbPool).CreateItineraryItem(context.Background(), store.CreateItineraryItemParams{
		TripID: trip.ID, Position: 0, Name: "Eiffel Tower", City: &city, Category: &category,
		Latitude: 48.85, Longitude: 2.35, Day: &day,
	}); err != nil {
		t.Fatalf("insert item: %v", err)
	}

	// Point the shared weather singleton at a rainy, mild forecast double.
	prev := weatherService
	weatherService = weatherStub(t, true, 22, 14)
	t.Cleanup(func() { weatherService = prev })

	if got := reviewCategories(t, id, ownerToken); !got["weather"] {
		t.Fatalf("expected a weather finding for a rainy outdoor day, got %v", got)
	}
}
