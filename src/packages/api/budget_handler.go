package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/google/uuid"
	"github.com/gorilla/mux"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// budget_handler.go — the per-trip budget & expense tracker. Mirrors
// checklist_handler.go conventions: the same validation/404 shape, TouchTrip
// on mutation. Gates are split by verb — the two GETs use viewableTrip (any
// active collaborator, viewers included, may read the budget) while every
// mutation stays behind editableTrip (owner or active editor-collaborator).
//
// Honest v1 model: ONE budget per trip (a single target_amount + one currency,
// default USD — there is no trip-level currency to inherit) plus a flat list of
// manual expense line-items. Category is a per-expense tag from the bounded set
// below, used only for client-side subtotals — there are NO per-category
// targets and NO cross-currency summing (every expense is assumed to be in the
// budget's currency; no FX). The GET endpoints hand the client the budget
// target/currency and the raw expense list so it can group and subtotal;
// the totals on BudgetResponse are a server-side convenience derived by
// sumExpenses.
//
// PLANNED vs PAID (migration 00067, specs/budget-planned-vs-paid). An expense
// carries up to two numbers — planned_amount (what the traveler meant to
// spend) and actual_amount (what it cost) — and at least one is always
// present. "Paid" is not stored: it is actual_amount != nil, behind the single
// predicate expensePurchased(). The plan SURVIVES the purchase — that is the
// whole feature, since at the end of a trip everything is bought — so no
// endpoint here can clear planned_amount; delete the line instead. The legacy
// wire field `amount` is the trigger-maintained COALESCE(actual, planned)
// column, served verbatim and never null, because a cached Flutter bundle
// parses it as a non-nullable double.

// allowedExpenseCategories bounds the free-text category to a known travel set
// so a stray value can't fragment the client's grouping. "general" is the
// default catch-all.
var allowedExpenseCategories = map[string]bool{
	"flights":    true,
	"lodging":    true,
	"food":       true,
	"activities": true,
	"transport":  true,
	"shopping":   true,
	"general":    true,
}

// expenseCategoryList is the human-readable form used in error messages. Kept
// in sync with allowedExpenseCategories.
const expenseCategoryList = "flights, lodging, food, activities, transport, shopping, general"

// allowedExpenseSourceKinds bounds the booking-row kinds an expense may link
// to (budget autopopulate, migration 00061). The link is a snapshot, not an
// FK — see the migration comment for the full `auto` contract: auto=true
// means system-managed mirror of the source row's booked state (unbook
// deletes it); any user edit of category/label/amount flips auto=false
// (manual takeover — unbook then leaves the row). `auto` is never
// client-writable: the server sets it true iff a source link is present.
var allowedExpenseSourceKinds = map[string]bool{
	"booking_todo":  true,
	"accommodation": true,
	"segment":       true,
}

// BudgetResponse carries the single per-trip budget and its totals.
//
// Spent/Remaining keep their EXACT pre-00067 meaning — money actually spent,
// and target minus that. Unchanged on purpose: checkBudget's over-budget
// finding, the trips-list hero pill, the print packet and every shipped client
// read those two words, and silently redefining a live field is the drift this
// repo keeps paying for. The new numbers get new names.
type BudgetResponse struct {
	TargetAmount *float64 `json:"target_amount"`
	Currency     string   `json:"currency"`
	Spent        float64  `json:"spent"`     // sum(actual_amount)
	Remaining    *float64 `json:"remaining"` // target - spent; nil with no target
	// Planned is the sum of every stated plan. It does NOT shrink as lines are
	// paid — that is the whole feature: at the end of the trip everything is
	// bought and this number is still the plan. Lines with no plan (unplanned
	// purchases) contribute nothing, so planned vs spent shows unplanned spend
	// as a gap rather than absorbing it.
	Planned float64 `json:"planned"`
	// Projected is sum(coalesce(actual, planned)) — what this trip costs if
	// every unpaid line lands at its plan. Equals Spent once everything is
	// paid.
	Projected float64 `json:"projected"`
	// PlanVariance is how the PAID lines came in against their own plans
	// (positive = over). Scoped to lines that carry BOTH numbers, because
	// planned-minus-spent mid-trip is "money not yet spent" plus variance —
	// two different claims in one number. Nil when no line has both yet:
	// nothing to compare is not the same as zero.
	PlanVariance *float64 `json:"plan_variance"`
}

type ExpenseResponse struct {
	ID       string `json:"id"`
	Category string `json:"category"`
	Label    string `json:"label"`
	// Amount is the LEGACY headline figure, served straight from the
	// trigger-maintained trip_expenses.amount column (00067) — never
	// re-derived here. Always present, never null: a cached Flutter bundle
	// does `(json['amount'] as num).toDouble()` in models/expense.dart and a
	// null takes the entire budget list down with it.
	Amount float64 `json:"amount"`
	// The two truths. Either may be null; never both
	// (trip_expenses_amount_present).
	PlannedAmount *float64 `json:"planned_amount"`
	ActualAmount  *float64 `json:"actual_amount"`
	// Purchased is expensePurchased(), STATED rather than left for each client
	// to re-derive from the nullness. Same call as `chosen` riding
	// BookingOptionResponse.
	Purchased bool `json:"purchased"`
	Position  int  `json:"position"`
	Auto      bool `json:"auto"`
	// The booking-row link this expense was autopopulated from (nil for
	// manual entries). The client needs both to dedupe the booked-flip
	// prompt and to find the row to remove on unbook.
	SourceKind *string `json:"source_kind"`
	SourceID   *string `json:"source_id"`
	// LegKey is the city leg this line plans for (00070), nil for every other
	// expense. It rides the wire so the daily-spend card can find ITS OWN line
	// by identity instead of by matching the label it generated — the label
	// being the key is what 00064 was written to undo.
	LegKey *string `json:"leg_key"`
}

func toExpenseResponse(e store.TripExpense) ExpenseResponse {
	resp := ExpenseResponse{
		ID:            e.ID.String(),
		Category:      e.Category,
		Label:         e.Label,
		Amount:        e.Amount,
		PlannedAmount: e.PlannedAmount,
		ActualAmount:  e.ActualAmount,
		Purchased:     expensePurchased(e),
		Position:      int(e.Position),
		Auto:          e.Auto,
		SourceKind:    e.SourceKind,
		LegKey:        e.LegKey,
	}
	if e.SourceID.Valid {
		id := uuid.UUID(e.SourceID.Bytes).String()
		resp.SourceID = &id
	}
	return resp
}

// normalizeExpenseCategory trims and lower-cases the category, defaulting to
// "general" when empty and rejecting unknown values.
func normalizeExpenseCategory(raw string) (string, bool) {
	c := strings.ToLower(strings.TrimSpace(raw))
	if c == "" {
		return "general", true
	}
	if !allowedExpenseCategories[c] {
		return "", false
	}
	return c, true
}

// expensePurchased is the ONE definition of "this line has been paid" (00067).
// The fact IS the nullness of the money column — mirroring optionChosen, and
// for the same reason: a second representation of one fact is a drift vector.
func expensePurchased(e store.TripExpense) bool { return e.ActualAmount != nil }

// expenseTotals is a trip's budget arithmetic. Every number here is derived in
// exactly one place, sumExpenses (docs/zen.md: second implementation of
// anything? consume the first) — buildBudgetResponse and buildPrintBudget both
// call it. The third sum site, the lateral in query/trips.sql, cannot share Go
// code and is held honest by TestListRowBudgetMatchesBudgetEndpoint instead.
type expenseTotals struct {
	Planned   float64
	Spent     float64
	Projected float64
	// Variance is nil when no line carries both a plan and a payment.
	Variance *float64
}

func sumExpenses(expenses []store.TripExpense) expenseTotals {
	var t expenseTotals
	var variance float64
	compared := false
	for _, e := range expenses {
		if e.PlannedAmount != nil {
			t.Planned += *e.PlannedAmount
		}
		switch {
		case e.ActualAmount != nil:
			t.Spent += *e.ActualAmount
			t.Projected += *e.ActualAmount
			if e.PlannedAmount != nil {
				variance += *e.ActualAmount - *e.PlannedAmount
				compared = true
			}
		case e.PlannedAmount != nil:
			t.Projected += *e.PlannedAmount
		}
	}
	if compared {
		t.Variance = &variance
	}
	return t
}

// buildBudgetResponse computes the totals from the expense list and the
// (possibly nil) target. A trip with no budget row yet reports the defaults:
// no target, USD currency.
func buildBudgetResponse(b *store.TripBudget, expenses []store.TripExpense) BudgetResponse {
	t := sumExpenses(expenses)
	resp := BudgetResponse{
		Currency:     "USD",
		Spent:        t.Spent,
		Planned:      t.Planned,
		Projected:    t.Projected,
		PlanVariance: t.Variance,
	}
	if b != nil {
		resp.Currency = b.Currency
		resp.TargetAmount = b.TargetAmount
		if b.TargetAmount != nil {
			rem := *b.TargetAmount - t.Spent
			resp.Remaining = &rem
		}
	}
	return resp
}

func getBudgetHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := viewableTrip(w, r)
	if !ok {
		return
	}
	q := store.New(dbPool)
	var budget *store.TripBudget
	if b, err := q.GetBudgetByTrip(r.Context(), trip.ID); err == nil {
		budget = &b
	}
	expenses, err := q.ListExpensesByTrip(r.Context(), trip.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load budget")
		return
	}
	writeJSON(w, http.StatusOK, buildBudgetResponse(budget, expenses))
}

// PutBudgetRequest upserts the single per-trip target + currency. A nil
// target_amount clears the target (budget with no ceiling); currency defaults to
// USD when omitted.
type PutBudgetRequest struct {
	TargetAmount *float64 `json:"target_amount"`
	Currency     string   `json:"currency"`
}

func putBudgetHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	var req PutBudgetRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if req.TargetAmount != nil && *req.TargetAmount < 0 {
		writeJSONError(w, http.StatusBadRequest, "target_amount cannot be negative")
		return
	}
	currency := strings.ToUpper(strings.TrimSpace(req.Currency))
	if currency == "" {
		currency = "USD"
	}
	if len(currency) != 3 {
		writeJSONError(w, http.StatusBadRequest, "currency must be a 3-letter code (e.g. USD)")
		return
	}

	q := store.New(dbPool)
	budget, err := q.UpsertBudget(r.Context(), store.UpsertBudgetParams{
		TripID:       trip.ID,
		TargetAmount: req.TargetAmount,
		Currency:     currency,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not save budget")
		return
	}
	_ = q.TouchTrip(r.Context(), touchedBy(trip.ID, r))

	expenses, err := q.ListExpensesByTrip(r.Context(), trip.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load budget")
		return
	}
	writeJSON(w, http.StatusOK, buildBudgetResponse(&budget, expenses))
}

func listExpensesHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := viewableTrip(w, r)
	if !ok {
		return
	}
	writeExpenses(w, r, trip.ID)
}

type AddExpenseRequest struct {
	Category string `json:"category"`
	Label    string `json:"label"`
	// Amount is the LEGACY field, now a pointer so absence is detectable.
	// Given alone it means a PAYMENT of that amount — today's meaning, since
	// the UI labels the total "Total spent" — so a cached bundle's add-expense
	// row keeps working byte-identically. Ignored when either explicit field
	// is present; 400 when all three are absent.
	Amount        *float64 `json:"amount"`
	PlannedAmount *float64 `json:"planned_amount"`
	ActualAmount  *float64 `json:"actual_amount"`
	// Optional booking-row link (both or neither): makes the POST an
	// upsert-by-source and marks the row auto (see the migration 00061
	// contract). Plain manual adds omit them, byte-identical to before.
	SourceKind *string `json:"source_kind"`
	SourceID   *string `json:"source_id"`
	// LegKey binds this line to ONE city leg of the trip (00070) — the daily
	// food & drink guide's "add to plan". It makes the POST an
	// upsert-by-leg so a double tap returns the existing plan instead of
	// filing a second one. Unlike SourceKind it does NOT mark the row auto:
	// this is the traveler's own plan, not a mirror of a booking.
	LegKey *string `json:"leg_key"`
}

// resolveAddAmounts maps the request's three money fields onto the two columns.
// Legacy `amount` alone is a payment; explicit fields win over it.
func (req AddExpenseRequest) resolveAddAmounts() (planned, actual *float64) {
	planned, actual = req.PlannedAmount, req.ActualAmount
	if planned == nil && actual == nil {
		actual = req.Amount
	}
	return planned, actual
}

func addExpenseHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	var req AddExpenseRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	label := strings.TrimSpace(req.Label)
	if label == "" {
		writeJSONError(w, http.StatusBadRequest, "label is required")
		return
	}
	if _, err := boundedString("label", label, maxNameLen); err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	planned, actual := req.resolveAddAmounts()
	if planned == nil && actual == nil {
		writeJSONError(w, http.StatusBadRequest,
			"pass planned_amount, actual_amount, or amount")
		return
	}
	if (planned != nil && *planned < 0) || (actual != nil && *actual < 0) {
		writeJSONError(w, http.StatusBadRequest, "amount cannot be negative")
		return
	}
	category, valid := normalizeExpenseCategory(req.Category)
	if !valid {
		writeJSONError(w, http.StatusBadRequest, "category must be one of: "+expenseCategoryList)
		return
	}
	if (req.SourceKind == nil) != (req.SourceID == nil) {
		writeJSONError(w, http.StatusBadRequest, "source_kind and source_id must be passed together")
		return
	}
	// A linked expense mirrors a booking that just went booked, so it records a
	// payment by definition. Refuse a plan-only linked add rather than guessing
	// which column the caller meant.
	if req.SourceKind != nil && actual == nil {
		writeJSONError(w, http.StatusBadRequest,
			"a linked expense records a payment; pass actual_amount")
		return
	}
	var sourceID pgtype.UUID
	if req.SourceKind != nil {
		if !allowedExpenseSourceKinds[*req.SourceKind] {
			writeJSONError(w, http.StatusBadRequest, "source_kind must be one of: booking_todo, accommodation, segment")
			return
		}
		parsed, err := uuid.Parse(*req.SourceID)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, "source_id must be a UUID")
			return
		}
		sourceID = pgtype.UUID{Bytes: parsed, Valid: true}
	}

	q := store.New(dbPool)

	// A city plan and a booking mirror are different things with different
	// owners (00070 vs 00061), and a row that was both would have two rules for
	// what unbooking does to it. Refuse rather than pick one.
	if req.LegKey != nil && req.SourceKind != nil {
		writeJSONError(w, http.StatusBadRequest, "leg_key and source_kind cannot be combined")
		return
	}
	var legKey *string
	if req.LegKey != nil {
		key := strings.TrimSpace(*req.LegKey)
		if key == "" {
			writeJSONError(w, http.StatusBadRequest, "leg_key cannot be empty")
			return
		}
		// The leg has to be one the trip actually renders. This is the 00064
		// rule: the server decides which row a city maps to, so a stale tab, an
		// old cached bundle and a collaborator's device all land on the SAME
		// line instead of each minting an orphan under its own spelling of the
		// trip.
		known, err := tripLegKeyExists(r.Context(), q, trip, key)
		if err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not save expense")
			return
		}
		if !known {
			writeJSONError(w, http.StatusBadRequest, "leg_key is not a city on this trip")
			return
		}
		legKey = &key
	}

	expense, outcome, err := upsertLinkedExpense(r.Context(), q, linkedExpense{
		TripID:        trip.ID,
		Category:      category,
		Label:         label,
		PlannedAmount: planned,
		ActualAmount:  actual,
		SourceKind:    req.SourceKind,
		SourceID:      sourceID,
		LegKey:        legKey,
	})
	if err != nil {
		if errors.Is(err, errExpenseLimitReached) {
			writeJSONError(w, http.StatusUnprocessableEntity,
				fmt.Sprintf("expense limit reached (max %d) — remove one first", maxExpensesPerTrip()))
			return
		}
		writeJSONError(w, http.StatusInternalServerError, "could not save expense")
		return
	}
	switch outcome {
	case expenseUntouched:
		// A manual takeover, or the loser of a concurrent linked POST. Nothing
		// changed, so nothing is touched.
		writeJSON(w, http.StatusOK, toExpenseResponse(expense))
		return
	case expenseRefreshed:
		_ = q.TouchTrip(r.Context(), touchedBy(trip.ID, r))
		writeJSON(w, http.StatusOK, toExpenseResponse(expense))
		return
	}
	_ = q.TouchTrip(r.Context(), touchedBy(trip.ID, r))
	if user, ok := userFromContext(r.Context()); ok {
		meta := map[string]any{"category": category, "auto": expense.Auto}
		if req.SourceKind != nil {
			meta["source_kind"] = *req.SourceKind
		}
		safeGo("recordEvent", func() {
			recordEvent(user.ID, "expense_added", &trip.ID, meta)
		})
	}
	writeJSON(w, http.StatusCreated, toExpenseResponse(expense))
}

// PatchExpenseRequest is a partial update: recategorize, relabel, restate the
// plan, reposition.
//
// Note what is deliberately NOT here:
//
//   - actual_amount. Paying has its own verb pair, POST/DELETE
//     .../{expenseId}/purchase. One obvious way to record what something cost.
//   - any way to CLEAR planned_amount. JSON null decodes to nil, which means
//     "omitted, leave it" like every other field here. That is the design, not
//     an oversight: "the plan survives the purchase" is the feature, so the API
//     offers no way to erase a plan. Delete the line if you want it gone.
type PatchExpenseRequest struct {
	Category      *string  `json:"category"`
	Label         *string  `json:"label"`
	PlannedAmount *float64 `json:"planned_amount"`
	// Amount is the LEGACY alias. It writes back to whichever column the wire's
	// `amount` was READ from — actual_amount on a paid row, planned_amount
	// otherwise (resolved in SQL, see UpdateExpense) — so an old bundle's edit
	// dialog round-trips the number the user was looking at instead of silently
	// re-classifying the line.
	Amount   *float64 `json:"amount"`
	Position *int     `json:"position"`
}

func patchExpenseHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	expenseID, err := uuid.Parse(mux.Vars(r)["expenseId"])
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "expense not found")
		return
	}
	var req PatchExpenseRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if req.Category == nil && req.Label == nil && req.Amount == nil &&
		req.PlannedAmount == nil && req.Position == nil {
		writeJSONError(w, http.StatusBadRequest,
			"pass at least one field to change (category, label, planned_amount, amount, or position)")
		return
	}
	// Two writers for one column: `amount` resolves to planned_amount on an
	// unpaid row, which planned_amount also targets. Refuse rather than pick.
	if req.Amount != nil && req.PlannedAmount != nil {
		writeJSONError(w, http.StatusBadRequest, "pass planned_amount or amount, not both")
		return
	}

	params := store.UpdateExpenseParams{ID: expenseID, TripID: trip.ID}
	if req.Category != nil {
		category, valid := normalizeExpenseCategory(*req.Category)
		if !valid {
			writeJSONError(w, http.StatusBadRequest, "category must be one of: "+expenseCategoryList)
			return
		}
		params.Category = &category
	}
	if req.Label != nil {
		l := strings.TrimSpace(*req.Label)
		if l == "" {
			writeJSONError(w, http.StatusBadRequest, "label cannot be empty")
			return
		}
		if _, err := boundedString("label", l, maxNameLen); err != nil {
			writeJSONError(w, http.StatusBadRequest, err.Error())
			return
		}
		params.Label = &l
	}
	if req.Amount != nil {
		if *req.Amount < 0 {
			writeJSONError(w, http.StatusBadRequest, "amount cannot be negative")
			return
		}
		params.LegacyAmount = req.Amount
	}
	if req.PlannedAmount != nil {
		if *req.PlannedAmount < 0 {
			writeJSONError(w, http.StatusBadRequest, "amount cannot be negative")
			return
		}
		params.PlannedAmount = req.PlannedAmount
	}
	if req.Position != nil {
		p := int32(*req.Position)
		params.Position = &p
	}
	// Server rule (never a request field): editing the CONTENT of an
	// auto-created expense is a manual takeover — the row stops mirroring
	// its booking's booked state (unbook then leaves it; see the 00061
	// contract). Reordering isn't ownership, so a position-only PATCH
	// leaves auto alone.
	//
	// Since 00067 the ownership of an auto row is SPLIT: the system owns
	// category, label and actual_amount (they mirror the booking), the
	// traveler owns planned_amount on every row — a plan is never
	// system-generated and never system-clobbered. So writing in the field you
	// own is not a takeover: a planned_amount-only PATCH leaves auto alone,
	// which is also what stops unbook from stranding a stale payment.
	if req.Category != nil || req.Label != nil || req.Amount != nil {
		autoFalse := false
		params.Auto = &autoFalse
	}

	q := store.New(dbPool)
	expense, err := q.UpdateExpense(r.Context(), params)
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "expense not found")
		return
	}
	_ = q.TouchTrip(r.Context(), touchedBy(trip.ID, r))
	writeJSON(w, http.StatusOK, toExpenseResponse(expense))
}

// --- the purchase verb pair (00067) ----------------------------------------
//
// POST/DELETE /trips/{id}/budget/expenses/{expenseId}/purchase, mirroring
// booking-options/{optionId}/choose. A verb pair rather than a nullable PATCH
// field because only ONE column is ever cleared, and a null-means-clear JSON
// convention is unfalsifiable by inspection: an old client that serializes
// absent fields as null would silently un-pay everything it touched. A verb
// cannot fire by accident.
//
// Both answer a plain ExpenseResponse: budget_provider.dart invalidates the
// budget and the expense list after every mutation, so an envelope would buy
// nothing and would make these the only differently-shaped calls in the
// feature. The response still states the post-state of the thing that changed
// (both amounts, purchased, auto).

// PurchaseExpenseRequest is the body of POST .../purchase.
type PurchaseExpenseRequest struct {
	// Amount is what it actually cost. Omitted (or an empty body) means "paid
	// the planned amount"; 409 when the line has no plan to fall back on.
	Amount *float64 `json:"amount"`
}

func purchaseExpenseHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	expenseID, err := uuid.Parse(mux.Vars(r)["expenseId"])
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "expense not found")
		return
	}
	var req PurchaseExpenseRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil && !errors.Is(err, io.EOF) {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if req.Amount != nil && *req.Amount < 0 {
		writeJSONError(w, http.StatusBadRequest, "amount cannot be negative")
		return
	}

	q := store.New(dbPool)
	expense, err := q.PurchaseExpense(r.Context(), store.PurchaseExpenseParams{
		ID: expenseID, TripID: trip.ID, ActualAmount: req.Amount,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			// No row can mean two very different things, and the traveler can
			// act on only one of them — so say which.
			if _, missing := q.GetExpense(r.Context(),
				store.GetExpenseParams{ID: expenseID, TripID: trip.ID}); missing != nil {
				writeJSONError(w, http.StatusNotFound, "expense not found")
				return
			}
			writeJSONError(w, http.StatusConflict,
				"pass an amount: this expense has no planned amount to pay at")
			return
		}
		writeJSONError(w, http.StatusInternalServerError, "could not save expense")
		return
	}
	_ = q.TouchTrip(r.Context(), touchedBy(trip.ID, r))
	writeJSON(w, http.StatusOK, toExpenseResponse(expense))
}

func unpurchaseExpenseHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	expenseID, err := uuid.Parse(mux.Vars(r)["expenseId"])
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "expense not found")
		return
	}

	q := store.New(dbPool)
	expense, err := q.UnpurchaseExpense(r.Context(),
		store.UnpurchaseExpenseParams{ID: expenseID, TripID: trip.ID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			existing, missing := q.GetExpense(r.Context(),
				store.GetExpenseParams{ID: expenseID, TripID: trip.ID})
			switch {
			case missing != nil:
				writeJSONError(w, http.StatusNotFound, "expense not found")
			case !expensePurchased(existing):
				// Only reachable when a concurrent write un-paid it first
				// (a plan-less row is always paid — trip_expenses_amount_present).
				// The caller's intent already holds, so report success.
				writeJSON(w, http.StatusOK, toExpenseResponse(existing))
			default:
				writeJSONError(w, http.StatusConflict,
					"this expense has no planned amount — delete it instead of un-paying it")
			}
			return
		}
		writeJSONError(w, http.StatusInternalServerError, "could not save expense")
		return
	}
	_ = q.TouchTrip(r.Context(), touchedBy(trip.ID, r))
	writeJSON(w, http.StatusOK, toExpenseResponse(expense))
}

func deleteExpenseHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	expenseID, err := uuid.Parse(mux.Vars(r)["expenseId"])
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "expense not found")
		return
	}
	q := store.New(dbPool)
	rows, err := q.DeleteExpense(r.Context(),
		store.DeleteExpenseParams{ID: expenseID, TripID: trip.ID})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not delete expense")
		return
	}
	if rows == 0 {
		writeJSONError(w, http.StatusNotFound, "expense not found")
		return
	}
	_ = q.TouchTrip(r.Context(), touchedBy(trip.ID, r))
	w.WriteHeader(http.StatusNoContent)
}

func writeExpenses(w http.ResponseWriter, r *http.Request, tripID uuid.UUID) {
	expenses, err := store.New(dbPool).ListExpensesByTrip(r.Context(), tripID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load expenses")
		return
	}
	resp := make([]ExpenseResponse, 0, len(expenses))
	for _, e := range expenses {
		resp = append(resp, toExpenseResponse(e))
	}
	writeJSON(w, http.StatusOK, resp)
}

// --- linked-expense upsert (shared) -----------------------------------------

// expenseOutcome names what upsertLinkedExpense actually did, because the
// callers must treat the three cases differently: only a create is a 201 and
// only a create/refresh has anything to touch. A bare bool would collapse
// "refreshed the price" and "left a manual takeover alone" into one answer.
type expenseOutcome int

const (
	expenseCreated expenseOutcome = iota
	expenseRefreshed
	expenseUntouched
)

// errExpenseLimitReached lets the caller map the per-trip cap to its own 422
// without this helper knowing about HTTP.
var errExpenseLimitReached = errors.New("expense limit reached")

// linkedExpense describes one "record this booking's price" write. The money is
// two nullable fields rather than one number because an expense line carries
// both a plan and a payment (00067) — but the booking paths only ever set
// ActualAmount: a booked flip is a PAYMENT, and any plan the traveler put on
// that line is theirs. Leaving PlannedAmount nil on the refresh path is the
// whole preservation mechanism (UpdateExpense's COALESCE keeps what is there,
// and no clear flag exists that could reach it by mistake). That is this
// feature's best payoff: plan $400 for the flight, book it at $372, see the
// −$28 without typing anything.
type linkedExpense struct {
	TripID        uuid.UUID
	Category      string
	Label         string
	PlannedAmount *float64
	ActualAmount  *float64
	SourceKind    *string
	SourceID      pgtype.UUID
	// LegKey is the OTHER identity a line can carry (00070) — the city leg it
	// plans for. Mutually exclusive with the source link, and deliberately NOT
	// an auto marker: the booking paths own a payment, this owns a plan.
	LegKey *string
}

// upsertLinkedExpense is the ONE implementation of "record this booking's price
// in the budget" (docs/zen.md: second implementation of anything? consume the
// first). Extracted from addExpenseHandler when the booking-shortlist choose
// transaction (00065) needed the same behaviour inside its own tx — hence the
// store.Querier argument, which is either store.New(dbPool) or store.New(tx).
//
// There are two identities a line can carry, and each makes the POST an
// upsert on its own partial unique index:
//
//   - by SOURCE (00061), the booking mirror. Found & still auto -> refresh it
//     (a re-book with a new price); found & user-owned -> return it untouched
//     (never clobber a manual takeover).
//   - by LEG (00070), the city's daily plan. Found -> untouched, always.
//
// An add carrying neither always creates. The two are mutually exclusive; the
// handler refuses a request that names both.
func upsertLinkedExpense(ctx context.Context, q *store.Queries, in linkedExpense) (store.TripExpense, expenseOutcome, error) {
	if in.SourceKind != nil {
		if existing, err := q.GetExpenseBySource(ctx, store.GetExpenseBySourceParams{
			TripID: in.TripID, SourceKind: in.SourceKind, SourceID: in.SourceID,
		}); err == nil {
			if !existing.Auto {
				return existing, expenseUntouched, nil
			}
			autoTrue := true
			updated, err := q.UpdateExpense(ctx, store.UpdateExpenseParams{
				ID: existing.ID, TripID: in.TripID,
				Category: &in.Category, Label: &in.Label,
				PlannedAmount: in.PlannedAmount, ActualAmount: in.ActualAmount,
				Auto: &autoTrue,
			})
			if err != nil {
				return store.TripExpense{}, expenseUntouched, err
			}
			return updated, expenseRefreshed, nil
		}
	}

	// Leg-keyed adds are an upsert-by-leg (the 00070 partial unique index).
	// Found -> return it UNTOUCHED, always: unlike the booking mirror above
	// there is no "still auto" case to refresh, because the number on this line
	// is the traveler's plan the moment it exists. A second tap on a city
	// already in the plan must not quietly restate it at today's tier.
	if in.SourceKind == nil && in.LegKey != nil {
		if existing, err := q.GetExpenseByLegKey(ctx, store.GetExpenseByLegKeyParams{
			TripID: in.TripID, LegKey: in.LegKey, Category: in.Category,
		}); err == nil {
			return existing, expenseUntouched, nil
		}
	}

	// The per-trip cap guards creates only — the upsert paths above can't grow
	// the list.
	if existing, err := q.ListExpensesByTrip(ctx, in.TripID); err == nil &&
		len(existing) >= maxExpensesPerTrip() {
		return store.TripExpense{}, expenseUntouched, errExpenseLimitReached
	}
	expense, err := q.CreateExpense(ctx, store.CreateExpenseParams{
		TripID:        in.TripID,
		Category:      in.Category,
		Label:         in.Label,
		PlannedAmount: in.PlannedAmount,
		ActualAmount:  in.ActualAmount,
		Position:      9999,
		Auto:          in.SourceKind != nil, // server rule: auto iff linked
		SourceKind:    in.SourceKind,
		SourceID:      in.SourceID,
		LegKey:        in.LegKey,
	})
	if err != nil {
		// Concurrent POSTs can race past either lookup; the partial unique
		// indexes turn the loser into a 23505 — re-read and take the found path
		// so the caller still gets the one row that exists.
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			if in.SourceKind != nil {
				if existing, lookupErr := q.GetExpenseBySource(ctx, store.GetExpenseBySourceParams{
					TripID: in.TripID, SourceKind: in.SourceKind, SourceID: in.SourceID,
				}); lookupErr == nil {
					return existing, expenseUntouched, nil
				}
			}
			if in.LegKey != nil {
				if existing, lookupErr := q.GetExpenseByLegKey(ctx, store.GetExpenseByLegKeyParams{
					TripID: in.TripID, LegKey: in.LegKey, Category: in.Category,
				}); lookupErr == nil {
					return existing, expenseUntouched, nil
				}
			}
		}
		return store.TripExpense{}, expenseUntouched, err
	}
	return expense, expenseCreated, nil
}
