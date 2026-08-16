package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"testing"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// daily_spend_integration_test.go — GET /trips/{id}/budget/daily-spend and the
// leg-keyed expense it produces (specs/daily-spend-guide, migration 00070).

// seedTwoCityTrip builds Lisbon (Sep 1 → Sep 5, 4 nights) then Porto (Sep 5 →
// Sep 8, 3 nights): a 7-night trip whose two legs SHARE Sep 5. That shared day
// is the whole reason the multiplier is nights — 4+3 = 7 reconciles with the
// trip, 5+4 = 9 would not.
func seedTwoCityTrip(t *testing.T, trip store.Trip, owner uuid.UUID) {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	if _, err := q.UpdateTrip(ctx, store.UpdateTripParams{
		ID: trip.ID, UserID: owner,
		StartDate: validDate("2026-09-01"), EndDate: validDate("2026-09-08"),
	}); err != nil {
		t.Fatalf("seed trip dates: %v", err)
	}
	seed := func(pos int, name, city string, day int) {
		t.Helper()
		d := int32(day)
		if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
			TripID: trip.ID, Position: int32(pos), Name: name, City: &city, Day: &d,
			Latitude: 38.72 + float64(pos)*0.01, Longitude: -9.13,
		}); err != nil {
			t.Fatalf("seed item %s: %v", name, err)
		}
	}
	for i := 0; i < 5; i++ {
		seed(i, fmt.Sprintf("Lisbon Spot %d", i+1), "Lisbon", i+1)
	}
	for i := 0; i < 3; i++ {
		seed(5+i, fmt.Sprintf("Porto Spot %d", i+1), "Porto", 5+i)
	}
	if _, err := q.CreateAccommodation(ctx, store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Lisbon Stay",
		CheckIn: validDate("2026-09-01"), CheckOut: validDate("2026-09-05"),
	}); err != nil {
		t.Fatalf("seed Lisbon stay: %v", err)
	}
	if _, err := q.CreateAccommodation(ctx, store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Porto Stay",
		CheckIn: validDate("2026-09-05"), CheckOut: validDate("2026-09-08"),
	}); err != nil {
		t.Fatalf("seed Porto stay: %v", err)
	}
}

func cityRows(t *testing.T, body map[string]any) []map[string]any {
	t.Helper()
	raw, _ := body["cities"].([]any)
	out := make([]map[string]any, 0, len(raw))
	for _, r := range raw {
		out = append(out, r.(map[string]any))
	}
	return out
}

func TestDailySpendPerCity(t *testing.T) {
	resetDB(t)
	freshDailySpendCache(t)
	fake := newFakeAnthropic(t)
	fake.scriptNonStreamingTool(dailySpendToolName, `{"estimates":[
		{"city":"Lisbon","daily_amount":50,"includes":"Coffee, a casual lunch, dinner with wine."},
		{"city":"Porto","daily_amount":45,"includes":"Coffee, a casual lunch, dinner with wine."}
	]}`)

	owner, token := createTestUser(t, "spend-owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	seedTwoCityTrip(t, trip, owner.ID)
	tripID := trip.ID.String()

	body := decode(t, doJSON(t, "GET", "/api/v1/trips/"+tripID+"/budget/daily-spend", token, nil))
	if body["basis"] != dailySpendBasisEstimate {
		t.Fatalf("basis must ride the answer: %v", body["basis"])
	}
	if body["currency"] != "USD" {
		t.Fatalf("currency = %v, want the budget's USD default", body["currency"])
	}
	// Nothing stated, no saved profile ⇒ the default tier, and the answer SAYS
	// so rather than letting the card imply a preference.
	if body["tier"] != defaultSpendTier || body["tier_source"] != tierSourceDefault {
		t.Fatalf("tier = %v from %v", body["tier"], body["tier_source"])
	}
	if body["unavailable_reason"] != nil {
		t.Fatalf("unexpected unavailable: %v", body["unavailable_reason"])
	}

	cities := cityRows(t, body)
	if len(cities) != 2 {
		t.Fatalf("want two cities, got %v", cities)
	}
	want := []struct {
		legKey string
		nights float64
		daily  float64
	}{{"Lisbon", 4, 50}, {"Porto", 3, 45}}
	total := 0.0
	for i, w := range want {
		got := cities[i]
		if got["leg_key"] != w.legKey || got["label"] != w.legKey {
			t.Errorf("city %d = %v, want %s", i, got, w.legKey)
		}
		if got["nights"].(float64) != w.nights {
			t.Errorf("%s nights = %v, want %v", w.legKey, got["nights"], w.nights)
		}
		if got["daily_amount"].(float64) != w.daily {
			t.Errorf("%s daily = %v, want %v", w.legKey, got["daily_amount"], w.daily)
		}
		if got["includes"] == "" {
			t.Errorf("%s should say what the amount covers", w.legKey)
		}
		total += got["nights"].(float64)
	}
	// The reconciliation the nights-not-days decision buys: Sep 1 → Sep 8 is 7
	// nights, and the per-city nights sum to exactly that. Days would give 9.
	if total != 7 {
		t.Fatalf("per-city nights sum = %v, want the trip's 7", total)
	}
}

// The nights on this card and the nights on the city header chip come from ONE
// derivation. This is the Go half of the twin-fixture parity contract with
// test/leg_ranges_test.dart (docs/zen.md) — the fixture above is the same trip
// both sides measure.
func TestDailySpendNightsMatchRenderedLegs(t *testing.T) {
	resetDB(t)
	freshDailySpendCache(t)
	fake := newFakeAnthropic(t)
	fake.scriptNonStreamingTool(dailySpendToolName, `{"estimates":[
		{"city":"Lisbon","daily_amount":50,"includes":"Meals."},
		{"city":"Porto","daily_amount":45,"includes":"Meals."}
	]}`)

	owner, token := createTestUser(t, "parity@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	seedTwoCityTrip(t, trip, owner.ID)

	ctx := context.Background()
	q := store.New(dbPool)
	fresh, err := q.GetTripByIDAndOwner(ctx, store.GetTripByIDAndOwnerParams{ID: trip.ID, UserID: owner.ID})
	if err != nil {
		t.Fatalf("reload trip: %v", err)
	}
	items, _ := q.GetItineraryItemsByTrip(ctx, trip.ID)
	stays, _ := q.ListAccommodationsByTrip(ctx, trip.ID)
	byKey := map[string]int{}
	for _, l := range computeTripLegs(fresh, items, stays) {
		if l.Start != nil && l.End != nil {
			byKey[l.Key] = nightsBetween(*l.Start, *l.End)
		}
	}

	body := decode(t, doJSON(t, "GET",
		"/api/v1/trips/"+trip.ID.String()+"/budget/daily-spend", token, nil))
	for _, c := range cityRows(t, body) {
		key := c["leg_key"].(string)
		if want, ok := byKey[key]; !ok || float64(want) != c["nights"].(float64) {
			t.Errorf("%s nights = %v, rendered leg says %v", key, c["nights"], byKey[key])
		}
	}
}

func TestDailySpendTierResolution(t *testing.T) {
	resetDB(t)
	freshDailySpendCache(t)
	fake := newFakeAnthropic(t)
	fake.scriptNonStreamingTool(dailySpendToolName,
		`{"estimates":[{"city":"Lisbon","daily_amount":50,"includes":"Meals."},{"city":"Porto","daily_amount":45,"includes":"Meals."}]}`)

	owner, token := createTestUser(t, "tier@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	seedTwoCityTrip(t, trip, owner.ID)
	base := "/api/v1/trips/" + trip.ID.String() + "/budget/daily-spend"

	doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{"budget": "luxury"})
	body := decode(t, doJSON(t, "GET", base, token, nil))
	if body["tier"] != "luxury" || body["tier_source"] != tierSourceProfile {
		t.Fatalf("saved profile should answer: tier=%v source=%v", body["tier"], body["tier_source"])
	}

	body = decode(t, doJSON(t, "GET", base+"?tier=budget", token, nil))
	if body["tier"] != "budget" || body["tier_source"] != tierSourceRequest {
		t.Fatalf("stated tier should win: tier=%v source=%v", body["tier"], body["tier_source"])
	}

	// The one 400 on this endpoint: the caller named something we do not
	// understand. Everything else degrades.
	if rec := doJSON(t, "GET", base+"?tier=baller", token, nil); rec.Code != http.StatusBadRequest {
		t.Fatalf("unknown tier = %d, want 400", rec.Code)
	}
}

// Every failure answers 200 with a reason code and an empty list, so the Budget
// tab drops the section instead of showing the traveler an error they did
// nothing to cause.
func TestDailySpendDegradesNeverErrors(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "degrade@example.com")
	dated := createTestTrip(t, owner.ID, 0)
	seedTwoCityTrip(t, dated, owner.ID)

	t.Run("no api key", func(t *testing.T) {
		freshDailySpendCache(t)
		newFakeAnthropic(t)
		t.Setenv("ANTHROPIC_API_KEY", "")
		body := decode(t, doJSON(t, "GET",
			"/api/v1/trips/"+dated.ID.String()+"/budget/daily-spend", token, nil))
		if body["unavailable_reason"] != dailySpendNotConfigured {
			t.Fatalf("reason = %v, want %s", body["unavailable_reason"], dailySpendNotConfigured)
		}
		if len(cityRows(t, body)) != 0 {
			t.Fatal("no key ⇒ no cities")
		}
	})

	t.Run("provider failure", func(t *testing.T) {
		freshDailySpendCache(t)
		fake := newFakeAnthropic(t)
		fake.scriptNonStreamingHTTPError(400, "invalid_request_error", "credit balance too low")
		body := decode(t, doJSON(t, "GET",
			"/api/v1/trips/"+dated.ID.String()+"/budget/daily-spend", token, nil))
		if body["unavailable_reason"] != dailySpendProviderError {
			t.Fatalf("reason = %v, want %s", body["unavailable_reason"], dailySpendProviderError)
		}
	})

	t.Run("undated trip", func(t *testing.T) {
		freshDailySpendCache(t)
		newFakeAnthropic(t)
		bare := createTestTrip(t, owner.ID, 2) // items, but no cities and no dates
		body := decode(t, doJSON(t, "GET",
			"/api/v1/trips/"+bare.ID.String()+"/budget/daily-spend", token, nil))
		if body["unavailable_reason"] != dailySpendNoCities {
			t.Fatalf("reason = %v, want %s", body["unavailable_reason"], dailySpendNoCities)
		}
		// It still states the tier and currency: the section is absent, not the
		// answer's meaning.
		if body["tier"] == nil || body["currency"] != "USD" {
			t.Fatalf("shape should survive an empty answer: %v", body)
		}
	})
}

// editableTrip, not viewableTrip: the endpoint spends a model call and only an
// editor can act on the answer.
func TestDailySpendIsEditorOnly(t *testing.T) {
	resetDB(t)
	freshDailySpendCache(t)
	fake := newFakeAnthropic(t)
	fake.scriptNonStreamingTool(dailySpendToolName,
		`{"estimates":[{"city":"Lisbon","daily_amount":50,"includes":"Meals."}]}`)

	owner, token := createTestUser(t, "editor-only@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	seedTwoCityTrip(t, trip, owner.ID)
	tripID := trip.ID.String()

	_, viewerToken := createTestUser(t, "spend-viewer@example.com")
	shareToken := createShare(t, token, tripID, "viewer")
	if rec := joinShare(t, viewerToken, shareToken); rec.Code != http.StatusOK {
		t.Fatalf("viewer join = %d: %s", rec.Code, rec.Body.String())
	}
	if rec := doJSON(t, "GET", "/api/v1/trips/"+tripID+"/budget/daily-spend", viewerToken, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("viewer daily-spend = %d, want 404", rec.Code)
	}

	_, editorToken := createTestUser(t, "spend-editor@example.com")
	editShare := createShare(t, token, tripID, "editor")
	if rec := joinShare(t, editorToken, editShare); rec.Code != http.StatusOK {
		t.Fatalf("editor join = %d: %s", rec.Code, rec.Body.String())
	}
	if rec := doJSON(t, "GET", "/api/v1/trips/"+tripID+"/budget/daily-spend", editorToken, nil); rec.Code != http.StatusOK {
		t.Fatalf("editor daily-spend = %d, want 200: %s", rec.Code, rec.Body.String())
	}
}

// --- the leg-keyed expense (migration 00070) --------------------------------

func TestLegKeyedExpenseIsUpsertNotDuplicate(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "legkey@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	seedTwoCityTrip(t, trip, owner.ID)
	path := "/api/v1/trips/" + trip.ID.String() + "/budget/expenses"

	add := map[string]any{
		"label": "Food & drink · Lisbon", "category": "food",
		"planned_amount": 200, "leg_key": "Lisbon",
	}
	rec := doJSON(t, "POST", path, token, add)
	if rec.Code != http.StatusCreated {
		t.Fatalf("first add = %d: %s", rec.Code, rec.Body.String())
	}
	first := decode(t, rec)
	if first["leg_key"] != "Lisbon" {
		t.Fatalf("leg_key must ride the wire so the card can find its own line: %v", first)
	}
	// A city plan is the TRAVELER's, never a system mirror — no booking-state
	// change may reach it.
	if first["auto"] != false {
		t.Fatalf("a leg-keyed plan must not be auto: %v", first)
	}
	if first["purchased"] != false || first["planned_amount"].(float64) != 200 {
		t.Fatalf("should file as planned, not paid: %v", first)
	}

	// Tapping the same city again returns the SAME row, untouched — even at a
	// different amount, because by then the number on the line is the
	// traveler's plan, not the suggestion's.
	add["planned_amount"] = 999
	rec = doJSON(t, "POST", path, token, add)
	if rec.Code != http.StatusOK {
		t.Fatalf("second add = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	second := decode(t, rec)
	if second["id"] != first["id"] {
		t.Fatalf("second tap created a new line: %v vs %v", second["id"], first["id"])
	}
	if second["planned_amount"].(float64) != 200 {
		t.Fatalf("existing plan must not be restated: %v", second)
	}

	// A different city is a different line; the same city in a different
	// category would be too.
	if rec := doJSON(t, "POST", path, token, map[string]any{
		"label": "Food & drink · Porto", "category": "food",
		"planned_amount": 135, "leg_key": "Porto",
	}); rec.Code != http.StatusCreated {
		t.Fatalf("second city = %d, want 201: %s", rec.Code, rec.Body.String())
	}

	var rows []map[string]any
	if err := json.Unmarshal(doJSON(t, "GET", path, token, nil).Body.Bytes(), &rows); err != nil {
		t.Fatalf("decode expenses: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("want exactly two lines, got %d: %v", len(rows), rows)
	}
	budget := decode(t, doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String()+"/budget", token, nil))
	if budget["planned"].(float64) != 335 || budget["spent"].(float64) != 0 {
		t.Fatalf("plans must raise planned/projected but never spent: %v", budget)
	}
	if budget["projected"].(float64) != 335 {
		t.Fatalf("projected = %v, want 335", budget["projected"])
	}
}

func TestLegKeyedExpenseRejectsUnknownAndConflictingKeys(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "legkey-bad@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	seedTwoCityTrip(t, trip, owner.ID)
	path := "/api/v1/trips/" + trip.ID.String() + "/budget/expenses"

	// The 00064 rule: the server confirms the key against the trip's real legs,
	// so a stale tab cannot mint an orphan no card can ever claim.
	if rec := doJSON(t, "POST", path, token, map[string]any{
		"label": "Food", "category": "food", "planned_amount": 100, "leg_key": "Madrid",
	}); rec.Code != http.StatusBadRequest {
		t.Fatalf("unknown leg = %d, want 400", rec.Code)
	}
	if rec := doJSON(t, "POST", path, token, map[string]any{
		"label": "Food", "category": "food", "planned_amount": 100, "leg_key": "  ",
	}); rec.Code != http.StatusBadRequest {
		t.Fatalf("blank leg = %d, want 400", rec.Code)
	}
	// A city plan and a booking mirror have different owners and different
	// unbook rules; a row that was both would need two answers to one question.
	if rec := doJSON(t, "POST", path, token, map[string]any{
		"label": "Food", "category": "food", "actual_amount": 100,
		"leg_key": "Lisbon", "source_kind": "booking_todo", "source_id": uuid.NewString(),
	}); rec.Code != http.StatusBadRequest {
		t.Fatalf("leg_key + source_kind = %d, want 400", rec.Code)
	}
}

// PATCH has no mechanism to move a line to another city — the same shape as
// TestPatchTripCannotSetOrigin. Which leg a plan belongs to is decided once, by
// the one writer, against the trip's real legs.
func TestPatchExpenseCannotSetLegKey(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "legkey-patch@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	seedTwoCityTrip(t, trip, owner.ID)
	path := "/api/v1/trips/" + trip.ID.String() + "/budget/expenses"

	created := decode(t, doJSON(t, "POST", path, token, map[string]any{
		"label": "Food & drink · Lisbon", "category": "food",
		"planned_amount": 200, "leg_key": "Lisbon",
	}))
	id := created["id"].(string)

	patched := decode(t, doJSON(t, "PATCH", path+"/"+id, token,
		map[string]any{"label": "Eating in Lisbon", "leg_key": "Porto"}))
	if patched["leg_key"] != "Lisbon" {
		t.Fatalf("PATCH moved the line to another city: %v", patched["leg_key"])
	}
	if patched["label"] != "Eating in Lisbon" {
		t.Fatalf("the rest of the PATCH should still apply: %v", patched)
	}

	// A plain expense stays plain — PATCH cannot give one a city either.
	plain := decode(t, doJSON(t, "POST", path, token,
		map[string]any{"label": "Souvenirs", "planned_amount": 20}))
	got := decode(t, doJSON(t, "PATCH", path+"/"+plain["id"].(string), token,
		map[string]any{"leg_key": "Lisbon"}))
	if got["leg_key"] != nil {
		t.Fatalf("PATCH gave a plain line a city: %v", got["leg_key"])
	}
}
