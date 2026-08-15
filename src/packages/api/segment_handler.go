package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/google/uuid"
	"github.com/gorilla/mux"

	"travel-route-planner/store"
)

var allowedSegmentModes = map[string]bool{
	"flight": true, "train": true, "bus": true, "car": true, "ferry": true, "other": true,
}

// validateSegmentInput bounds the free-text fields shared by the add + patch
// paths. `notes` is the biggest megabyte sink, so it gets the note ceiling.
func validateSegmentInput(req *AddSegmentRequest) error {
	if err := boundedOptional("origin", req.Origin, maxNameLen); err != nil {
		return err
	}
	if err := boundedOptional("destination", req.Destination, maxNameLen); err != nil {
		return err
	}
	if err := boundedOptional("provider", req.Provider, maxProviderLen); err != nil {
		return err
	}
	if err := boundedOptional("url", req.URL, maxURLLen); err != nil {
		return err
	}
	if err := boundedOptional("price_note", req.PriceNote, maxNoteLen); err != nil {
		return err
	}
	return boundedOptional("notes", req.Notes, maxNoteLen)
}

type SegmentResponse struct {
	ID          string  `json:"id"`
	Mode        string  `json:"mode"`
	Origin      *string `json:"origin,omitempty"`
	Destination *string `json:"destination,omitempty"`
	DepartDate  *string `json:"depart_date,omitempty"`
	ArriveDate  *string `json:"arrive_date,omitempty"`
	Provider    *string `json:"provider,omitempty"`
	URL         *string `json:"url,omitempty"`
	PriceNote   *string `json:"price_note,omitempty"`
	Notes       *string `json:"notes,omitempty"`
	Booked      bool    `json:"booked"`
	Auto        bool    `json:"auto"`
	AutoKey     *string `json:"auto_key,omitempty"`
}

type AddSegmentRequest struct {
	Mode        string  `json:"mode"`
	Origin      *string `json:"origin"`
	Destination *string `json:"destination"`
	DepartDate  *string `json:"depart_date"`
	ArriveDate  *string `json:"arrive_date"`
	Provider    *string `json:"provider"`
	URL         *string `json:"url"`
	PriceNote   *string `json:"price_note"`
	Notes       *string `json:"notes"`

	// PATCH-only: the "Booked" checkbox on confirmed rows. Ignored on add —
	// new segments start unbooked.
	Booked *bool `json:"booked"`
}

// findTripSegment returns one segment of a trip by id. Used by the PATCH path
// to check a partial date edit against the row's CURRENT state — there is no
// single-row query, and the per-trip list is small and already indexed.
func findTripSegment(ctx context.Context, tripID, segID uuid.UUID) (store.TripSegment, error) {
	segs, err := store.New(dbPool).ListSegmentsByTrip(ctx, tripID)
	if err != nil {
		return store.TripSegment{}, err
	}
	for _, s := range segs {
		if s.ID == segID {
			return s, nil
		}
	}
	return store.TripSegment{}, fmt.Errorf("segment %s not found on trip %s", segID, tripID)
}

func toSegmentResponse(s store.TripSegment) SegmentResponse {
	return SegmentResponse{
		ID:          s.ID.String(),
		Mode:        s.Mode,
		Origin:      s.Origin,
		Destination: s.Destination,
		DepartDate:  dateToPtr(s.DepartDate),
		ArriveDate:  dateToPtr(s.ArriveDate),
		Provider:    s.Provider,
		URL:         s.Url,
		PriceNote:   s.PriceNote,
		Notes:       s.Notes,
		Booked:      s.Booked,
		Auto:        s.Auto,
		AutoKey:     s.AutoKey,
	}
}

// transportLinksHandler builds the per-provider browse links. No auth.
func transportLinksHandler(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	origin := strings.TrimSpace(q.Get("origin"))
	destination := strings.TrimSpace(q.Get("destination"))
	if origin == "" || destination == "" {
		writeJSONError(w, http.StatusBadRequest, "origin and destination are required")
		return
	}
	passengers, _ := strconv.Atoi(q.Get("passengers"))
	links := transportLinks(TransportQuery{
		Mode:        strings.TrimSpace(q.Get("mode")),
		Origin:      origin,
		Destination: destination,
		DepartDate:  q.Get("depart_date"),
		ReturnDate:  q.Get("return_date"),
		Passengers:  passengers,
	})
	writeJSON(w, http.StatusOK, links)
}

func addSegmentHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	tripID := trip.ID
	var req AddSegmentRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	mode := strings.ToLower(strings.TrimSpace(req.Mode))
	if !allowedSegmentModes[mode] {
		writeJSONError(w, http.StatusBadRequest, "mode must be one of: flight, train, bus, car, ferry, other")
		return
	}
	if err := validateSegmentInput(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	depart, err := parseDateParam(req.DepartDate)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "depart_date must be YYYY-MM-DD")
		return
	}
	arrive, err := parseDateParam(req.ArriveDate)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "arrive_date must be YYYY-MM-DD")
		return
	}
	if depart.Valid && arrive.Valid && arrive.Time.Before(depart.Time) {
		writeJSONError(w, http.StatusBadRequest, "arrive_date must not be before depart_date")
		return
	}
	if existing, err := store.New(dbPool).ListSegmentsByTrip(r.Context(), tripID); err == nil &&
		len(existing) >= maxSegmentsPerTrip() {
		writeJSONError(w, http.StatusUnprocessableEntity,
			fmt.Sprintf("segment limit reached (max %d) — remove one first", maxSegmentsPerTrip()))
		return
	}

	seg, err := store.New(dbPool).CreateSegment(r.Context(), store.CreateSegmentParams{
		TripID:      tripID,
		Mode:        mode,
		Origin:      req.Origin,
		Destination: req.Destination,
		DepartDate:  depart,
		ArriveDate:  arrive,
		Provider:    req.Provider,
		Url:         req.URL,
		PriceNote:   req.PriceNote,
		Notes:       req.Notes,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not save segment")
		return
	}
	// Best-effort attribution/freshness bump — the segment itself committed.
	_ = store.New(dbPool).TouchTrip(r.Context(), touchedBy(tripID, r))
	writeJSON(w, http.StatusCreated, toSegmentResponse(seg))
}

// updateSegmentHandler partially updates a segment. Any edit — including an
// empty {} body ("Keep" on a suggested draft) — confirms the row (auto=false),
// taking it out of the booking-drafts sync's ownership.
func updateSegmentHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	tripID := trip.ID
	segID, err := uuid.Parse(mux.Vars(r)["segmentId"])
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "segment not found")
		return
	}
	var req AddSegmentRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	mode := strings.ToLower(strings.TrimSpace(req.Mode))
	if mode != "" && !allowedSegmentModes[mode] {
		writeJSONError(w, http.StatusBadRequest, "mode must be one of: flight, train, bus, car, ferry, other")
		return
	}
	if err := validateSegmentInput(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	depart, err := parseDateParam(req.DepartDate)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "depart_date must be YYYY-MM-DD")
		return
	}
	arrive, err := parseDateParam(req.ArriveDate)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "arrive_date must be YYYY-MM-DD")
		return
	}
	// Validate the POST-STATE, not the request. UpdateSegment COALESCEs each
	// date, so a PATCH carrying only one of the pair silently keeps the other —
	// and a request-only check (which needs BOTH present) waves through
	// "arrive 08-22" onto a row that departs 08-23. The trip page renders a
	// known pair as a two-date span, so a backwards pair is not cosmetic.
	if depart.Valid != arrive.Valid {
		if cur, err := findTripSegment(r.Context(), tripID, segID); err == nil {
			if !depart.Valid {
				depart = cur.DepartDate
			}
			if !arrive.Valid {
				arrive = cur.ArriveDate
			}
		}
	}
	if depart.Valid && arrive.Valid && arrive.Time.Before(depart.Time) {
		writeJSONError(w, http.StatusBadRequest, "arrive_date must not be before depart_date")
		return
	}
	seg, err := store.New(dbPool).UpdateSegment(r.Context(), store.UpdateSegmentParams{
		Mode:        strPtrOrNil(mode),
		Origin:      req.Origin,
		Destination: req.Destination,
		DepartDate:  depart,
		ArriveDate:  arrive,
		Provider:    req.Provider,
		Url:         req.URL,
		PriceNote:   req.PriceNote,
		Notes:       req.Notes,
		Booked:      req.Booked,
		ID:          segID,
		TripID:      tripID,
	})
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "segment not found")
		return
	}
	if req.Booked != nil && *req.Booked {
		user, _ := userFromContext(r.Context())
		meta := map[string]any{"kind": "transport", "mode": seg.Mode}
		if seg.Provider != nil {
			meta["provider"] = *seg.Provider
		}
		safeGo("recordEvent", func() { recordEvent(user.ID, "saved_booking_marked_booked", &tripID, meta) })
	}
	_ = store.New(dbPool).TouchTrip(r.Context(), touchedBy(tripID, r))
	writeJSON(w, http.StatusOK, toSegmentResponse(seg))
}

func deleteSegmentHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	tripID := trip.ID
	segID, err := uuid.Parse(mux.Vars(r)["segmentId"])
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "segment not found")
		return
	}
	q := store.New(dbPool)
	// Deleting a suggested draft tombstones it (dismissed=true, key kept) so
	// the itinerary sync can't re-seed it. No TouchTrip on that path —
	// dismissing a suggestion isn't a content edit worth stamping.
	dismissed, err := q.DismissDraftSegment(r.Context(),
		store.DismissDraftSegmentParams{ID: segID, TripID: tripID})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not delete segment")
		return
	}
	if dismissed > 0 {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	rows, err := q.DeleteSegment(r.Context(),
		store.DeleteSegmentParams{ID: segID, TripID: tripID})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not delete segment")
		return
	}
	if rows == 0 {
		writeJSONError(w, http.StatusNotFound, "segment not found")
		return
	}
	_ = store.New(dbPool).TouchTrip(r.Context(), touchedBy(tripID, r))
	w.WriteHeader(http.StatusNoContent)
}
