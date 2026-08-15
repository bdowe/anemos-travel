package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/google/uuid"
	"github.com/gorilla/mux"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// booking_option_handler.go — CRUD for the per-leg shortlist (migration 00065,
// specs/booking-shortlist). The choose transaction, which is the only
// multi-table write in the feature, lives next door in booking_option_choose.go.
//
// Options ride the trip payload on GET /trips/{id} (trip_handler.go) rather
// than getting a list route of their own: the trip screen already loads
// everything in one request, and a shortlist is only ever read in the context
// of the legs it hangs off.

type BookingOptionResponse struct {
	ID            string `json:"id"`
	BookingTodoID string `json:"booking_todo_id"`
	Title         string `json:"title"`

	Subtitle *string  `json:"subtitle,omitempty"`
	URL      *string  `json:"url,omitempty"`
	Provider *string  `json:"provider,omitempty"`
	Notes    *string  `json:"notes,omitempty"`
	ImageURL *string  `json:"image_url,omitempty"`
	Price    *float64 `json:"price,omitempty"`
	Currency *string  `json:"currency,omitempty"`

	StartDate   *string `json:"start_date,omitempty"`
	EndDate     *string `json:"end_date,omitempty"`
	Origin      *string `json:"origin,omitempty"`
	Destination *string `json:"destination,omitempty"`
	Mode        *string `json:"mode,omitempty"`

	// Chosen is server-computed from the two promoted ids so no client ever has
	// to OR two nullable uuids to answer "did this one win" — one derivation,
	// one place (docs/zen.md).
	Chosen                  bool    `json:"chosen"`
	PromotedAccommodationID *string `json:"promoted_accommodation_id,omitempty"`
	PromotedSegmentID       *string `json:"promoted_segment_id,omitempty"`

	Position int32 `json:"position"`

	// SavedAt is what stops a snapshot price being read as a live one. Nothing
	// re-fetches an option's fare (price_alerts was dropped in 00056 for going
	// unused), so the wire says how old the number is and the UI shows it.
	SavedAt string `json:"saved_at"`
}

// optionChosen is the single definition of "this option won its leg".
func optionChosen(o store.BookingOption) bool {
	return o.PromotedAccommodationID.Valid || o.PromotedSegmentID.Valid
}

func pgUUIDToPtr(u pgtype.UUID) *string {
	if !u.Valid {
		return nil
	}
	s := uuid.UUID(u.Bytes).String()
	return &s
}

func toBookingOptionResponse(o store.BookingOption) BookingOptionResponse {
	return BookingOptionResponse{
		ID:                      o.ID.String(),
		BookingTodoID:           o.BookingTodoID.String(),
		Title:                   o.Title,
		Subtitle:                o.Subtitle,
		URL:                     o.Url,
		Provider:                o.Provider,
		Notes:                   o.Notes,
		ImageURL:                o.ImageUrl,
		Price:                   o.Price,
		Currency:                o.Currency,
		StartDate:               dateToPtr(o.StartDate),
		EndDate:                 dateToPtr(o.EndDate),
		Origin:                  o.Origin,
		Destination:             o.Destination,
		Mode:                    o.Mode,
		Chosen:                  optionChosen(o),
		PromotedAccommodationID: pgUUIDToPtr(o.PromotedAccommodationID),
		PromotedSegmentID:       pgUUIDToPtr(o.PromotedSegmentID),
		Position:                o.Position,
		SavedAt:                 o.CreatedAt.UTC().Format("2006-01-02T15:04:05Z"),
	}
}

type BookingOptionRequest struct {
	BookingTodoID string   `json:"booking_todo_id"` // create only; a candidate can't change legs
	Title         *string  `json:"title"`
	Subtitle      *string  `json:"subtitle"`
	URL           *string  `json:"url"`
	Provider      *string  `json:"provider"`
	Notes         *string  `json:"notes"`
	ImageURL      *string  `json:"image_url"`
	Price         *float64 `json:"price"`
	Currency      *string  `json:"currency"`
	StartDate     *string  `json:"start_date"`
	EndDate       *string  `json:"end_date"`
	Origin        *string  `json:"origin"`
	Destination   *string  `json:"destination"`
	Mode          *string  `json:"mode"`
}

var allowedOptionModes = map[string]bool{
	"flight": true, "car": true, "train": true, "bus": true, "ferry": true,
}

// validateBookingOptionInput bounds the free-text sinks and normalizes the
// currency, so the caller gets a 400 naming the field instead of a 500 carrying
// a constraint name.
//
// It deliberately does NOT check the price/currency pair rule: that rule is
// about the row's EFFECTIVE state, and a PATCH naming only the currency of a
// row that already has a price is legitimate. Each caller checks the pair
// against the state it will actually write — the payload on create, the merge
// on patch. (The rule itself matters because a number with no currency cannot
// be summed and this app has no FX, 00042: the Budget projection would have to
// either drop it silently or guess.)
func validateBookingOptionInput(req *BookingOptionRequest, requireTitle bool) error {
	if requireTitle {
		if req.Title == nil || strings.TrimSpace(*req.Title) == "" {
			return fmt.Errorf("title is required")
		}
	}
	if req.Title != nil {
		if _, err := boundedString("title", *req.Title, maxNameLen); err != nil {
			return err
		}
	}
	for _, f := range []struct {
		name string
		val  *string
		max  int
	}{
		{"subtitle", req.Subtitle, maxNameLen},
		{"provider", req.Provider, maxProviderLen},
		{"url", req.URL, maxURLLen},
		{"image_url", req.ImageURL, maxURLLen},
		{"notes", req.Notes, maxNoteLen},
		{"origin", req.Origin, maxNameLen},
		{"destination", req.Destination, maxNameLen},
	} {
		if err := boundedOptional(f.name, f.val, f.max); err != nil {
			return err
		}
	}
	if req.Price != nil && *req.Price < 0 {
		return fmt.Errorf("price must not be negative")
	}
	if req.Currency != nil {
		c := strings.ToUpper(strings.TrimSpace(*req.Currency))
		if len(c) != 3 {
			return fmt.Errorf("currency must be a 3-letter code")
		}
		for _, r := range c {
			if r < 'A' || r > 'Z' {
				return fmt.Errorf("currency must be a 3-letter code")
			}
		}
		*req.Currency = c
	}
	if req.Mode != nil && !allowedOptionModes[*req.Mode] {
		return fmt.Errorf("mode must be one of flight, car, train, bus, ferry")
	}
	return nil
}

func addBookingOptionHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	var req BookingOptionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	todoID, err := uuid.Parse(strings.TrimSpace(req.BookingTodoID))
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "booking_todo_id is required")
		return
	}
	if err := validateBookingOptionInput(&req, true); err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	// On create the payload IS the effective state, so the pair rule is checked
	// against it directly; the patch path checks the MERGED state instead,
	// because a partial update naming only the currency is legitimate.
	if (req.Price == nil) != (req.Currency == nil) {
		writeJSONError(w, http.StatusBadRequest, "price and currency must be provided together")
		return
	}
	startDate, err := parseDateParam(req.StartDate)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "start_date must be YYYY-MM-DD")
		return
	}
	endDate, err := parseDateParam(req.EndDate)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "end_date must be YYYY-MM-DD")
		return
	}

	q := store.New(dbPool)
	// The leg must exist ON THIS TRIP. Without this check the FK would still
	// hold, but an option could be hung off another trip's leg — visible to
	// that trip's owner, written by someone who can't see it.
	todo, err := q.GetBookingTodo(r.Context(), store.GetBookingTodoParams{ID: todoID, TripID: trip.ID})
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "booking row not found")
		return
	}
	if n, err := q.CountBookingOptionsByTodo(r.Context(), todo.ID); err == nil &&
		int(n) >= maxBookingOptionsPerTodo() {
		writeJSONError(w, http.StatusUnprocessableEntity,
			fmt.Sprintf("saved-option limit reached for this booking (max %d) — remove one first",
				maxBookingOptionsPerTodo()))
		return
	}
	if n, err := q.CountBookingOptionsByTrip(r.Context(), trip.ID); err == nil &&
		int(n) >= maxBookingOptionsPerTrip() {
		writeJSONError(w, http.StatusUnprocessableEntity,
			fmt.Sprintf("saved-option limit reached for this trip (max %d) — remove one first",
				maxBookingOptionsPerTrip()))
		return
	}

	opt, err := q.CreateBookingOption(r.Context(), store.CreateBookingOptionParams{
		TripID:        trip.ID,
		BookingTodoID: todo.ID,
		Title:         strings.TrimSpace(*req.Title),
		Subtitle:      req.Subtitle,
		Url:           req.URL,
		Provider:      req.Provider,
		Notes:         req.Notes,
		ImageUrl:      req.ImageURL,
		Price:         req.Price,
		Currency:      req.Currency,
		StartDate:     startDate,
		EndDate:       endDate,
		Origin:        req.Origin,
		Destination:   req.Destination,
		Mode:          req.Mode,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not save option")
		return
	}
	_ = q.TouchTrip(r.Context(), touchedBy(trip.ID, r))
	if user, ok := userFromContext(r.Context()); ok {
		recordEvent(user.ID, "booking_option_saved", &trip.ID, map[string]any{
			"kind":      todo.Kind,
			"provider":  strPtrVal(opt.Provider),
			"has_price": opt.Price != nil,
		})
	}
	writeJSON(w, http.StatusCreated, toBookingOptionResponse(opt))
}

func updateBookingOptionHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	optID, err := uuid.Parse(mux.Vars(r)["optionId"])
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "option not found")
		return
	}
	var req BookingOptionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if err := validateBookingOptionInput(&req, false); err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	// The pair rule has to be re-checked against the STORED row, not just the
	// patch: clearing a price while leaving a currency (or vice versa) would
	// otherwise sneak past the field-level check and hit the CHECK constraint
	// as a 500.
	existing, err := store.New(dbPool).GetBookingOption(r.Context(),
		store.GetBookingOptionParams{ID: optID, TripID: trip.ID})
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "option not found")
		return
	}
	mergedPrice, mergedCurrency := existing.Price, existing.Currency
	if req.Price != nil {
		mergedPrice = req.Price
	}
	if req.Currency != nil {
		mergedCurrency = req.Currency
	}
	if (mergedPrice == nil) != (mergedCurrency == nil) {
		writeJSONError(w, http.StatusBadRequest, "price and currency must be provided together")
		return
	}

	startDate, err := parseDateParam(req.StartDate)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "start_date must be YYYY-MM-DD")
		return
	}
	endDate, err := parseDateParam(req.EndDate)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "end_date must be YYYY-MM-DD")
		return
	}
	var title *string
	if req.Title != nil {
		t := strings.TrimSpace(*req.Title)
		title = &t
	}

	opt, err := store.New(dbPool).UpdateBookingOption(r.Context(), store.UpdateBookingOptionParams{
		ID:          optID,
		TripID:      trip.ID,
		Title:       title,
		Subtitle:    req.Subtitle,
		Url:         req.URL,
		Provider:    req.Provider,
		Notes:       req.Notes,
		ImageUrl:    req.ImageURL,
		Price:       req.Price,
		Currency:    req.Currency,
		StartDate:   startDate,
		EndDate:     endDate,
		Origin:      req.Origin,
		Destination: req.Destination,
		Mode:        req.Mode,
	})
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "option not found")
		return
	}
	_ = store.New(dbPool).TouchTrip(r.Context(), touchedBy(trip.ID, r))
	writeJSON(w, http.StatusOK, toBookingOptionResponse(opt))
}

// deleteBookingOptionHandler removes a candidate. It refuses a CHOSEN one with
// a 409: un-choosing has side effects the traveler did not ask for by tapping
// "remove bookmark" (it unbooks the leg and deletes the linked expense), and
// doing them silently is exactly the error-passing-silently case docs/zen.md
// names. DELETE .../choose is the explicit way to reverse a choice.
func deleteBookingOptionHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	optID, err := uuid.Parse(mux.Vars(r)["optionId"])
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "option not found")
		return
	}
	q := store.New(dbPool)
	rows, err := q.DeleteBookingOption(r.Context(),
		store.DeleteBookingOptionParams{ID: optID, TripID: trip.ID})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not remove option")
		return
	}
	if rows == 0 {
		// Distinguish "not yours / not here" from "it's the chosen one", so the
		// client can offer the right next step instead of a generic failure.
		if _, err := q.GetBookingOption(r.Context(),
			store.GetBookingOptionParams{ID: optID, TripID: trip.ID}); err == nil {
			writeJSONError(w, http.StatusConflict,
				"this option is the chosen booking — un-choose it before removing it")
			return
		}
		writeJSONError(w, http.StatusNotFound, "option not found")
		return
	}
	_ = q.TouchTrip(r.Context(), touchedBy(trip.ID, r))
	w.WriteHeader(http.StatusNoContent)
}
