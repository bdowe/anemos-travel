package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"
)

func decodeExpenses(t *testing.T, rec *httptest.ResponseRecorder) []map[string]any {
	t.Helper()
	var list []map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &list); err != nil {
		t.Fatalf("decode expenses %q: %v", rec.Body.String(), err)
	}
	return list
}

func TestBudgetUpsertAndDefaults(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	tripID := trip.ID.String()

	// A trip with no budget row yet reports defaults: no target, USD, 0 spent.
	rec := doJSON(t, "GET", "/api/v1/trips/"+tripID+"/budget", token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("initial get = %d: %s", rec.Code, rec.Body.String())
	}
	got := decode(t, rec)
	if got["currency"] != "USD" || got["target_amount"] != nil || got["spent"].(float64) != 0 || got["remaining"] != nil {
		t.Fatalf("default budget wrong: %v", got)
	}

	// Upsert a target; currency defaults to USD when omitted.
	rec = doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/budget", token, map[string]any{"target_amount": 2000})
	if rec.Code != http.StatusOK {
		t.Fatalf("put budget = %d: %s", rec.Code, rec.Body.String())
	}
	got = decode(t, rec)
	if got["currency"] != "USD" || got["target_amount"].(float64) != 2000 || got["remaining"].(float64) != 2000 {
		t.Fatalf("after set-target wrong: %v", got)
	}

	// Upsert again with a currency + a lower target overwrites (one row per trip).
	rec = doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/budget", token, map[string]any{"target_amount": 1500, "currency": "eur"})
	got = decode(t, rec)
	if got["currency"] != "EUR" || got["target_amount"].(float64) != 1500 {
		t.Fatalf("overwrite wrong: %v", got)
	}

	// Clearing the target (nil) is allowed; remaining goes nil.
	rec = doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/budget", token, map[string]any{"currency": "EUR"})
	got = decode(t, rec)
	if got["target_amount"] != nil || got["remaining"] != nil || got["currency"] != "EUR" {
		t.Fatalf("clear-target wrong: %v", got)
	}
}

func TestExpenseCRUDAndSpent(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	tripID := trip.ID.String()

	doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/budget", token, map[string]any{"target_amount": 1000})

	// Empty to start.
	rec := doJSON(t, "GET", "/api/v1/trips/"+tripID+"/budget/expenses", token, nil)
	if rec.Code != http.StatusOK || len(decodeExpenses(t, rec)) != 0 {
		t.Fatalf("initial expenses = %d: %s", rec.Code, rec.Body.String())
	}

	// Create (category defaults to general when omitted).
	rec = doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses", token, map[string]any{"label": "Hotel", "category": "lodging", "amount": 300})
	if rec.Code != http.StatusCreated {
		t.Fatalf("create = %d: %s", rec.Code, rec.Body.String())
	}
	created := decode(t, rec)
	expenseID := created["id"].(string)
	if created["category"] != "lodging" || created["label"] != "Hotel" ||
		created["amount"].(float64) != 300 || created["auto"] != false {
		t.Fatalf("created expense wrong: %v", created)
	}

	rec = doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses", token, map[string]any{"label": "Snacks", "amount": 20})
	if rec.Code != http.StatusCreated || decode(t, rec)["category"] != "general" {
		t.Fatalf("default category = %d: %s", rec.Code, rec.Body.String())
	}

	// spent (300+20) reflected on the budget; remaining = 1000-320.
	rec = doJSON(t, "GET", "/api/v1/trips/"+tripID+"/budget", token, nil)
	got := decode(t, rec)
	if got["spent"].(float64) != 320 || got["remaining"].(float64) != 680 {
		t.Fatalf("spent/remaining wrong: %v", got)
	}

	// List shows both.
	rec = doJSON(t, "GET", "/api/v1/trips/"+tripID+"/budget/expenses", token, nil)
	if len(decodeExpenses(t, rec)) != 2 {
		t.Fatalf("list len wrong: %s", rec.Body.String())
	}

	// Partial patch: change amount + recategorize, label untouched.
	rec = doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/budget/expenses/"+expenseID, token, map[string]any{"amount": 250, "category": "food"})
	got = decode(t, rec)
	if got["amount"].(float64) != 250 || got["category"] != "food" || got["label"] != "Hotel" {
		t.Fatalf("patch clobbered/failed: %v", got)
	}

	// Delete, idempotent 404 on re-delete.
	rec = doJSON(t, "DELETE", "/api/v1/trips/"+tripID+"/budget/expenses/"+expenseID, token, nil)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("delete = %d: %s", rec.Code, rec.Body.String())
	}
	rec = doJSON(t, "DELETE", "/api/v1/trips/"+tripID+"/budget/expenses/"+expenseID, token, nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("re-delete = %d, want 404", rec.Code)
	}
	rec = doJSON(t, "GET", "/api/v1/trips/"+tripID+"/budget/expenses", token, nil)
	if len(decodeExpenses(t, rec)) != 1 {
		t.Fatalf("list after delete = %s", rec.Body.String())
	}
}

func TestBudgetValidation(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	tripID := trip.ID.String()

	rec := doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses", token, map[string]any{"label": "seed", "amount": 10})
	expenseID := decode(t, rec)["id"].(string)

	cases := []struct {
		name   string
		method string
		path   string
		body   map[string]any
		want   int
	}{
		{"budget negative target", "PUT", "/budget", map[string]any{"target_amount": -5}, http.StatusBadRequest},
		{"budget bad currency", "PUT", "/budget", map[string]any{"currency": "dollars"}, http.StatusBadRequest},
		{"missing label", "POST", "/budget/expenses", map[string]any{"category": "food", "amount": 5}, http.StatusBadRequest},
		{"blank label", "POST", "/budget/expenses", map[string]any{"label": "  ", "amount": 5}, http.StatusBadRequest},
		{"negative amount", "POST", "/budget/expenses", map[string]any{"label": "x", "amount": -1}, http.StatusBadRequest},
		{"bad category", "POST", "/budget/expenses", map[string]any{"label": "x", "amount": 5, "category": "bribes"}, http.StatusBadRequest},
		{"empty patch", "PATCH", "/budget/expenses/" + expenseID, map[string]any{}, http.StatusBadRequest},
		{"patch blank label", "PATCH", "/budget/expenses/" + expenseID, map[string]any{"label": " "}, http.StatusBadRequest},
		{"patch negative amount", "PATCH", "/budget/expenses/" + expenseID, map[string]any{"amount": -3}, http.StatusBadRequest},
		{"patch bad category", "PATCH", "/budget/expenses/" + expenseID, map[string]any{"category": "misc"}, http.StatusBadRequest},
		{"patch unknown id", "PATCH", "/budget/expenses/" + uuid.NewString(), map[string]any{"amount": 5}, http.StatusNotFound},
	}
	for _, tc := range cases {
		rec := doJSON(t, tc.method, "/api/v1/trips/"+tripID+tc.path, token, tc.body)
		if rec.Code != tc.want {
			t.Fatalf("%s = %d, want %d: %s", tc.name, rec.Code, tc.want, rec.Body.String())
		}
	}
}

func TestBudgetOwnershipAndAccess(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	tripID := trip.ID.String()
	rec := doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses", token, map[string]any{"label": "Hotel", "amount": 100})
	expenseID := decode(t, rec)["id"].(string)

	// A stranger (no share) is 404 on every route.
	_, strangerToken := createTestUser(t, "stranger@example.com")
	for _, m := range []struct {
		method, path string
		body         map[string]any
	}{
		{"GET", "/budget", nil},
		{"PUT", "/budget", map[string]any{"target_amount": 1}},
		{"GET", "/budget/expenses", nil},
		{"POST", "/budget/expenses", map[string]any{"label": "sneak", "amount": 1}},
		{"PATCH", "/budget/expenses/" + expenseID, map[string]any{"amount": 1}},
		{"DELETE", "/budget/expenses/" + expenseID, nil},
	} {
		if rec := doJSON(t, m.method, "/api/v1/trips/"+tripID+m.path, strangerToken, m.body); rec.Code != http.StatusNotFound {
			t.Fatalf("stranger %s %s = %d, want 404", m.method, m.path, rec.Code)
		}
	}

	// A viewer-collaborator can read (viewableTrip on the GETs) but not
	// mutate (editableTrip => 404).
	_, viewerToken := createTestUser(t, "viewer@example.com")
	shareToken := createShare(t, token, tripID, "viewer")
	if rec := joinShare(t, viewerToken, shareToken); rec.Code != http.StatusOK {
		t.Fatalf("viewer join = %d: %s", rec.Code, rec.Body.String())
	}
	rec = doJSON(t, "GET", "/api/v1/trips/"+tripID+"/budget", viewerToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("viewer get budget = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	if spent := decode(t, rec)["spent"].(float64); spent != 100 {
		t.Fatalf("viewer get budget spent = %v, want 100", spent)
	}
	if rec := doJSON(t, "GET", "/api/v1/trips/"+tripID+"/budget/expenses", viewerToken, nil); rec.Code != http.StatusOK {
		t.Fatalf("viewer list expenses = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	for _, m := range []struct {
		method, path string
		body         map[string]any
	}{
		{"PUT", "/budget", map[string]any{"target_amount": 1}},
		{"POST", "/budget/expenses", map[string]any{"label": "sneak", "amount": 1}},
		{"PATCH", "/budget/expenses/" + expenseID, map[string]any{"amount": 5}},
		{"DELETE", "/budget/expenses/" + expenseID, nil},
	} {
		if rec := doJSON(t, m.method, "/api/v1/trips/"+tripID+m.path, viewerToken, m.body); rec.Code != http.StatusNotFound {
			t.Fatalf("viewer %s %s = %d, want 404", m.method, m.path, rec.Code)
		}
	}

	// An editor-collaborator can mutate.
	_, editorToken := createTestUser(t, "editor@example.com")
	editShare := createShare(t, token, tripID, "editor")
	if rec := joinShare(t, editorToken, editShare); rec.Code != http.StatusOK {
		t.Fatalf("editor join = %d: %s", rec.Code, rec.Body.String())
	}
	if rec := doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/budget/expenses/"+expenseID, editorToken, map[string]any{"amount": 5}); rec.Code != http.StatusOK {
		t.Fatalf("editor patch = %d, want 200: %s", rec.Code, rec.Body.String())
	}

	// Anonymous is 401.
	if rec := doJSON(t, "GET", "/api/v1/trips/"+tripID+"/budget", "", nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous get = %d, want 401", rec.Code)
	}
}

func TestBudgetCascadeOnTripDelete(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "owner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	tripID := trip.ID.String()
	doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/budget", token, map[string]any{"target_amount": 500})
	doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses", token, map[string]any{"label": "Flight", "category": "flights", "amount": 200})

	if rec := doJSON(t, "DELETE", "/api/v1/trips/"+tripID, token, nil); rec.Code != http.StatusNoContent && rec.Code != http.StatusOK {
		t.Fatalf("delete trip = %d: %s", rec.Code, rec.Body.String())
	}
	var nb, ne int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM trip_budgets WHERE trip_id = $1`, trip.ID).Scan(&nb); err != nil {
		t.Fatalf("count budget: %v", err)
	}
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM trip_expenses WHERE trip_id = $1`, trip.ID).Scan(&ne); err != nil {
		t.Fatalf("count expenses: %v", err)
	}
	if nb != 0 || ne != 0 {
		t.Fatalf("budget/expense rows survived trip delete: budget=%d expenses=%d", nb, ne)
	}
}
