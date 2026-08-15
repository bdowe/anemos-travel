package main

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// DraftStay / DraftTransport are the itinerary-derived booking drafts sent by
// the client's sync (the same client pass that derives the booking-todo
// checklist). They land in accommodations / trip_segments as auto=true rows.
type DraftStay struct {
	AutoKey  string  `json:"auto_key"` // stay:<city>
	Name     string  `json:"name"`
	Address  *string `json:"address"`
	CheckIn  *string `json:"check_in"`
	CheckOut *string `json:"check_out"`
}

// DraftTransport's auto_key is the ONE place the endpoint-labelled
// `transport:<a>>><b>` grammar still doubles as an identity (booking_todos
// moved off it in 00064). Deliberately frozen rather than canonicalized: no
// current client posts to this endpoint, so surviving rows are legacy and are
// never re-derived — which means they can never be pruned by a label change
// either. _computeGroupedBookings matches them on the CITY side of the key
// (endsWith '>><city>' / startsWith 'transport:<city>>>') with an origin/
// destination equality fallback, so a stale endpoint label costs nothing.
// If this endpoint is ever revived, canonicalize it through
// classifyDerivedTodos instead of growing a second grammar.
type DraftTransport struct {
	AutoKey     string  `json:"auto_key"` // transport:<a>>><b>
	Mode        string  `json:"mode"`
	Origin      *string `json:"origin"`
	Destination *string `json:"destination"`
	DepartDate  *string `json:"depart_date"`
}

type SyncBookingDraftsRequest struct {
	Stays      []DraftStay      `json:"stays"`
	Transports []DraftTransport `json:"transports"`
}

// syncBookingDraftsHandler upserts the client's itinerary-derived draft stays
// and transport segments and prunes drafts whose legs no longer exist.
// Confirmed rows (auto=false) and dismissed tombstones are never modified by
// the upsert; the prune only ever deletes auto=true rows. Returns the fresh
// (dismissed-filtered) lists.
// (Like syncBookingTodosHandler, this must NEVER TouchTrip: it runs on every
// trip load and would otherwise stamp freshness/attribution passively.)
func syncBookingDraftsHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	tripID := trip.ID
	var req SyncBookingDraftsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}

	q := store.New(dbPool)

	stayKeys := make([]string, 0, len(req.Stays))
	for _, s := range req.Stays {
		if !strings.HasPrefix(s.AutoKey, "stay:") || strings.TrimSpace(s.Name) == "" {
			writeJSONError(w, http.StatusBadRequest, "each stay needs a stay: auto_key and a name")
			return
		}
		checkIn, err := parseDateParam(s.CheckIn)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, "check_in must be YYYY-MM-DD")
			return
		}
		checkOut, err := parseDateParam(s.CheckOut)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, "check_out must be YYYY-MM-DD")
			return
		}
		key := s.AutoKey
		if _, err := q.UpsertDraftAccommodation(r.Context(), store.UpsertDraftAccommodationParams{
			TripID:   tripID,
			Name:     strings.TrimSpace(s.Name),
			Address:  s.Address,
			CheckIn:  checkIn,
			CheckOut: checkOut,
			AutoKey:  &key,
		}); err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not save draft stay")
			return
		}
		stayKeys = append(stayKeys, key)
	}

	transportKeys := make([]string, 0, len(req.Transports))
	for _, t := range req.Transports {
		mode := strings.ToLower(strings.TrimSpace(t.Mode))
		if !strings.HasPrefix(t.AutoKey, "transport:") || !allowedSegmentModes[mode] {
			writeJSONError(w, http.StatusBadRequest, "each transport needs a transport: auto_key and a valid mode")
			return
		}
		depart, err := parseDateParam(t.DepartDate)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, "depart_date must be YYYY-MM-DD")
			return
		}
		key := t.AutoKey
		if _, err := q.UpsertDraftSegment(r.Context(), store.UpsertDraftSegmentParams{
			TripID:      tripID,
			Mode:        mode,
			Origin:      t.Origin,
			Destination: t.Destination,
			DepartDate:  depart,
			AutoKey:     &key,
		}); err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not save draft transport")
			return
		}
		transportKeys = append(transportKeys, key)
	}

	if _, err := q.DeleteStaleDraftAccommodations(r.Context(), store.DeleteStaleDraftAccommodationsParams{
		TripID: tripID,
		Keys:   stayKeys,
	}); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not prune draft stays")
		return
	}
	if _, err := q.DeleteStaleDraftSegments(r.Context(), store.DeleteStaleDraftSegmentsParams{
		TripID: tripID,
		Keys:   transportKeys,
	}); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not prune draft transports")
		return
	}

	accommodations, err := q.ListAccommodationsByTrip(r.Context(), tripID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load accommodations")
		return
	}
	segments, err := q.ListSegmentsByTrip(r.Context(), tripID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load segments")
		return
	}
	accResp := make([]AccommodationResponse, 0, len(accommodations))
	for _, a := range accommodations {
		accResp = append(accResp, toAccommodationResponse(a))
	}
	segResp := make([]SegmentResponse, 0, len(segments))
	for _, s := range segments {
		segResp = append(segResp, toSegmentResponse(s))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"accommodations": accResp,
		"segments":       segResp,
	})
}

type ReorderBookingsRequest struct {
	StayIDs    []string `json:"stay_ids"`
	SegmentIDs []string `json:"segment_ids"`
}

// orderedIDSubset parses ids and checks each exists in the trip's row set with
// no duplicates. ok=false means the client's list is stale (or malformed) and
// the caller should 409.
func orderedIDSubset(ids []string, existing map[uuid.UUID]bool) ([]uuid.UUID, bool) {
	ordered := make([]uuid.UUID, 0, len(ids))
	seen := make(map[uuid.UUID]bool, len(ids))
	for _, raw := range ids {
		id, err := uuid.Parse(raw)
		if err != nil || !existing[id] || seen[id] {
			return nil, false
		}
		seen[id] = true
		ordered = append(ordered, id)
	}
	return ordered, true
}

// reorderBookingsHandler reassigns positions 0..n-1 per bookings-hub group
// (stays, segments) to the submitted ids. A drag sends only the group that
// moved; the other array stays empty. Subsets are fine: unsubmitted rows keep
// their position (new rows default to 9999 and sort by date at the tail).
// Draft (auto) rows are orderable too — the drafts sync upsert never touches
// position, so the order set here survives every trip load; a drag racing a
// concurrent prune fails the exists check below and 409s.
func reorderBookingsHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	tripID := trip.ID
	var req ReorderBookingsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if len(req.StayIDs) == 0 && len(req.SegmentIDs) == 0 {
		writeJSONError(w, http.StatusBadRequest, "stay_ids or segment_ids is required")
		return
	}

	ctx := r.Context()
	tx, err := dbPool.Begin(ctx)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not reorder bookings")
		return
	}
	defer tx.Rollback(ctx)
	q := store.New(tx)

	// Serialize against concurrent syncs/reorders so the stale-set 409 stays
	// reliable between the reads below and commit.
	if _, err := q.GetTripForUpdate(ctx, tripID); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not reorder bookings")
		return
	}
	if len(req.StayIDs) > 0 {
		stays, err := q.ListAccommodationsByTrip(ctx, tripID)
		if err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not load bookings")
			return
		}
		existing := make(map[uuid.UUID]bool, len(stays))
		for _, a := range stays {
			existing[a.ID] = true
		}
		ordered, ok := orderedIDSubset(req.StayIDs, existing)
		if !ok {
			writeJSONError(w, http.StatusConflict, "bookings list is out of date; reload the trip")
			return
		}
		for pos, id := range ordered {
			if err := q.SetAccommodationPosition(ctx, store.SetAccommodationPositionParams{
				ID: id, TripID: tripID, Position: int32(pos),
			}); err != nil {
				writeJSONError(w, http.StatusInternalServerError, "could not reorder bookings")
				return
			}
		}
	}
	if len(req.SegmentIDs) > 0 {
		segments, err := q.ListSegmentsByTrip(ctx, tripID)
		if err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not load bookings")
			return
		}
		existing := make(map[uuid.UUID]bool, len(segments))
		for _, s := range segments {
			existing[s.ID] = true
		}
		ordered, ok := orderedIDSubset(req.SegmentIDs, existing)
		if !ok {
			writeJSONError(w, http.StatusConflict, "bookings list is out of date; reload the trip")
			return
		}
		for pos, id := range ordered {
			if err := q.SetSegmentPosition(ctx, store.SetSegmentPositionParams{
				ID: id, TripID: tripID, Position: int32(pos),
			}); err != nil {
				writeJSONError(w, http.StatusInternalServerError, "could not reorder bookings")
				return
			}
		}
	}
	if err := q.TouchTrip(ctx, touchedBy(tripID, r)); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not reorder bookings")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not reorder bookings")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
