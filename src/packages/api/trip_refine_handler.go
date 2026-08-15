package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"travel-route-planner/store"
)

// Trip refine conversations (specs/trip-refine-memory). One saved conversation
// per traveler per trip: the chat behind the trip-detail refine panel, so
// closing the panel — or hitting back, which used to pop the whole page —
// never loses it.
//
// Addressed by trip id and nothing else. There is deliberately no chat id in
// this table or on this wire: a refine transcript must never be resumable into
// the unbound Agent tab, where the trip binding would silently vanish and the
// agent would fall back to create_itinerary. See the 00069 migration header for
// why this is a separate table rather than a nullable column on
// plan_chat_sessions.

// TripRefineChatSummary is presence + freshness, attached to full trip views as
// `refine_chat`. It carries NO identifier — that absence is the feature.
//
// Not to be confused with TripResponse.ChatID, which is the OWNER's itinerary
// version-lineage key: different entity, different lifetime, different
// visibility (collaborators never receive ChatID; they always receive their own
// RefineChat).
type TripRefineChatSummary struct {
	MessageCount int       `json:"message_count"`
	Preview      string    `json:"preview"`
	UpdatedAt    time.Time `json:"updated_at"`
}

// TripRefineChatResponse is the full transcript (GET /trips/{id}/refine-chat).
// Messages reuse PlanChatMessage so display labels and the data-less image
// markers round-trip exactly as they do for /chats/{chatId}.
type TripRefineChatResponse struct {
	TripID       string            `json:"trip_id"`
	Summary      string            `json:"summary"`
	Messages     []PlanChatMessage `json:"messages"`
	MessageCount int               `json:"message_count"`
	UpdatedAt    time.Time         `json:"updated_at"`
}

// TripRefineChatClearedResponse states the post-state a DELETE leaves behind
// (docs/zen.md: a mutating result must state what the consumer will observe).
// RefineChat is always null; the field exists so this shape names the same
// thing TripResponse does.
type TripRefineChatClearedResponse struct {
	TripID     string                 `json:"trip_id"`
	RefineChat *TripRefineChatSummary `json:"refine_chat"`
}

// saveTripRefineSession upserts the whole transcript for one trip's refine
// conversation. Best-effort by design, exactly like savePlanChatSession: a
// failure is logged and the turn proceeds.
//
// One case is expected rather than exceptional: a trip deleted between the
// pre-stream authorization check and this deferred save fails the trip_id
// foreign key. The turn is already over and its edits are already gone with the
// trip, so the log line is the whole response.
func saveTripRefineSession(ctx context.Context, uid, tripID uuid.UUID, summary string, msgs []PlanChatMessage) {
	if dbPool == nil || len(msgs) == 0 {
		return
	}
	payload, _, preview, err := planTranscriptFields(msgs)
	if err != nil {
		log.Printf("failed to marshal refine session for trip %s: %v", tripID, err)
		return
	}
	if err := store.New(dbPool).UpsertTripRefineSession(ctx, store.UpsertTripRefineSessionParams{
		UserID:       uid,
		TripID:       tripID,
		Preview:      preview,
		Summary:      summary,
		Messages:     payload,
		MessageCount: int32(len(msgs)),
	}); err != nil {
		log.Printf("failed to persist refine session for trip %s: %v", tripID, err)
	}
}

// tripRefineChatSummary reads presence + freshness for one caller and trip.
// Returns nil when there is no conversation — an absence, not an error.
func tripRefineChatSummary(ctx context.Context, q *store.Queries, uid, tripID uuid.UUID) (*TripRefineChatSummary, error) {
	row, err := q.GetTripRefineSessionSummary(ctx, store.GetTripRefineSessionSummaryParams{
		UserID: uid, TripID: tripID,
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return &TripRefineChatSummary{
		MessageCount: int(row.MessageCount),
		Preview:      row.Preview,
		UpdatedAt:    row.UpdatedAt,
	}, nil
}

// getTripRefineChatHandler is GET /trips/{id}/refine-chat: the caller's own
// saved conversation about this trip, in full.
//
// editableTrip, not viewableTrip: only someone who may edit a trip can hold a
// refine conversation about it, so a downgraded or removed collaborator gets
// the same 404 as a stranger with no extra check. "No conversation", "no trip"
// and "not yours" are deliberately one answer.
func getTripRefineChatHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	row, err := store.New(dbPool).GetTripRefineSession(r.Context(),
		store.GetTripRefineSessionParams{UserID: user.ID, TripID: trip.ID})
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "conversation not found")
		return
	}
	var msgs []PlanChatMessage
	if err := json.Unmarshal(row.Messages, &msgs); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load the conversation")
		return
	}
	writeJSON(w, http.StatusOK, TripRefineChatResponse{
		TripID:       trip.ID.String(),
		Summary:      row.Summary,
		Messages:     msgs,
		MessageCount: int(row.MessageCount),
		UpdatedAt:    row.UpdatedAt,
	})
}

// deleteTripRefineChatHandler is DELETE /trips/{id}/refine-chat — the "New
// chat" action.
//
// Deliberate divergence from its sibling DELETE /chats/{chatId}, which 404s
// when no row existed: this one answers 200 with the post-state whether or not
// there was a conversation. Clearing state the caller cannot observe beforehand
// must be idempotent — "New chat" tapped on a conversation that never completed
// a turn is not an error, and a client that retries after a dropped response
// must not see one either. (docs/zen.md: divergence gets a comment, a decision
// record in specs/trip-refine-memory/plan.md, and a test —
// TestDeleteTripRefineChatIsIdempotent.)
func deleteTripRefineChatHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	if _, err := store.New(dbPool).DeleteTripRefineSession(r.Context(),
		store.DeleteTripRefineSessionParams{UserID: user.ID, TripID: trip.ID}); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not clear the conversation")
		return
	}
	writeJSON(w, http.StatusOK, TripRefineChatClearedResponse{TripID: trip.ID.String()})
}
