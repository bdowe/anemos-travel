package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/google/uuid"
	"github.com/gorilla/mux"
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
	// The booking-row link this expense was autopopulated from (nil for
	// manual entries). The client needs both to dedupe the booked-flip
	// prompt and to find the row to remove on unbook.
	SourceKind *string `json:"source_kind"`
	SourceID   *string `json:"source_id"`
}

func toExpenseResponse(e store.TripExpense) ExpenseResponse {
	resp := ExpenseResponse{
		ID:         e.ID.String(),
		Category:   e.Category,
		Label:      e.Label,
		Amount:     e.Amount,
		Position:   int(e.Position),
		Auto:       e.Auto,
		SourceKind: e.SourceKind,
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
	// Optional booking-row link (both or neither): makes the POST an
	// upsert-by-source and marks the row auto (see the migration 00061
	// contract). Plain manual adds omit them, byte-identical to before.
	SourceKind *string `json:"source_kind"`
	SourceID   *string `json:"source_id"`
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
	if (req.SourceKind == nil) != (req.SourceID == nil) {
		writeJSONError(w, http.StatusBadRequest, "source_kind and source_id must be passed together")
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

	// Linked adds are an upsert-by-source: at most one expense per booking
	// row (partial unique index). Found & still auto -> refresh it (a
	// re-book with a new price); found & user-owned -> return it untouched
	// (never clobber a manual takeover). Both are 200s — idempotent
	// re-submits, no client error handling for the retry race.
	if req.SourceKind != nil {
		if existing, err := q.GetExpenseBySource(r.Context(), store.GetExpenseBySourceParams{
			TripID: trip.ID, SourceKind: req.SourceKind, SourceID: sourceID,
		}); err == nil {
			if !existing.Auto {
				writeJSON(w, http.StatusOK, toExpenseResponse(existing))
				return
			}
			autoTrue := true
			updated, err := q.UpdateExpense(r.Context(), store.UpdateExpenseParams{
				ID: existing.ID, TripID: trip.ID,
				Category: &category, Label: &label, Amount: &req.Amount, Auto: &autoTrue,
			})
			if err != nil {
				writeJSONError(w, http.StatusInternalServerError, "could not save expense")
				return
			}
			_ = q.TouchTrip(r.Context(), touchedBy(trip.ID, r))
			writeJSON(w, http.StatusOK, toExpenseResponse(updated))
			return
		}
	}

	// The per-trip cap guards creates only — the upsert path above can't
	// grow the list.
	if existing, err := q.ListExpensesByTrip(r.Context(), trip.ID); err == nil &&
		len(existing) >= maxExpensesPerTrip() {
		writeJSONError(w, http.StatusUnprocessableEntity,
			fmt.Sprintf("expense limit reached (max %d) — remove one first", maxExpensesPerTrip()))
		return
	}
	expense, err := q.CreateExpense(r.Context(), store.CreateExpenseParams{
		TripID:     trip.ID,
		Category:   category,
		Label:      label,
		Amount:     req.Amount,
		Position:   9999,
		Auto:       req.SourceKind != nil, // server rule: auto iff linked
		SourceKind: req.SourceKind,
		SourceID:   sourceID,
	})
	if err != nil {
		// Concurrent linked POSTs can race past the lookup; the partial
		// unique index turns the loser into a 23505 — re-read and take the
		// found path so the caller still gets the one linked row.
		var pgErr *pgconn.PgError
		if req.SourceKind != nil && errors.As(err, &pgErr) && pgErr.Code == "23505" {
			if existing, lookupErr := q.GetExpenseBySource(r.Context(), store.GetExpenseBySourceParams{
				TripID: trip.ID, SourceKind: req.SourceKind, SourceID: sourceID,
			}); lookupErr == nil {
				writeJSON(w, http.StatusOK, toExpenseResponse(existing))
				return
			}
		}
		writeJSONError(w, http.StatusInternalServerError, "could not save expense")
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
	// Server rule (never a request field): editing the CONTENT of an
	// auto-created expense is a manual takeover — the row stops mirroring
	// its booking's booked state (unbook then leaves it; see the 00061
	// contract). Reordering isn't ownership, so a position-only PATCH
	// leaves auto alone.
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
