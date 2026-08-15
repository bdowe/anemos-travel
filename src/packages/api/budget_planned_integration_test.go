package main

// budget_planned_integration_test.go — the planned-vs-paid contract
// (migration 00066, specs/budget-planned-vs-paid). The compatibility half —
// a bare legacy `amount` still means money spent — lives in
// budget_integration_test.go, deliberately unchanged.

import (
	"context"
	"net/http"
	"testing"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// seedPlannedTrip returns an owner token, the trip id, and a budget target.
func seedPlannedTrip(t *testing.T, email string, target float64) (string, string) {
	t.Helper()
	owner, token := createTestUser(t, email)
	trip := createTestTrip(t, owner.ID, 0)
	tripID := trip.ID.String()
	doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/budget", token,
		map[string]any{"target_amount": target})
	return token, tripID
}

func TestPlannedOnlyExpense(t *testing.T) {
	resetDB(t)
	token, tripID := seedPlannedTrip(t, "owner@example.com", 2000)

	rec := doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses", token,
		map[string]any{"label": "Flights", "category": "flights", "planned_amount": 400})
	if rec.Code != http.StatusCreated {
		t.Fatalf("planned create = %d: %s", rec.Code, rec.Body.String())
	}
	created := decode(t, rec)
	if created["purchased"] != false || created["actual_amount"] != nil ||
		created["planned_amount"].(float64) != 400 {
		t.Fatalf("planned-only shape wrong: %v", created)
	}
	// The legacy alias must stay non-null — a cached bundle parses it as a
	// non-nullable double and a null takes the whole list down.
	if created["amount"].(float64) != 400 {
		t.Fatalf("legacy amount should mirror the plan: %v", created)
	}

	got := decode(t, doJSON(t, "GET", "/api/v1/trips/"+tripID+"/budget", token, nil))
	if got["planned"].(float64) != 400 || got["spent"].(float64) != 0 ||
		got["projected"].(float64) != 400 || got["remaining"].(float64) != 2000 {
		t.Fatalf("planned money must not count as spend: %v", got)
	}
	if got["plan_variance"] != nil {
		t.Fatalf("nothing paid yet ⇒ nothing to compare: %v", got)
	}
}

func TestPurchaseRecordsActualAndKeepsPlan(t *testing.T) {
	resetDB(t)
	token, tripID := seedPlannedTrip(t, "owner@example.com", 2000)
	rec := doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses", token,
		map[string]any{"label": "Flights", "category": "flights", "planned_amount": 400})
	id := decode(t, rec)["id"].(string)

	rec = doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses/"+id+"/purchase", token,
		map[string]any{"amount": 372})
	if rec.Code != http.StatusOK {
		t.Fatalf("purchase = %d: %s", rec.Code, rec.Body.String())
	}
	paid := decode(t, rec)
	if paid["purchased"] != true || paid["actual_amount"].(float64) != 372 ||
		paid["planned_amount"].(float64) != 400 || paid["amount"].(float64) != 372 {
		t.Fatalf("purchase should keep the plan: %v", paid)
	}

	got := decode(t, doJSON(t, "GET", "/api/v1/trips/"+tripID+"/budget", token, nil))
	if got["planned"].(float64) != 400 || got["spent"].(float64) != 372 ||
		got["projected"].(float64) != 372 {
		t.Fatalf("totals after purchase: %v", got)
	}
	if got["plan_variance"].(float64) != -28 {
		t.Fatalf("came in under plan ⇒ -28, got %v", got["plan_variance"])
	}

	// Idempotent: re-paying edits what it cost rather than growing anything.
	rec = doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses/"+id+"/purchase", token,
		map[string]any{"amount": 380})
	if again := decode(t, rec); again["actual_amount"].(float64) != 380 ||
		again["planned_amount"].(float64) != 400 {
		t.Fatalf("re-purchase: %v", again)
	}
}

func TestPurchaseWithoutAmountUsesThePlan(t *testing.T) {
	resetDB(t)
	token, tripID := seedPlannedTrip(t, "owner@example.com", 2000)
	rec := doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses", token,
		map[string]any{"label": "Museum pass", "planned_amount": 42})
	id := decode(t, rec)["id"].(string)

	// No body at all: "I paid exactly what I planned" — the one-tap case.
	rec = doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses/"+id+"/purchase", token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("bodyless purchase = %d: %s", rec.Code, rec.Body.String())
	}
	paid := decode(t, rec)
	if paid["actual_amount"].(float64) != 42 || paid["planned_amount"].(float64) != 42 {
		t.Fatalf("should pay the planned amount: %v", paid)
	}
	// Both numbers present and equal ⇒ a real comparison that happens to be 0.
	got := decode(t, doJSON(t, "GET", "/api/v1/trips/"+tripID+"/budget", token, nil))
	if got["plan_variance"] == nil || got["plan_variance"].(float64) != 0 {
		t.Fatalf("on-plan is 0, not absent: %v", got["plan_variance"])
	}
}

func TestPurchaseWithoutAmountOrPlanIs409(t *testing.T) {
	resetDB(t)
	token, tripID := seedPlannedTrip(t, "owner@example.com", 2000)
	rec := doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses", token,
		map[string]any{"label": "Taxi", "actual_amount": 30})
	id := decode(t, rec)["id"].(string)

	// Nothing to pay AT: no amount in the body and no plan on the row.
	rec = doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses/"+id+"/purchase", token, nil)
	if rec.Code != http.StatusConflict {
		t.Fatalf("plan-less bodyless purchase = %d, want 409: %s", rec.Code, rec.Body.String())
	}
	// An unknown id is a 404 even with a valid body — the two "no row" cases
	// are told apart, because only one of them is actionable.
	rec = doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses/"+uuid.NewString()+"/purchase",
		token, map[string]any{"amount": 5})
	if rec.Code != http.StatusNotFound {
		t.Fatalf("unknown id purchase = %d, want 404", rec.Code)
	}
	rec = doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses/"+id+"/purchase", token,
		map[string]any{"amount": -1})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("negative purchase = %d, want 400", rec.Code)
	}
}

func TestUnpurchaseRestoresPlanOnly(t *testing.T) {
	resetDB(t)
	token, tripID := seedPlannedTrip(t, "owner@example.com", 2000)
	rec := doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses", token,
		map[string]any{"label": "Flights", "planned_amount": 400})
	id := decode(t, rec)["id"].(string)
	doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses/"+id+"/purchase", token,
		map[string]any{"amount": 372})

	rec = doJSON(t, "DELETE", "/api/v1/trips/"+tripID+"/budget/expenses/"+id+"/purchase", token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("un-pay = %d: %s", rec.Code, rec.Body.String())
	}
	back := decode(t, rec)
	if back["purchased"] != false || back["actual_amount"] != nil ||
		back["planned_amount"].(float64) != 400 || back["amount"].(float64) != 400 {
		t.Fatalf("un-pay must keep the plan and restore the headline: %v", back)
	}

	// Idempotent: a second un-pay is a no-op, not an error.
	rec = doJSON(t, "DELETE", "/api/v1/trips/"+tripID+"/budget/expenses/"+id+"/purchase", token, nil)
	if rec.Code != http.StatusOK || decode(t, rec)["purchased"] != false {
		t.Fatalf("repeat un-pay = %d: %s", rec.Code, rec.Body.String())
	}

	// A line with no plan cannot be un-paid — that would leave it with no
	// money at all, and deleting it on the traveler's behalf is a guess.
	rec = doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses", token,
		map[string]any{"label": "Gelato", "actual_amount": 6})
	planless := decode(t, rec)["id"].(string)
	rec = doJSON(t, "DELETE", "/api/v1/trips/"+tripID+"/budget/expenses/"+planless+"/purchase", token, nil)
	if rec.Code != http.StatusConflict {
		t.Fatalf("plan-less un-pay = %d, want 409: %s", rec.Code, rec.Body.String())
	}
	rec = doJSON(t, "DELETE", "/api/v1/trips/"+tripID+"/budget/expenses/"+uuid.NewString()+"/purchase", token, nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("unknown id un-pay = %d, want 404", rec.Code)
	}
}

// TestPlannedTotalSurvivesFullPurchase is the acceptance test for the whole
// feature: at the end of a trip everything is bought, and the plan is STILL
// there to compare against. A status an expense merely leaves would report
// "planned 0".
func TestPlannedTotalSurvivesFullPurchase(t *testing.T) {
	resetDB(t)
	token, tripID := seedPlannedTrip(t, "owner@example.com", 2000)

	ids := map[string]string{}
	for _, line := range []struct {
		label   string
		planned float64
		paid    float64
	}{
		{"Flights", 400, 437},
		{"Hotel", 750, 750},
		{"Food", 350, 291},
	} {
		rec := doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses", token,
			map[string]any{"label": line.label, "planned_amount": line.planned})
		id := decode(t, rec)["id"].(string)
		ids[line.label] = id
		doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses/"+id+"/purchase", token,
			map[string]any{"amount": line.paid})
	}
	// Money spent that was never planned shows up as a GAP, not absorbed into
	// the plan — that is the whole reason planned_amount is nullable.
	doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses", token,
		map[string]any{"label": "Souvenirs", "actual_amount": 120})

	got := decode(t, doJSON(t, "GET", "/api/v1/trips/"+tripID+"/budget", token, nil))
	if got["planned"].(float64) != 1500 {
		t.Fatalf("planned must not shrink as lines are paid: %v", got["planned"])
	}
	if got["spent"].(float64) != 1598 || got["projected"].(float64) != 1598 {
		t.Fatalf("spent/projected after a finished trip: %v", got)
	}
	// Variance is scoped to the lines that carry BOTH numbers: +37 −59 +0.
	if got["plan_variance"].(float64) != -22 {
		t.Fatalf("plan_variance = %v, want -22", got["plan_variance"])
	}
}

func TestPlannedAmountCannotBeCleared(t *testing.T) {
	resetDB(t)
	token, tripID := seedPlannedTrip(t, "owner@example.com", 2000)
	rec := doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses", token,
		map[string]any{"label": "Flights", "planned_amount": 400, "actual_amount": 372})
	id := decode(t, rec)["id"].(string)

	// An explicit JSON null decodes to nil, which means "omitted" here — so
	// this is an empty patch, and the plan is untouched. "The plan survives"
	// is expressed as the absence of a mechanism.
	rec = doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/budget/expenses/"+id, token,
		map[string]any{"planned_amount": nil})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("null planned_amount = %d, want 400 (empty patch): %s", rec.Code, rec.Body.String())
	}
	list := decodeExpenses(t, doJSON(t, "GET", "/api/v1/trips/"+tripID+"/budget/expenses", token, nil))
	if list[0]["planned_amount"].(float64) != 400 {
		t.Fatalf("plan was erased: %v", list[0])
	}
}

// TestLegacyAmountPatchWritesTheColumnItWasReadFrom pins the stale-bundle path:
// an old edit dialog round-trips the number the traveler was looking at,
// instead of silently re-classifying the line.
func TestLegacyAmountPatchWritesTheColumnItWasReadFrom(t *testing.T) {
	resetDB(t)
	token, tripID := seedPlannedTrip(t, "owner@example.com", 2000)

	rec := doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses", token,
		map[string]any{"label": "Flights", "planned_amount": 400})
	unpaid := decode(t, rec)["id"].(string)
	rec = doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/budget/expenses/"+unpaid, token,
		map[string]any{"amount": 425})
	got := decode(t, rec)
	if got["planned_amount"].(float64) != 425 || got["actual_amount"] != nil || got["purchased"] != false {
		t.Fatalf("legacy patch on an unpaid row must move the plan: %v", got)
	}

	rec = doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses", token,
		map[string]any{"label": "Hotel", "planned_amount": 700, "actual_amount": 720})
	paid := decode(t, rec)["id"].(string)
	rec = doJSON(t, "PATCH", "/api/v1/trips/"+tripID+"/budget/expenses/"+paid, token,
		map[string]any{"amount": 730})
	got = decode(t, rec)
	if got["actual_amount"].(float64) != 730 || got["planned_amount"].(float64) != 700 {
		t.Fatalf("legacy patch on a paid row must move the payment: %v", got)
	}
}

// TestExpenseAmountColumnIsDerived pins the enforced boundary: `amount` has
// exactly one writer, the 00066 trigger. A hand-written value raises rather
// than being silently recomputed over — a discarded write is how a wrong
// mental model survives unlimited "successful" calls (docs/zen.md).
func TestExpenseAmountColumnIsDerived(t *testing.T) {
	resetDB(t)
	token, tripID := seedPlannedTrip(t, "owner@example.com", 2000)
	rec := doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses", token,
		map[string]any{"label": "Flights", "planned_amount": 400})
	id := decode(t, rec)["id"].(string)

	_, err := dbPool.Exec(context.Background(),
		`UPDATE trip_expenses SET amount = 9 WHERE id = $1`, uuid.MustParse(id))
	if err == nil {
		t.Fatal("writing the derived amount column should raise")
	}

	// And the row is untouched.
	list := decodeExpenses(t, doJSON(t, "GET", "/api/v1/trips/"+tripID+"/budget/expenses", token, nil))
	if list[0]["amount"].(float64) != 400 {
		t.Fatalf("amount was clobbered: %v", list[0])
	}
}

// TestListRowBudgetMatchesBudgetEndpoint is the parity contract for the third
// sum site — the lateral in query/trips.sql, which cannot share Go code with
// sumExpenses (docs/zen.md: write the twin fixtures that keep them honest).
// Without it, the trips-list pill and the Budget tab can report two different
// "spent" numbers for the same trip, with no error anywhere.
func TestListRowBudgetMatchesBudgetEndpoint(t *testing.T) {
	resetDB(t)
	token, tripID := seedPlannedTrip(t, "owner@example.com", 2000)

	// The three shapes: planned only, paid only, and both.
	for _, body := range []map[string]any{
		{"label": "Flights", "planned_amount": 400, "actual_amount": 372},
		{"label": "Hotel", "planned_amount": 750},
		{"label": "Gelato", "actual_amount": 6},
	} {
		if rec := doJSON(t, "POST", "/api/v1/trips/"+tripID+"/budget/expenses", token, body); rec.Code != http.StatusCreated {
			t.Fatalf("seed %v = %d: %s", body, rec.Code, rec.Body.String())
		}
	}

	budget := decode(t, doJSON(t, "GET", "/api/v1/trips/"+tripID+"/budget", token, nil))
	row := listTrips(t, "/api/v1/trips", token)[0]
	if row["budget_spent"].(float64) != budget["spent"].(float64) {
		t.Fatalf("list budget_spent %v != budget endpoint spent %v",
			row["budget_spent"], budget["spent"])
	}
	// Belt and braces: the shared number is the PAID one, not the projection.
	if budget["spent"].(float64) != 378 || budget["projected"].(float64) != 1128 {
		t.Fatalf("fixture drifted: %v", budget)
	}
}

// TestExpenseTotalsUnit covers the derivation directly, so a totals bug can be
// localized without a database.
func TestExpenseTotalsUnit(t *testing.T) {
	got := sumExpenses([]store.TripExpense{
		{PlannedAmount: ptrTo(400.0), ActualAmount: ptrTo(372.0)},
		{PlannedAmount: ptrTo(750.0)},
		{ActualAmount: ptrTo(6.0)},
		// Planned zero is real data — a free walking tour you budgeted at 0 —
		// and must not read as "never planned".
		{PlannedAmount: ptrTo(0.0), ActualAmount: ptrTo(12.0)},
	})
	if got.Planned != 1150 || got.Spent != 390 || got.Projected != 1140 {
		t.Fatalf("totals = %+v", got)
	}
	if got.Variance == nil || *got.Variance != -16 {
		t.Fatalf("variance = %v, want -16", got.Variance)
	}
	if empty := sumExpenses(nil); empty.Variance != nil {
		t.Fatalf("nothing to compare ⇒ nil variance, got %v", *empty.Variance)
	}
}
