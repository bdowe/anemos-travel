package main

// List-row enrichment (item_count / booking_total / booking_booked / shared
// on GET /trips, and the item/booking fields on GET /trips/shared-with-me
// with the viewer boundary), plus the insight fields
// (specs/trips-page-insights): stays / packing / budget / summary /
// next_transport_depart / city_pins on GET /trips — and their deliberate
// ABSENCE on shared-with-me. The counts come from laterals in
// ListLatestTripsByOwner / ListLatestCollaboratedTripsForUser — one query
// per list, no N+1 — so these tests pin the wire shape, not the SQL.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"travel-route-planner/store"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
)

func addBookingTodo(t *testing.T, tripID uuid.UUID, key string, booked bool) {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	todo, err := q.CreateBookingTodo(ctx, store.CreateBookingTodoParams{
		TripID: tripID, Kind: "transport", TodoKey: key, Title: "Book " + key,
	})
	if err != nil {
		t.Fatalf("addBookingTodo(%s): %v", key, err)
	}
	if booked {
		if _, err := q.SetBookingTodoBooked(ctx, store.SetBookingTodoBookedParams{
			ID: todo.ID, TripID: tripID, Booked: true,
		}); err != nil {
			t.Fatalf("SetBookingTodoBooked(%s): %v", key, err)
		}
	}
}

// addBookingTodoDated is addBookingTodo with an explicit kind and depart
// date, for the next_transport_depart selection rules.
func addBookingTodoDated(t *testing.T, tripID uuid.UUID, key, kind string, booked bool, depart time.Time) {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	todo, err := q.CreateBookingTodo(ctx, store.CreateBookingTodoParams{
		TripID: tripID, Kind: kind, TodoKey: key, Title: "Book " + key,
		DepartDate: pgtype.Date{Time: depart, Valid: true},
	})
	if err != nil {
		t.Fatalf("addBookingTodoDated(%s): %v", key, err)
	}
	if booked {
		if _, err := q.SetBookingTodoBooked(ctx, store.SetBookingTodoBookedParams{
			ID: todo.ID, TripID: tripID, Booked: true,
		}); err != nil {
			t.Fatalf("SetBookingTodoBooked(%s): %v", key, err)
		}
	}
}

// seedStay seeds an accommodations row directly (the makeAdmin direct-SQL
// pattern): the confirmed/draft/dismissed/booked mix the stay laterals
// filter on has no single store mutation — drafts come from the sync
// upsert and booked flips from PATCH.
func seedStay(t *testing.T, tripID uuid.UUID, name string, auto, dismissed, booked bool) {
	t.Helper()
	if _, err := dbPool.Exec(context.Background(),
		`INSERT INTO accommodations (trip_id, name, auto, dismissed, booked) VALUES ($1, $2, $3, $4, $5)`,
		tripID, name, auto, dismissed, booked); err != nil {
		t.Fatalf("seedStay(%s): %v", name, err)
	}
}

func addChecklistItem(t *testing.T, tripID uuid.UUID, title string, checked bool) {
	t.Helper()
	if _, err := dbPool.Exec(context.Background(),
		`INSERT INTO trip_checklist_items (trip_id, title, checked) VALUES ($1, $2, $3)`,
		tripID, title, checked); err != nil {
		t.Fatalf("addChecklistItem(%s): %v", title, err)
	}
}

func setTripSummary(t *testing.T, tripID uuid.UUID, summary string) {
	t.Helper()
	if _, err := dbPool.Exec(context.Background(),
		`UPDATE trips SET summary = $1 WHERE id = $2`, summary, tripID); err != nil {
		t.Fatalf("setTripSummary: %v", err)
	}
}

func listTrips(t *testing.T, path, token string) []map[string]any {
	t.Helper()
	rec := doJSON(t, "GET", path, token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET %s = %d: %s", path, rec.Code, rec.Body.String())
	}
	var trips []map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &trips); err != nil {
		t.Fatalf("decode %s: %v (%s)", path, err, rec.Body.String())
	}
	return trips
}

func numField(row map[string]any, key string) (float64, bool) {
	v, ok := row[key].(float64)
	return v, ok
}

func TestTripListEnrichment(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 3)
	addBookingTodo(t, trip.ID, "flight-out", true)
	addBookingTodo(t, trip.ID, "stay-athens", false)

	rows := listTrips(t, "/api/v1/trips", ownerToken)
	if len(rows) != 1 {
		t.Fatalf("list rows = %d, want 1", len(rows))
	}
	row := rows[0]
	for key, want := range map[string]float64{
		"item_count": 3, "booking_total": 2, "booking_booked": 1,
	} {
		if got, ok := numField(row, key); !ok || got != want {
			t.Fatalf("%s = %v, want %v (%v)", key, row[key], want, row)
		}
	}
	// No collaborators yet: shared is false, so omitempty drops it.
	if v, present := row["shared"]; present && v != false {
		t.Fatalf("shared = %v before any collaborator, want absent/false", v)
	}

	// An editor joining flips shared on the owner's list row.
	_, editorToken := createTestUser(t, "editor@example.com")
	shareToken := createShare(t, ownerToken, trip.ID.String(), "editor")
	if rec := joinShare(t, editorToken, shareToken); rec.Code != http.StatusOK {
		t.Fatalf("join share = %d: %s", rec.Code, rec.Body.String())
	}
	row = listTrips(t, "/api/v1/trips", ownerToken)[0]
	if row["shared"] != true {
		t.Fatalf("shared = %v after editor join, want true", row["shared"])
	}
}

func TestTripListZeroBookingProgressStillSerializes(t *testing.T) {
	// The pointer fields exist so a real zero survives omitempty — a trip
	// with todos but nothing booked must say 0, not vanish.
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	addBookingTodo(t, trip.ID, "flight-out", false)

	row := listTrips(t, "/api/v1/trips", ownerToken)[0]
	if got, ok := numField(row, "booking_booked"); !ok || got != 0 {
		t.Fatalf("booking_booked = %v, want explicit 0", row["booking_booked"])
	}
	if got, ok := numField(row, "booking_total"); !ok || got != 1 {
		t.Fatalf("booking_total = %v, want 1", row["booking_total"])
	}
}

func TestSharedWithMeEnrichmentViewerBoundary(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 2)
	addBookingTodo(t, trip.ID, "flight-out", true)

	join := func(email, role string) string {
		_, token := createTestUser(t, email)
		shareToken := createShare(t, ownerToken, trip.ID.String(), role)
		var rec *httptest.ResponseRecorder
		if rec = joinShare(t, token, shareToken); rec.Code != http.StatusOK {
			t.Fatalf("join(%s) = %d: %s", role, rec.Code, rec.Body.String())
		}
		return token
	}
	editorToken := join("editor@example.com", "editor")
	viewerToken := join("viewer@example.com", "viewer")

	editorRow := listTrips(t, "/api/v1/trips/shared-with-me", editorToken)[0]
	if got, ok := numField(editorRow, "item_count"); !ok || got != 2 {
		t.Fatalf("editor item_count = %v, want 2", editorRow["item_count"])
	}
	if got, ok := numField(editorRow, "booking_total"); !ok || got != 1 {
		t.Fatalf("editor booking_total = %v, want 1", editorRow["booking_total"])
	}

	viewerRow := listTrips(t, "/api/v1/trips/shared-with-me", viewerToken)[0]
	if got, ok := numField(viewerRow, "item_count"); !ok || got != 2 {
		t.Fatalf("viewer item_count = %v, want 2", viewerRow["item_count"])
	}
	// Booking state is editor-visible only — the getTripHandler boundary.
	for _, key := range []string{"booking_total", "booking_booked"} {
		if v, present := viewerRow[key]; present {
			t.Fatalf("viewer row carries %s = %v, want absent", key, v)
		}
	}
}

func TestTripListInsightEnrichment(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 2)
	setTripSummary(t, trip.ID, "Ten days of island hopping")

	// Only confirmed stays (auto=false AND NOT dismissed) count — the
	// ListConfirmedAccommodationsByTrip rule.
	seedStay(t, trip.ID, "Hotel Athens", false, false, true)   // confirmed, booked
	seedStay(t, trip.ID, "Naxos Studio", false, false, false)  // confirmed, unbooked
	seedStay(t, trip.ID, "Suggested stay", true, false, false) // auto draft — excluded
	seedStay(t, trip.ID, "Dismissed draft", true, true, false) // tombstone — excluded

	addChecklistItem(t, trip.ID, "Passport", true)
	addChecklistItem(t, trip.ID, "Sunscreen", false)
	addChecklistItem(t, trip.ID, "Adapter", false)

	ctx := context.Background()
	q := store.New(dbPool)
	target := 2000.0
	if _, err := q.UpsertBudget(ctx, store.UpsertBudgetParams{
		TripID: trip.ID, TargetAmount: &target, Currency: "EUR",
	}); err != nil {
		t.Fatalf("UpsertBudget: %v", err)
	}
	for i, amount := range []float64{150, 50} {
		if _, err := q.CreateExpense(ctx, store.CreateExpenseParams{
			TripID: trip.ID, Category: "general",
			Label: fmt.Sprintf("expense %d", i), Amount: amount,
		}); err != nil {
			t.Fatalf("CreateExpense(%d): %v", i, err)
		}
	}

	row := listTrips(t, "/api/v1/trips", ownerToken)[0]
	for key, want := range map[string]float64{
		"stay_total": 2, "stay_booked": 1,
		"packing_total": 3, "packing_done": 1,
		"budget_target": 2000, "budget_spent": 200,
	} {
		if got, ok := numField(row, key); !ok || got != want {
			t.Fatalf("%s = %v, want %v (%v)", key, row[key], want, row)
		}
	}
	if row["budget_currency"] != "EUR" {
		t.Fatalf("budget_currency = %v, want EUR", row["budget_currency"])
	}
	if row["summary"] != "Ten days of island hopping" {
		t.Fatalf("summary = %v, want the trip blurb", row["summary"])
	}
}

func TestTripListInsightZeroesSerialize(t *testing.T) {
	// The pointer fields exist so a real zero survives omitempty: a trip
	// with no stays / checklist / expenses must say 0, not vanish — and no
	// budget row means no target plus the USD default, matching
	// buildBudgetResponse.
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	createTestTrip(t, owner.ID, 1)

	row := listTrips(t, "/api/v1/trips", ownerToken)[0]
	for _, key := range []string{
		"stay_total", "stay_booked", "packing_total", "packing_done", "budget_spent",
	} {
		if got, ok := numField(row, key); !ok || got != 0 {
			t.Fatalf("%s = %v, want explicit 0", key, row[key])
		}
	}
	if v, present := row["budget_target"]; present {
		t.Fatalf("budget_target = %v with no budget row, want absent", v)
	}
	if row["budget_currency"] != "USD" {
		t.Fatalf("budget_currency = %v, want the USD default", row["budget_currency"])
	}
	if v, present := row["next_transport_depart"]; present {
		t.Fatalf("next_transport_depart = %v with no todos, want absent", v)
	}
}

func TestTripListNextTransportDepart(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 1)
	today := time.Now().UTC().Truncate(24 * time.Hour)
	// Distractors: booked transport, stay kind, and a past date never
	// produce the nudge date.
	addBookingTodoDated(t, trip.ID, "booked-flight", "transport", true, today.AddDate(0, 0, 3))
	addBookingTodoDated(t, trip.ID, "stay-athens", "stay", false, today.AddDate(0, 0, 4))
	addBookingTodoDated(t, trip.ID, "missed-train", "transport", false, today.AddDate(0, 0, -3))
	// Qualifiers: the EARLIEST unbooked future transport wins.
	addBookingTodoDated(t, trip.ID, "ferry-naxos", "transport", false, today.AddDate(0, 0, 10))
	addBookingTodoDated(t, trip.ID, "flight-out", "transport", false, today.AddDate(0, 0, 5))

	row := listTrips(t, "/api/v1/trips", ownerToken)[0]
	want := today.AddDate(0, 0, 5).Format(dateLayout)
	if row["next_transport_depart"] != want {
		t.Fatalf("next_transport_depart = %v, want %s", row["next_transport_depart"], want)
	}

	// A trip whose only candidates are booked or past reports nothing.
	quiet := createTestTrip(t, owner.ID, 1)
	addBookingTodoDated(t, quiet.ID, "booked-flight", "transport", true, today.AddDate(0, 0, 3))
	addBookingTodoDated(t, quiet.ID, "missed-train", "transport", false, today.AddDate(0, 0, -3))
	var quietRow map[string]any
	for _, r := range listTrips(t, "/api/v1/trips", ownerToken) {
		if r["id"] == quiet.ID.String() {
			quietRow = r
		}
	}
	if quietRow == nil {
		t.Fatalf("quiet trip missing from list")
	}
	if v, present := quietRow["next_transport_depart"]; present {
		t.Fatalf("next_transport_depart = %v with no qualifying todo, want absent", v)
	}
}

func TestTripListCityPins(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	ctx := context.Background()
	q := store.New(dbPool)
	addItem := func(tripID uuid.UUID, pos int32, name string, city, dayTripFrom *string, lat, lng float64) {
		t.Helper()
		if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
			TripID: tripID, Position: pos, Name: name,
			City: city, DayTripFrom: dayTripFrom, Latitude: lat, Longitude: lng,
		}); err != nil {
			t.Fatalf("CreateItineraryItem(%s): %v", name, err)
		}
	}
	athens, paros, naxos, delphi := "Athens", "Paros", "Naxos", "Delphi"
	// Athens' first item carries the (0,0) no-location sentinel — the pin
	// must come from the first LOCATED item by position, never (0,0).
	addItem(trip.ID, 0, "Unlocated cafe", &athens, nil, 0, 0)
	addItem(trip.ID, 1, "Acropolis", &athens, nil, 37.97, 23.72)
	// day_trip_from overrides the item's own city for hub grouping.
	addItem(trip.ID, 2, "Naxos beach", &naxos, &paros, 37.08, 25.15)
	// A hub with only sentinel items is listed in cities but never pinned.
	addItem(trip.ID, 3, "Oracle", &delphi, nil, 0, 0)

	row := listTrips(t, "/api/v1/trips", ownerToken)[0]
	cities, _ := row["cities"].([]any)
	if len(cities) != 3 || cities[0] != "Athens" || cities[1] != "Paros" || cities[2] != "Delphi" {
		t.Fatalf("cities = %v, want [Athens Paros Delphi]", row["cities"])
	}
	pins, ok := row["city_pins"].([]any)
	if !ok || len(pins) != 2 {
		t.Fatalf("city_pins = %v, want 2 pins (Delphi unlocated)", row["city_pins"])
	}
	first, _ := pins[0].(map[string]any)
	second, _ := pins[1].(map[string]any)
	if first["city"] != "Athens" || first["lat"] != 37.97 || first["lng"] != 23.72 {
		t.Fatalf("pin[0] = %v, want Athens @ 37.97,23.72", first)
	}
	if second["city"] != "Paros" || second["lat"] != 37.08 || second["lng"] != 25.15 {
		t.Fatalf("pin[1] = %v, want Paros @ 37.08,25.15", second)
	}

	// No located items at all: city_pins is absent, not an empty array.
	bare := createTestTrip(t, owner.ID, 0)
	addItem(bare.ID, 0, "Unlocated oracle", &delphi, nil, 0, 0)
	var bareRow map[string]any
	for _, r := range listTrips(t, "/api/v1/trips", ownerToken) {
		if r["id"] == bare.ID.String() {
			bareRow = r
		}
	}
	if bareRow == nil {
		t.Fatalf("bare trip missing from list")
	}
	if v, present := bareRow["city_pins"]; present {
		t.Fatalf("city_pins = %v with no located items, want absent", v)
	}
}

func TestSharedWithMeInsightAbsence(t *testing.T) {
	// v1 exclusion (stricter than the viewer boundary): shared-with-me rows
	// carry NONE of the insight fields, for editors and viewers alike. Seed
	// real data on every insight source so absence proves the boundary, not
	// an empty trip.
	resetDB(t)
	owner, ownerToken := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 2)
	setTripSummary(t, trip.ID, "Owner-only blurb")
	seedStay(t, trip.ID, "Hotel Athens", false, false, true)
	addChecklistItem(t, trip.ID, "Passport", true)
	ctx := context.Background()
	q := store.New(dbPool)
	target := 500.0
	if _, err := q.UpsertBudget(ctx, store.UpsertBudgetParams{
		TripID: trip.ID, TargetAmount: &target, Currency: "EUR",
	}); err != nil {
		t.Fatalf("UpsertBudget: %v", err)
	}
	if _, err := q.CreateExpense(ctx, store.CreateExpenseParams{
		TripID: trip.ID, Category: "general", Label: "hotel", Amount: 120,
	}); err != nil {
		t.Fatalf("CreateExpense: %v", err)
	}
	addBookingTodoDated(t, trip.ID, "flight-out", "transport", false,
		time.Now().UTC().Truncate(24*time.Hour).AddDate(0, 0, 5))
	athens := "Athens"
	if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
		TripID: trip.ID, Position: 2, Name: "Acropolis",
		City: &athens, Latitude: 37.97, Longitude: 23.72,
	}); err != nil {
		t.Fatalf("CreateItineraryItem: %v", err)
	}

	join := func(email, role string) string {
		_, token := createTestUser(t, email)
		shareToken := createShare(t, ownerToken, trip.ID.String(), role)
		if rec := joinShare(t, token, shareToken); rec.Code != http.StatusOK {
			t.Fatalf("join(%s) = %d: %s", role, rec.Code, rec.Body.String())
		}
		return token
	}
	editorToken := join("editor@example.com", "editor")
	viewerToken := join("viewer@example.com", "viewer")

	insightKeys := []string{
		"summary", "stay_total", "stay_booked", "packing_total", "packing_done",
		"budget_target", "budget_spent", "budget_currency",
		"next_transport_depart", "city_pins",
	}
	for _, tc := range []struct{ name, token string }{
		{"editor", editorToken}, {"viewer", viewerToken},
	} {
		row := listTrips(t, "/api/v1/trips/shared-with-me", tc.token)[0]
		for _, key := range insightKeys {
			if v, present := row[key]; present {
				t.Fatalf("%s row carries %s = %v, want absent", tc.name, key, v)
			}
		}
	}
	// The owner's own list still carries them — the boundary is the shared
	// list, not the data.
	ownerRow := listTrips(t, "/api/v1/trips", ownerToken)[0]
	if got, ok := numField(ownerRow, "stay_total"); !ok || got != 1 {
		t.Fatalf("owner stay_total = %v, want 1", ownerRow["stay_total"])
	}
}
