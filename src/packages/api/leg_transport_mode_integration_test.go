package main

// The Italy case, end to end (00068): a trip whose cities are 230km apart must
// come back from the sync as a TRAIN leg linking to Rome2Rio, not as the flight
// search every rung of the old ladder defaulted to — while the leg home, which
// has no coordinates, stays a flight.

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// italyTrip is Rome (2 nights) then Florence (2 nights), with real
// coordinates, plus a saved home airport so the two home legs exist.
func italyTrip(t *testing.T, owner uuid.UUID) store.Trip {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	chat := uuid.NewString()
	trip, err := q.CreateTrip(ctx, store.CreateTripParams{
		UserID: owner, Title: "Italy", ChatID: &chat,
	})
	if err != nil {
		t.Fatalf("createTrip: %v", err)
	}
	places := []struct {
		name, city string
		lat, lng   float64
		day        int32
	}{
		{"Colosseum", "Rome", 41.8902, 12.4922, 1},
		{"Trastevere", "Rome", 41.8890, 12.4695, 2},
		{"Uffizi", "Florence", 43.7678, 11.2553, 3},
		{"Duomo", "Florence", 43.7731, 11.2560, 4},
	}
	for i, p := range places {
		city, day := p.city, p.day
		if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
			TripID: trip.ID, Position: int32(i), Name: p.name,
			Latitude: p.lat, Longitude: p.lng, City: &city, Day: &day,
		}); err != nil {
			t.Fatalf("createItem %s: %v", p.name, err)
		}
	}
	return trip
}

// italyLegPayload is what the trip screen's bootstrap derivation posts before
// it has ever heard back: every leg a flight.
func italyLegPayload(home string) []map[string]any {
	return []map[string]any{
		{"kind": "transport", "todo_key": "transport:" + lower(home) + ">>rome",
			"title": home + " → Rome", "origin": home, "destination": "Rome",
			"provider": "google_flights", "position": 0, "depart_date": "2026-09-01", "passengers": 1},
		{"kind": "stay", "todo_key": "stay:rome", "title": "Stay in Rome",
			"destination": "Rome", "position": 1, "depart_date": "2026-09-01",
			"return_date": "2026-09-03", "guests": 1},
		{"kind": "transport", "todo_key": "transport:rome>>florence",
			"title": "Rome → Florence", "origin": "Rome", "destination": "Florence",
			"provider": "google_flights", "position": 2, "depart_date": "2026-09-03", "passengers": 1},
		{"kind": "stay", "todo_key": "stay:florence", "title": "Stay in Florence",
			"destination": "Florence", "position": 3, "depart_date": "2026-09-03",
			"return_date": "2026-09-05", "guests": 1},
		{"kind": "transport", "todo_key": "transport:florence>>" + lower(home),
			"title": "Florence → " + home, "origin": "Florence", "destination": home,
			"provider": "google_flights", "position": 4, "depart_date": "2026-09-05", "passengers": 1},
	}
}

func todoByTitleContains(todos []map[string]any, want string) map[string]any {
	for _, td := range todos {
		if title, _ := td["title"].(string); strings.Contains(title, want) {
			return td
		}
	}
	return nil
}

func TestSyncDerivesTrainForAShortIntercityLeg(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "italy@example.com")
	trip := italyTrip(t, user.ID)
	tripID := trip.ID.String()

	rec := doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/booking-todos", token, italyLegPayload("EWR"))
	if rec.Code != http.StatusOK {
		t.Fatalf("sync = %d: %s", rec.Code, rec.Body.String())
	}
	todos := decodeTodoList(t, rec)

	leg := todoByTitleContains(todos, "Rome → Florence")
	if leg == nil {
		t.Fatalf("no Rome → Florence row in %+v", todos)
	}
	if got, _ := leg["derived_mode"].(string); got != "train" {
		t.Errorf("Rome → Florence derived_mode = %q, want train", got)
	}
	if got, _ := leg["provider"].(string); got != "rome2rio" {
		t.Errorf("Rome → Florence provider = %q, want rome2rio (the client posted google_flights)", got)
	}
	if got, _ := leg["search_url"].(string); !strings.Contains(got, "rome2rio.com") {
		t.Errorf("Rome → Florence search_url = %q, want a rome2rio link", got)
	}
	// Nobody chose this: `mode` is where a choice lives and must stay empty.
	if got, ok := leg["mode"]; ok {
		t.Errorf("Rome → Florence mode = %v, want absent — the server derived it, nobody chose it", got)
	}

	// The leg home has no coordinates at its outer end, so geography says
	// nothing and it stays exactly what it was.
	home := todoByTitleContains(todos, "Florence → EWR")
	if home == nil {
		t.Fatalf("no Florence → EWR row in %+v", todos)
	}
	if got, _ := home["derived_mode"].(string); got != "flight" {
		t.Errorf("home leg derived_mode = %q, want flight", got)
	}
	if got, _ := home["provider"].(string); got != "google_flights" {
		t.Errorf("home leg provider = %q, want google_flights", got)
	}
}

// A chosen mode is the top rung, and a re-sync from any client — including a
// stale one still posting google_flights — must not walk over it.
func TestSyncKeepsAChosenModeAndItsLink(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "italy-override@example.com")
	trip := italyTrip(t, user.ID)
	tripID := trip.ID.String()
	base := "/api/v1/trips/" + tripID

	rec := doJSON(t, "PUT", base+"/booking-todos", token, italyLegPayload("EWR"))
	if rec.Code != http.StatusOK {
		t.Fatalf("first sync = %d: %s", rec.Code, rec.Body.String())
	}
	legID := todoByTitleContains(decodeTodoList(t, rec), "Rome → Florence")["id"].(string)

	// The traveler picks the flight anyway.
	if rec := doJSON(t, "PATCH", base+"/booking-todos/"+legID, token, map[string]any{
		"mode": "flight", "origin": "Rome", "destination": "Florence",
	}); rec.Code != http.StatusOK {
		t.Fatalf("set mode = %d: %s", rec.Code, rec.Body.String())
	}

	// A stale tab re-syncs the old flight-derived payload.
	rec = doJSON(t, "PUT", base+"/booking-todos", token, italyLegPayload("EWR"))
	if rec.Code != http.StatusOK {
		t.Fatalf("re-sync = %d: %s", rec.Code, rec.Body.String())
	}
	leg := todoByTitleContains(decodeTodoList(t, rec), "Rome → Florence")
	if got, _ := leg["mode"].(string); got != "flight" {
		t.Errorf("chosen mode = %q, want flight (the choice must survive a re-sync)", got)
	}
	if got, _ := leg["provider"].(string); got != "google_flights" {
		t.Errorf("provider = %q, want google_flights — the link must follow the CHOSEN mode", got)
	}
	// The derivation still records what geography says, so un-choosing works.
	if got, _ := leg["derived_mode"].(string); got != "train" {
		t.Errorf("derived_mode = %q, want train — the derivation is refreshed, not overwritten", got)
	}
}

// Trip Health and the trip page must agree about how a gap is crossed: before
// this, checkTransit hard-coded "flight" and the fix button said "Add flight"
// under a row the page was about to render as a train.
func TestTripReviewNamesTheRightModeForAGap(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "italy-review@example.com")
	trip := italyTrip(t, user.ID)

	rec := doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String()+"/review", token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("review = %d: %s", rec.Code, rec.Body.String())
	}
	findings, _ := decode(t, rec)["findings"].([]any)
	var transit map[string]any
	for _, f := range findings {
		m, _ := f.(map[string]any)
		if cat, _ := m["category"].(string); cat == "transit" {
			transit = m
			break
		}
	}
	if transit == nil {
		t.Fatalf("no transit finding in %+v", findings)
	}
	fix, _ := transit["fix"].(map[string]any)
	if got, _ := fix["mode"].(string); got != "train" {
		t.Errorf("transit fix mode = %q, want train", got)
	}
	if got, _ := fix["label"].(string); !strings.Contains(strings.ToLower(got), "train") {
		t.Errorf("transit fix label = %q, want it to name the train", got)
	}
}

// The planner's correction, on a trip whose page has never synced — so the leg
// has no checklist row yet and the tool must create the one the sync would
// have, on the canonical key.
func TestSetLegTransportModeToolWritesTheLeg(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "italy-tool@example.com")
	trip := italyTrip(t, user.ID)

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetLegTransportModeTool(s, []byte(`{"origin":"Rome","destination":"Florence","mode":"bus"}`))
	if isErr {
		t.Fatalf("set_leg_transport_mode errored: %s", msg)
	}
	// The result states the post-state, not just success.
	if !strings.Contains(msg, "bus") || !strings.Contains(msg, "Rome → Florence") {
		t.Errorf("result does not state the post-state: %q", msg)
	}

	todos, err := store.New(dbPool).ListBookingTodosByTrip(context.Background(), trip.ID)
	if err != nil {
		t.Fatalf("list todos: %v", err)
	}
	var row *store.BookingTodo
	for i := range todos {
		if todos[i].TodoKey == "transport:rome>>florence" {
			row = &todos[i]
		}
	}
	if row == nil {
		t.Fatalf("tool wrote no row on the canonical key; got %+v", todos)
	}
	if strPtrVal(row.Mode) != "bus" {
		t.Errorf("mode = %q, want bus", strPtrVal(row.Mode))
	}
	if !row.Auto {
		t.Error("the created row must be auto, so the page's sync adopts it instead of growing a second one")
	}
	if !strings.Contains(strPtrVal(row.SearchUrl), "rome2rio.com") {
		t.Errorf("search_url = %q, want a rome2rio link", strPtrVal(row.SearchUrl))
	}
}

// Refusing beats writing an orphan: an unmatched key would survive as a row
// nobody can see, and the model would have been told it succeeded.
func TestSetLegTransportModeToolRefusesALegTheTripLacks(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "italy-tool-refuse@example.com")
	trip := italyTrip(t, user.ID)

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetLegTransportModeTool(s, []byte(`{"origin":"Rome","destination":"Naples","mode":"train"}`))
	if !isErr {
		t.Fatalf("expected a refusal, got success: %s", msg)
	}
	if !strings.Contains(msg, "Rome") || !strings.Contains(msg, "Florence") {
		t.Errorf("refusal must name the trip's real legs, got: %q", msg)
	}
	todos, _ := store.New(dbPool).ListBookingTodosByTrip(context.Background(), trip.ID)
	if len(todos) != 0 {
		t.Errorf("refusal wrote %d rows, want none", len(todos))
	}
}

// The echo every itinerary write carries: without it the planner cannot see
// the app's answer, which is the whole reason it kept narrating flights.
func TestLegTransportSummaryNamesEachCrossing(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "italy-summary@example.com")
	trip := italyTrip(t, user.ID)
	ctx := context.Background()
	q := store.New(dbPool)
	items, _ := q.GetItineraryItemsByTrip(ctx, trip.ID)
	stays, _ := q.ListAccommodationsByTrip(ctx, trip.ID)
	full, _ := q.GetTripByIDAndOwner(ctx, store.GetTripByIDAndOwnerParams{ID: trip.ID, UserID: user.ID})

	got := legTransportSummary(full, items, stays, nil)
	if want := "- Rome → Florence: train\n"; got != want {
		t.Errorf("summary = %q, want %q", got, want)
	}
	// A chosen mode outranks the derivation here too, or the echo would tell
	// the model "train" about a leg the traveler set to a flight.
	got = legTransportSummary(full, items, stays, map[string]string{"transport:rome>>florence": "flight"})
	if want := "- Rome → Florence: flight\n"; got != want {
		t.Errorf("summary with an override = %q, want %q", got, want)
	}
}
