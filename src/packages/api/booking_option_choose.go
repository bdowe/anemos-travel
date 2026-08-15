package main

import (
	"net/http"
	"strconv"
	"strings"

	"github.com/google/uuid"
	"github.com/gorilla/mux"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// booking_option_choose.go — promoting a shortlisted candidate to THE booking,
// and reversing it (migration 00065, specs/booking-shortlist).
//
// This is the only multi-table write in the feature, so it is one transaction
// behind one endpoint rather than a client-orchestrated sequence: creating the
// record, linking it to the option, flipping the leg booked and recording the
// spend must either all happen or none of them. The client half of the older
// booked flip (_setRowBooked) is an optimistic three-call lockstep with manual
// rollback precisely because it predates having a place to put this.
//
// The response is an envelope rather than the whole trip: it carries every
// piece of post-state its caller will render — including the leg's remaining
// options, so the loser list can't blank — AND names what it declined to do
// (expense_skipped). docs/zen.md: a mutating call must state the post-state its
// consumer will observe, and "success" with no derived state is silent
// error-passing.

type ChooseBookingOptionResponse struct {
	Option BookingOptionResponse `json:"option"`
	// Options is the whole leg's post-state, in render order.
	Options       []BookingOptionResponse `json:"options"`
	BookingTodo   BookingTodoResponse     `json:"booking_todo"`
	Accommodation *AccommodationResponse  `json:"accommodation,omitempty"`
	Segment       *SegmentResponse        `json:"segment,omitempty"`
	// ReplacedOptionID names the candidate that used to hold this leg, so the
	// client can say "replaced Hotel Salvator" instead of silently re-pointing.
	ReplacedOptionID *string          `json:"replaced_option_id,omitempty"`
	Expense          *ExpenseResponse `json:"expense,omitempty"`
	// ExpenseSkipped says WHY no expense was written: no_budget | no_price |
	// currency_mismatch. Never both set with Expense.
	ExpenseSkipped *string `json:"expense_skipped,omitempty"`
}

// formatOptionPrice renders an option's money for a record's free-text
// price_note. Code AFTER the amount and no symbol table on purpose: guessing a
// symbol (or a locale's separators) from a 3-letter code is exactly the kind of
// silent invention this repo keeps paying for, and "1240 EUR" is unambiguous
// everywhere.
func formatOptionPrice(price *float64, currency *string) *string {
	if price == nil || currency == nil {
		return nil
	}
	amount := strconv.FormatFloat(*price, 'f', -1, 64)
	s := amount + " " + *currency
	return &s
}

// promotedSegmentMode resolves the mode a promoted transport record must carry
// (trip_segments.mode is NOT NULL). One ladder, in one place: the option's own
// mode (set explicitly by the save sheet, or "flight" when saved off a flight
// search) beats the leg's, which is transportSlotMode's existing definition —
// per-leg override, then what the provider implies, then the trip's ground
// mode. "flight" is the last resort because a transport leg with no signal at
// all is overwhelmingly a flight (it is what _deriveTodos assumes too).
func promotedSegmentMode(opt store.BookingOption, trip store.Trip, todo store.BookingTodo) string {
	if opt.Mode != nil && allowedOptionModes[*opt.Mode] {
		return *opt.Mode
	}
	if m := transportSlotMode(trip, todo); m != nil {
		return *m
	}
	return "flight"
}

// firstNonEmpty returns the first non-blank of its arguments, or nil.
func firstNonEmpty(vals ...*string) *string {
	for _, v := range vals {
		if v != nil && strings.TrimSpace(*v) != "" {
			return v
		}
	}
	return nil
}

// firstValidDate returns the first date that is actually set.
func firstValidDate(vals ...pgtype.Date) pgtype.Date {
	for _, v := range vals {
		if v.Valid {
			return v
		}
	}
	return pgtype.Date{}
}

// expenseCategoryForLeg maps a leg to a budget category the same way the
// client's deriveBookedExpensePrefill does.
func expenseCategoryForLeg(kind, mode string) string {
	switch kind {
	case "stay":
		return "lodging"
	case "transport":
		if mode == "flight" {
			return "flights"
		}
		return "transport"
	}
	return "general"
}

func chooseBookingOptionHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	optID, err := uuid.Parse(mux.Vars(r)["optionId"])
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "option not found")
		return
	}
	ctx := r.Context()
	tx, err := dbPool.Begin(ctx)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not save your choice")
		return
	}
	defer tx.Rollback(ctx)
	q := store.New(tx)

	// Serialize against a concurrent choose on the same leg, so
	// idx_booking_options_winner stays a backstop rather than the mechanism.
	if _, err := q.GetTripForUpdate(ctx, trip.ID); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not save your choice")
		return
	}

	opt, err := q.GetBookingOption(ctx, store.GetBookingOptionParams{ID: optID, TripID: trip.ID})
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "option not found")
		return
	}
	todo, err := q.GetBookingTodo(ctx, store.GetBookingTodoParams{ID: opt.BookingTodoID, TripID: trip.ID})
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "booking row not found")
		return
	}
	// An "other" leg has no target table, and picking one for it would be a
	// guess. Refuse out loud.
	if todo.Kind != "stay" && todo.Kind != "transport" {
		writeJSONError(w, http.StatusUnprocessableEntity,
			"only stay and transport bookings can have a chosen option")
		return
	}

	// Un-stamp whoever held the leg first, so the partial unique index can't
	// fire on the write below.
	replaced, err := q.ClearBookingTodoWinner(ctx, todo.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not save your choice")
		return
	}
	var replacedID *string
	for _, id := range replaced {
		if id != opt.ID {
			s := id.String()
			replacedID = &s
		}
	}

	priceNote := formatOptionPrice(opt.Price, opt.Currency)
	resp := ChooseBookingOptionResponse{}
	var promotedAcc, promotedSeg pgtype.UUID
	var expenseSourceID uuid.UUID
	category := ""

	if todo.Kind == "stay" {
		acc, err := q.PromoteAccommodationFromOption(ctx, store.PromoteAccommodationFromOptionParams{
			TripID:    trip.ID,
			Name:      opt.Title,
			Provider:  opt.Provider,
			Url:       opt.Url,
			CheckIn:   firstValidDate(opt.StartDate, todo.DepartDate),
			CheckOut:  firstValidDate(opt.EndDate, todo.ReturnDate),
			PriceNote: priceNote,
			AutoKey:   &todo.TodoKey,
		})
		if err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not save your choice")
			return
		}
		promotedAcc = pgtype.UUID{Bytes: acc.ID, Valid: true}
		expenseSourceID = todo.ID
		category = expenseCategoryForLeg("stay", "")
		accResp := toAccommodationResponse(acc)
		resp.Accommodation = &accResp
	} else {
		mode := promotedSegmentMode(opt, trip, todo)
		seg, err := q.PromoteSegmentFromOption(ctx, store.PromoteSegmentFromOptionParams{
			TripID:      trip.ID,
			Mode:        mode,
			Origin:      firstNonEmpty(opt.Origin, todo.OriginLabel),
			Destination: firstNonEmpty(opt.Destination, todo.DestinationLabel),
			DepartDate:  firstValidDate(opt.StartDate, todo.DepartDate),
			ArriveDate:  firstValidDate(opt.EndDate),
			Provider:    opt.Provider,
			Url:         opt.Url,
			PriceNote:   priceNote,
			Notes:       opt.Notes,
			AutoKey:     &todo.TodoKey,
		})
		if err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not save your choice")
			return
		}
		promotedSeg = pgtype.UUID{Bytes: seg.ID, Valid: true}
		expenseSourceID = todo.ID
		category = expenseCategoryForLeg("transport", mode)
		segResp := toSegmentResponse(seg)
		resp.Segment = &segResp
	}

	chosen, err := q.SetBookingOptionPromotion(ctx, store.SetBookingOptionPromotionParams{
		ID:                      opt.ID,
		TripID:                  trip.ID,
		PromotedAccommodationID: promotedAcc,
		PromotedSegmentID:       promotedSeg,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not save your choice")
		return
	}
	updatedTodo, err := q.SetBookingTodoBooked(ctx, store.SetBookingTodoBookedParams{
		ID: todo.ID, TripID: trip.ID, Booked: true,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not save your choice")
		return
	}

	// Money rides the same transaction. It is skipped — loudly — rather than
	// guessed: there is no FX anywhere in this app (00042), so an option priced
	// in EUR cannot be added to a USD budget, and saying so beats both silently
	// dropping it and inventing a rate.
	skip := ""
	budget, budgetErr := q.GetBudgetByTrip(ctx, trip.ID)
	switch {
	case budgetErr != nil:
		skip = "no_budget"
	case opt.Price == nil || opt.Currency == nil:
		skip = "no_price"
	case !strings.EqualFold(*opt.Currency, budget.Currency):
		skip = "currency_mismatch"
	}
	if skip == "" {
		expense, _, err := upsertLinkedExpense(ctx, q, trip.ID, category, opt.Title, *opt.Price,
			ptrTo("booking_todo"), pgtype.UUID{Bytes: expenseSourceID, Valid: true})
		if err != nil {
			// The booking itself is the point; a full budget or a racing write
			// must not lose the traveler their choice.
			skip = "no_budget"
		} else {
			expResp := toExpenseResponse(expense)
			resp.Expense = &expResp
		}
	}
	if skip != "" {
		resp.ExpenseSkipped = &skip
	}

	options, err := q.ListBookingOptionsByTodo(ctx, todo.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not save your choice")
		return
	}
	_ = q.TouchTrip(ctx, touchedBy(trip.ID, r))
	if err := tx.Commit(ctx); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not save your choice")
		return
	}

	resp.Option = toBookingOptionResponse(chosen)
	resp.BookingTodo = toBookingTodoResponse(updatedTodo)
	resp.ReplacedOptionID = replacedID
	for _, o := range options {
		resp.Options = append(resp.Options, toBookingOptionResponse(o))
	}
	if user, ok := userFromContext(ctx); ok {
		safeGo("recordEvent", func() {
			recordEvent(user.ID, "booking_option_chosen", &trip.ID, map[string]any{
				"kind":     todo.Kind,
				"provider": strPtrVal(chosen.Provider),
				"replaced": replacedID != nil,
			})
		})
	}
	writeJSON(w, http.StatusOK, resp)
}

// unchooseBookingOptionHandler reverses a choice: clears the stamp, unbooks
// both flags, drops the auto expense.
//
// It deliberately KEEPS the promoted record. That row may carry a hand-typed
// address or notes the traveler added after choosing, and destroying user
// content to undo a link is never the safe default — the record is one tap from
// deletion through its own route if they really want it gone.
func unchooseBookingOptionHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	optID, err := uuid.Parse(mux.Vars(r)["optionId"])
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "option not found")
		return
	}
	ctx := r.Context()
	tx, err := dbPool.Begin(ctx)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not undo your choice")
		return
	}
	defer tx.Rollback(ctx)
	q := store.New(tx)

	opt, err := q.GetBookingOption(ctx, store.GetBookingOptionParams{ID: optID, TripID: trip.ID})
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "option not found")
		return
	}
	if !optionChosen(opt) {
		writeJSONError(w, http.StatusConflict, "this option is not the chosen booking")
		return
	}
	todo, err := q.GetBookingTodo(ctx, store.GetBookingTodoParams{ID: opt.BookingTodoID, TripID: trip.ID})
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "booking row not found")
		return
	}

	notBooked := false
	if opt.PromotedAccommodationID.Valid {
		if _, err := q.UpdateAccommodation(ctx, store.UpdateAccommodationParams{
			ID: uuid.UUID(opt.PromotedAccommodationID.Bytes), TripID: trip.ID, Booked: &notBooked,
		}); err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not undo your choice")
			return
		}
	}
	if opt.PromotedSegmentID.Valid {
		if _, err := q.UpdateSegment(ctx, store.UpdateSegmentParams{
			ID: uuid.UUID(opt.PromotedSegmentID.Bytes), TripID: trip.ID, Booked: &notBooked,
		}); err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not undo your choice")
			return
		}
	}
	if _, err := q.ClearBookingTodoWinner(ctx, todo.ID); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not undo your choice")
		return
	}
	updatedTodo, err := q.SetBookingTodoBooked(ctx, store.SetBookingTodoBookedParams{
		ID: todo.ID, TripID: trip.ID, Booked: false,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not undo your choice")
		return
	}
	// Mirror the unbook contract from 00061: an AUTO expense is a mirror of the
	// booked state and goes with it; a manual takeover (auto=false) is the
	// traveler's own line item and stays.
	if existing, err := q.GetExpenseBySource(ctx, store.GetExpenseBySourceParams{
		TripID: trip.ID, SourceKind: ptrTo("booking_todo"),
		SourceID: pgtype.UUID{Bytes: todo.ID, Valid: true},
	}); err == nil && existing.Auto {
		_, _ = q.DeleteExpense(ctx, store.DeleteExpenseParams{ID: existing.ID, TripID: trip.ID})
	}

	reverted, err := q.GetBookingOption(ctx, store.GetBookingOptionParams{ID: optID, TripID: trip.ID})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not undo your choice")
		return
	}
	options, err := q.ListBookingOptionsByTodo(ctx, todo.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not undo your choice")
		return
	}
	_ = q.TouchTrip(ctx, touchedBy(trip.ID, r))
	if err := tx.Commit(ctx); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not undo your choice")
		return
	}

	resp := ChooseBookingOptionResponse{
		Option:      toBookingOptionResponse(reverted),
		BookingTodo: toBookingTodoResponse(updatedTodo),
	}
	for _, o := range options {
		resp.Options = append(resp.Options, toBookingOptionResponse(o))
	}
	writeJSON(w, http.StatusOK, resp)
}
