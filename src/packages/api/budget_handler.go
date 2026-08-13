package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/google/uuid"
	"github.com/gorilla/mux"

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
// `spent`/`remaining` on BudgetResponse are a server-side convenience derived
// by summing every expense's amount.

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

// BudgetResponse carries the single per-trip budget. `spent` is the sum of every
// expense amount and `remaining` is target-spent (nil when no target is set) —
// both derived server-side for convenience; the client still gets the raw
// expense list from GET /budget/expenses to compute its own subtotals.
type BudgetResponse struct {
	TargetAmount *float64 `json:"target_amount"`
	Currency     string   `json:"currency"`
	Spent        float64  `json:"spent"`
	Remaining    *float64 `json:"remaining"`
}

type ExpenseResponse struct {
	ID       string  `json:"id"`
	Category string  `json:"category"`
	Label    string  `json:"label"`
	Amount   float64 `json:"amount"`
	Position int     `json:"position"`
	Auto     bool    `json:"auto"`
}

func toExpenseResponse(e store.TripExpense) ExpenseResponse {
	return ExpenseResponse{
		ID:       e.ID.String(),
		Category: e.Category,
		Label:    e.Label,
		Amount:   e.Amount,
		Position: int(e.Position),
		Auto:     e.Auto,
	}
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

// buildBudgetResponse computes spent/remaining from the expense list and the
// (possibly nil) target. A trip with no budget row yet reports the defaults:
// no target, USD currency.
func buildBudgetResponse(b *store.TripBudget, expenses []store.TripExpense) BudgetResponse {
	var spent float64
	for _, e := range expenses {
		spent += e.Amount
	}
	resp := BudgetResponse{Currency: "USD", Spent: spent}
	if b != nil {
		resp.Currency = b.Currency
		resp.TargetAmount = b.TargetAmount
		if b.TargetAmount != nil {
			rem := *b.TargetAmount - spent
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
	Category string  `json:"category"`
	Label    string  `json:"label"`
	Amount   float64 `json:"amount"`
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
	if req.Amount < 0 {
		writeJSONError(w, http.StatusBadRequest, "amount cannot be negative")
		return
	}
	category, valid := normalizeExpenseCategory(req.Category)
	if !valid {
		writeJSONError(w, http.StatusBadRequest, "category must be one of: "+expenseCategoryList)
		return
	}

	q := store.New(dbPool)
	if existing, err := q.ListExpensesByTrip(r.Context(), trip.ID); err == nil &&
		len(existing) >= maxExpensesPerTrip() {
		writeJSONError(w, http.StatusUnprocessableEntity,
			fmt.Sprintf("expense limit reached (max %d) — remove one first", maxExpensesPerTrip()))
		return
	}
	expense, err := q.CreateExpense(r.Context(), store.CreateExpenseParams{
		TripID:   trip.ID,
		Category: category,
		Label:    label,
		Amount:   req.Amount,
		Position: 9999,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not save expense")
		return
	}
	_ = q.TouchTrip(r.Context(), touchedBy(trip.ID, r))
	writeJSON(w, http.StatusCreated, toExpenseResponse(expense))
}

// PatchExpenseRequest is a partial update: recategorize, relabel, change amount,
// reposition.
type PatchExpenseRequest struct {
	Category *string  `json:"category"`
	Label    *string  `json:"label"`
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
	if req.Category == nil && req.Label == nil && req.Amount == nil && req.Position == nil {
		writeJSONError(w, http.StatusBadRequest, "pass at least one field to change (category, label, amount, or position)")
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
		params.Amount = req.Amount
	}
	if req.Position != nil {
		p := int32(*req.Position)
		params.Position = &p
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
