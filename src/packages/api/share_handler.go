package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/mux"

	"travel-route-planner/store"
)

// Trip sharing: an owner mints an unguessable read-only link for a trip. The
// share binds to the trip's chat_id lineage (not one trips row) so the link
// always resolves to the latest version after agent refinements. Viewers need
// no account; a signed-in viewer can duplicate the trip into their own list.

type ShareResponse struct {
	Token     string    `json:"token"`
	Role      string    `json:"role"`
	CreatedAt time.Time `json:"created_at"`
}

type SharedTripResponse struct {
	Trip      TripResponse `json:"trip"`
	OwnerName string       `json:"owner_name"`
	// Role of the link used to open this trip: "viewer" (read-only,
	// save-a-copy) or "editor" (the client offers "Join as co-planner").
	Role string `json:"role"`
}

var allowedShareRoles = map[string]bool{"viewer": true, "editor": true}

// shareChatID returns the trip's chat lineage id, assigning one to legacy
// (NULL chat_id) trips the same way refineTripHandler does.
func shareChatID(r *http.Request, trip store.Trip) (string, error) {
	if trip.ChatID != nil {
		return *trip.ChatID, nil
	}
	token, err := generateSessionToken()
	if err != nil {
		return "", err
	}
	newID := "chat-" + token
	updated, err := store.New(dbPool).UpdateTrip(r.Context(), store.UpdateTripParams{
		ChatID: &newID, ID: trip.ID, UserID: trip.UserID,
	})
	if err != nil {
		return "", err
	}
	return *updated.ChatID, nil
}

// createShareHandler mints (or returns the existing) link for a trip.
// Optional body {"role": "viewer"|"editor"}; absent defaults to viewer.
// Idempotent per (chat lineage, role): viewer and editor links coexist.
func createShareHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	id, ok := tripIDFromPath(r)
	if !ok {
		writeJSONError(w, http.StatusNotFound, "trip not found")
		return
	}

	role := "viewer"
	// The original endpoint took no body; keep an empty/absent body valid.
	var req struct {
		Role string `json:"role"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err == nil && req.Role != "" {
		role = strings.ToLower(strings.TrimSpace(req.Role))
		if !allowedShareRoles[role] {
			writeJSONError(w, http.StatusBadRequest, "role must be 'viewer' or 'editor'")
			return
		}
	}

	q := store.New(dbPool)
	trip, err := q.GetTripByIDAndOwner(r.Context(), store.GetTripByIDAndOwnerParams{ID: id, UserID: user.ID})
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "trip not found")
		return
	}
	chatID, err := shareChatID(r, trip)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not create share link")
		return
	}
	if existing, err := q.GetActiveShareByOwnerAndChat(r.Context(), store.GetActiveShareByOwnerAndChatParams{
		OwnerID: user.ID, ChatID: chatID, Role: role,
	}); err == nil {
		writeJSON(w, http.StatusOK, ShareResponse{Token: existing.Token, Role: existing.Role, CreatedAt: existing.CreatedAt})
		return
	}
	token, err := generateSessionToken()
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not create share link")
		return
	}
	share, err := q.CreateTripShare(r.Context(), store.CreateTripShareParams{
		ChatID: chatID, OwnerID: user.ID, Token: token, Role: role,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not create share link")
		return
	}
	if role == "editor" {
		safeGo("recordEvent", func() { recordEvent(user.ID, "editor_share_created", &trip.ID, nil) })
	}
	writeJSON(w, http.StatusCreated, ShareResponse{Token: share.Token, Role: share.Role, CreatedAt: share.CreatedAt})
}

// revokeShareHandler revokes every active link for the trip's lineage.
func revokeShareHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	id, ok := tripIDFromPath(r)
	if !ok {
		writeJSONError(w, http.StatusNotFound, "trip not found")
		return
	}
	q := store.New(dbPool)
	trip, err := q.GetTripByIDAndOwner(r.Context(), store.GetTripByIDAndOwnerParams{ID: id, UserID: user.ID})
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "trip not found")
		return
	}
	if trip.ChatID == nil {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if _, err := q.RevokeSharesByOwnerAndChat(r.Context(), store.RevokeSharesByOwnerAndChatParams{
		OwnerID: user.ID, ChatID: *trip.ChatID,
	}); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not revoke share link")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// resolveShare turns a token into (share, latest trip). Revoked/unknown
// tokens and empty lineages are all a plain 404 — no distinction leaks.
func resolveShare(r *http.Request) (store.TripShare, store.Trip, bool) {
	token := mux.Vars(r)["token"]
	q := store.New(dbPool)
	share, err := q.GetActiveShareByToken(r.Context(), token)
	if err != nil {
		return store.TripShare{}, store.Trip{}, false
	}
	trip, err := q.GetLatestTripByOwnerAndChat(r.Context(), store.GetLatestTripByOwnerAndChatParams{
		UserID: share.OwnerID, ChatID: &share.ChatID,
	})
	if err != nil {
		return store.TripShare{}, store.Trip{}, false
	}
	return share, trip, true
}

// buildSharedTripResponse assembles the public shape of a shared trip:
// items/stays/segments plus owner attribution. Booking todos and all profile
// data are deliberately excluded; chat_id is stripped so the response
// carries nothing tied to the owner's sessions. Shared by the share-token
// and invite-token preview paths.
func buildSharedTripResponse(ctx context.Context, ownerID uuid.UUID, trip store.Trip, role string) (SharedTripResponse, error) {
	q := store.New(dbPool)
	items, err := q.GetItineraryItemsByTrip(ctx, trip.ID)
	if err != nil {
		return SharedTripResponse{}, err
	}
	// Confirmed rows only: suggested booking drafts are editor-facing working
	// state and never leak into the public share view.
	accommodations, err := q.ListConfirmedAccommodationsByTrip(ctx, trip.ID)
	if err != nil {
		return SharedTripResponse{}, err
	}
	segments, err := q.ListConfirmedSegmentsByTrip(ctx, trip.ID)
	if err != nil {
		return SharedTripResponse{}, err
	}
	ownerName := "A traveler"
	if owner, err := q.GetUserByID(ctx, ownerID); err == nil &&
		owner.DisplayName != nil && *owner.DisplayName != "" {
		ownerName = *owner.DisplayName
	}
	resp := toTripResponse(trip, items, accommodations, segments, nil)
	resp.Legs = tripLegsResponse(trip, items, accommodations)
	resp.ChatID = nil
	return SharedTripResponse{Trip: resp, OwnerName: ownerName, Role: role}, nil
}

// sharedTripHandler is the public, unauthenticated read of a shared trip.
func sharedTripHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	share, trip, ok := resolveShare(r)
	if !ok {
		writeJSONError(w, http.StatusNotFound, "shared trip not found")
		return
	}
	resp, err := buildSharedTripResponse(r.Context(), share.OwnerID, trip, share.Role)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load shared trip")
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

// duplicateSharedTripHandler copies the shared trip's latest version (items,
// stays, segments — attribution snapshots included, booking todos not) into a
// fresh draft lineage owned by the caller.
func duplicateSharedTripHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	_, src, ok := resolveShare(r)
	if !ok {
		writeJSONError(w, http.StatusNotFound, "shared trip not found")
		return
	}
	ctx := r.Context()
	q := store.New(dbPool)
	items, err := q.GetItineraryItemsByTrip(ctx, src.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load itinerary")
		return
	}
	// Confirmed rows only: copying drafts would turn suggestions into
	// confirmed bookings; the copy's own first sync re-seeds fresh drafts.
	accommodations, err := q.ListConfirmedAccommodationsByTrip(ctx, src.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load stays")
		return
	}
	segments, err := q.ListConfirmedSegmentsByTrip(ctx, src.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load segments")
		return
	}

	chatToken, err := generateSessionToken()
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not copy trip")
		return
	}
	newChatID := "chat-" + chatToken

	tx, err := dbPool.Begin(ctx)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not copy trip")
		return
	}
	defer tx.Rollback(ctx)
	qtx := store.New(tx)

	copyTrip, err := qtx.CreateTrip(ctx, store.CreateTripParams{
		UserID:     user.ID,
		Title:      src.Title + " (copy)",
		Status:     "draft",
		ChatID:     &newChatID,
		Summary:    src.Summary,
		TravelMode: src.TravelMode,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not copy trip")
		return
	}
	if src.StartDate.Valid || src.EndDate.Valid {
		if _, err := qtx.UpdateTrip(ctx, store.UpdateTripParams{
			StartDate: src.StartDate, EndDate: src.EndDate,
			ID: copyTrip.ID, UserID: user.ID,
		}); err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not copy trip")
			return
		}
	}
	for _, it := range items {
		if _, err := qtx.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
			TripID:                copyTrip.ID,
			Position:              it.Position,
			Name:                  it.Name,
			PlaceID:               it.PlaceID,
			Address:               it.Address,
			Latitude:              it.Latitude,
			Longitude:             it.Longitude,
			Category:              it.Category,
			TimeOfDay:             it.TimeOfDay,
			City:                  it.City,
			DayTripFrom:           it.DayTripFrom,
			Day:                   it.Day,
			LocalSourceName:       it.LocalSourceName,
			LocalRecommendationID: it.LocalRecommendationID,
		}); err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not copy trip")
			return
		}
	}
	for _, a := range accommodations {
		copied, err := qtx.CreateAccommodation(ctx, store.CreateAccommodationParams{
			TripID: copyTrip.ID, Name: a.Name, Provider: a.Provider, Url: a.Url,
			Address: a.Address, Latitude: a.Latitude, Longitude: a.Longitude,
			CheckIn: a.CheckIn, CheckOut: a.CheckOut, PriceNote: a.PriceNote,
		})
		if err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not copy trip")
			return
		}
		// Create doesn't take position (inserts default to the 9999 tail) —
		// carry the source's manual bookings-hub order onto the copy.
		if err := qtx.SetAccommodationPosition(ctx, store.SetAccommodationPositionParams{
			ID: copied.ID, TripID: copyTrip.ID, Position: a.Position,
		}); err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not copy trip")
			return
		}
	}
	for _, s := range segments {
		copied, err := qtx.CreateSegment(ctx, store.CreateSegmentParams{
			TripID: copyTrip.ID, Mode: s.Mode, Origin: s.Origin, Destination: s.Destination,
			DepartDate: s.DepartDate, ArriveDate: s.ArriveDate, Provider: s.Provider,
			Url: s.Url, PriceNote: s.PriceNote, Notes: s.Notes,
		})
		if err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not copy trip")
			return
		}
		if err := qtx.SetSegmentPosition(ctx, store.SetSegmentPositionParams{
			ID: copied.ID, TripID: copyTrip.ID, Position: s.Position,
		}); err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not copy trip")
			return
		}
	}
	if err := tx.Commit(ctx); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not copy trip")
		return
	}

	// Free-cap active_trips crossing signal (free_cap.go) — a duplicate is
	// always a fresh lineage. Synchronous but strictly fail-open: it can log,
	// never fail the request.
	recordActiveTripsCapSignal(user.ID, copyTrip.ID)

	qr := store.New(dbPool)
	final, err := qr.GetTripByIDAndOwner(ctx, store.GetTripByIDAndOwnerParams{ID: copyTrip.ID, UserID: user.ID})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load copied trip")
		return
	}
	copiedItems, err := qr.GetItineraryItemsByTrip(ctx, copyTrip.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load copied trip")
		return
	}
	writeJSON(w, http.StatusCreated, toTripResponse(final, copiedItems, nil, nil, nil))
}
