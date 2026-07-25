package main

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/mux"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// Email invites for co-planning (specs/invite-by-email). Unlike share links
// (anonymous, multi-use), an invite is minted for one address, single-use,
// TTL'd, and individually revocable; only the token's hash is stored because
// the plaintext transits email. Redemption does NOT require the redeemer's
// account email to match the invited address — with SSO they routinely
// differ — the token itself is the capability, strictly tighter than the
// editor share links that already exist.

const inviteTokenTTL = 7 * 24 * time.Hour

// maxPendingInvites caps live invites per lineage — an abuse brake on the
// email-sending path, far above any real co-planning group.
const maxPendingInvites = 20

type InviteResponse struct {
	ID        string    `json:"id"`
	Email     string    `json:"email"`
	Role      string    `json:"role"`
	CreatedAt time.Time `json:"created_at"`
	ExpiresAt time.Time `json:"expires_at"`
}

func toInviteResponse(in store.TripInvite) InviteResponse {
	return InviteResponse{
		ID:        in.ID.String(),
		Email:     in.Email,
		Role:      in.Role,
		CreatedAt: in.CreatedAt,
		ExpiresAt: in.ExpiresAt,
	}
}

// createTripInviteHandler mints an invite and emails the link. Owner-only.
// The response is identical whether or not the address has an account — no
// enumeration — and never contains the token.
func createTripInviteHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	id, ok := tripIDFromPath(r)
	if !ok {
		writeJSONError(w, http.StatusNotFound, "trip not found")
		return
	}
	var req struct {
		Email string `json:"email"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	email := strings.ToLower(strings.TrimSpace(req.Email))
	if !validateEmail(email) {
		writeJSONError(w, http.StatusBadRequest, "a valid email is required")
		return
	}
	if email == user.Email {
		writeJSONError(w, http.StatusUnprocessableEntity, "you already have access to this trip")
		return
	}

	q := store.New(dbPool)
	trip, err := q.GetTripByIDAndOwner(r.Context(), store.GetTripByIDAndOwnerParams{ID: id, UserID: user.ID})
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "trip not found")
		return
	}
	chatID, err := shareChatID(r, trip)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not create invite")
		return
	}
	pending, err := q.CountPendingInvitesByOwnerAndChat(r.Context(), store.CountPendingInvitesByOwnerAndChatParams{
		OwnerID: user.ID, ChatID: chatID,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not create invite")
		return
	}
	if pending >= maxPendingInvites {
		writeJSONError(w, http.StatusUnprocessableEntity, "too many pending invites on this trip — revoke some first")
		return
	}

	// Re-invite: void any live invite for this address, then mint fresh.
	if _, err := q.RevokePendingInviteByEmail(r.Context(), store.RevokePendingInviteByEmailParams{
		OwnerID: user.ID, ChatID: chatID, Email: email,
	}); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not create invite")
		return
	}
	token, err := generateSessionToken()
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not create invite")
		return
	}
	invite, err := q.CreateTripInvite(r.Context(), store.CreateTripInviteParams{
		ChatID:    chatID,
		OwnerID:   user.ID,
		Email:     email,
		Role:      "editor",
		TokenHash: hashEmailToken(token),
		ExpiresAt: time.Now().Add(inviteTokenTTL),
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not create invite")
		return
	}
	// The invite is read by the RECIPIENT, so their stored language wins when
	// they already have an account. Strangers have no stored locale, so the
	// inviter's request locale is the only signal there is. Resolved here (in
	// the request) rather than in the goroutine, which has no context; the
	// lookup can't leak account existence because the response is unchanged.
	inviteLocale := requestLocale(r.Context())
	if recipient, err := q.GetUserByEmail(r.Context(), email); err == nil {
		inviteLocale = localeOrDefault(recipient.Locale)
	}
	// Fire-and-forget like sendVerificationEmail; degraded SMTP logs the
	// body, and a send failure never fails the request.
	safeGo("sendInviteEmail", func() { sendInviteEmail(user, invite.Email, token, trip.Title, inviteLocale) })
	safeGo("recordEvent", func() { recordEvent(user.ID, "invite_sent", &trip.ID, nil) })
	writeJSON(w, http.StatusCreated, toInviteResponse(invite))
}

// sendInviteEmail composes and sends the invite link, in the recipient's
// language.
func sendInviteEmail(owner store.User, to, token, tripTitle, locale string) {
	ownerName := tr(locale, "email.invite.default_sender")
	if owner.DisplayName != nil && *owner.DisplayName != "" {
		ownerName = *owner.DisplayName
	}
	link := publicAppURL("invite/", token)
	body := tr(locale, "email.invite.body", ownerName, tripTitle, link)
	if err := emailService.Send(to, tr(locale, "email.invite.subject", ownerName, tripTitle), body); err != nil {
		log.Printf("invite email: send to %s failed: %v", maskEmail(to), err)
	}
}

// listTripInvitesHandler returns the trip's pending invites. Owner-only.
func listTripInvitesHandler(w http.ResponseWriter, r *http.Request) {
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
	out := []InviteResponse{}
	if trip.ChatID != nil {
		rows, err := q.ListPendingInvitesByOwnerAndChat(r.Context(), store.ListPendingInvitesByOwnerAndChatParams{
			OwnerID: user.ID, ChatID: *trip.ChatID,
		})
		if err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not load invites")
			return
		}
		for _, row := range rows {
			out = append(out, toInviteResponse(row))
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// revokeTripInviteHandler voids one pending invite. Owner-only (the query's
// WHERE owner_id enforces it; wrong owner or dead invite is the same 404).
func revokeTripInviteHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	inviteID, err := uuid.Parse(mux.Vars(r)["inviteId"])
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "invite not found")
		return
	}
	rows, err := store.New(dbPool).RevokeTripInviteByID(r.Context(), store.RevokeTripInviteByIDParams{
		ID: inviteID, OwnerID: user.ID,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not revoke invite")
		return
	}
	if rows == 0 {
		writeJSONError(w, http.StatusNotFound, "invite not found")
		return
	}
	safeGo("recordEvent", func() { recordEvent(user.ID, "invite_revoked", nil, nil) })
	w.WriteHeader(http.StatusNoContent)
}

// resolveInvite turns a live invite token into (invite, latest trip). The
// same undistinguished 404 posture as resolveShare.
func resolveInvite(r *http.Request) (store.TripInvite, store.Trip, bool) {
	token := mux.Vars(r)["token"]
	q := store.New(dbPool)
	invite, err := q.GetValidInviteByTokenHash(r.Context(), hashEmailToken(token))
	if err != nil {
		return store.TripInvite{}, store.Trip{}, false
	}
	trip, err := q.GetLatestTripByOwnerAndChat(r.Context(), store.GetLatestTripByOwnerAndChatParams{
		UserID: invite.OwnerID, ChatID: &invite.ChatID,
	})
	if err != nil {
		return store.TripInvite{}, store.Trip{}, false
	}
	return invite, trip, true
}

// invitePreviewHandler is the public read behind the emailed link — the same
// stripped shape as sharedTripHandler, so the client reuses its screen.
func invitePreviewHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	invite, trip, ok := resolveInvite(r)
	if !ok {
		writeJSONError(w, http.StatusNotFound, "invite not found")
		return
	}
	resp, err := buildSharedTripResponse(r.Context(), invite.OwnerID, trip, invite.Role)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load shared trip")
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

// acceptInviteHandler redeems the invite into editor membership. Single-use
// (race-safe via AcceptTripInvite's conditional update); a repeat accept by
// the same user stays a success, anyone else gets the 404 posture. The owner
// opening their own invite is a no-op success that leaves the token live.
func acceptInviteHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	token := mux.Vars(r)["token"]
	q := store.New(dbPool)
	invite, err := q.GetInviteByTokenHash(r.Context(), hashEmailToken(token))
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "invite not found")
		return
	}
	trip, err := q.GetLatestTripByOwnerAndChat(r.Context(), store.GetLatestTripByOwnerAndChatParams{
		UserID: invite.OwnerID, ChatID: &invite.ChatID,
	})
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "invite not found")
		return
	}
	if trip.UserID == user.ID {
		writeJSON(w, http.StatusOK, JoinSharedTripResponse{TripID: trip.ID.String(), Access: "owner"})
		return
	}
	// Idempotent retry: the redeemer re-opening the link after accepting.
	if invite.AcceptedAt.Valid {
		if invite.AcceptedBy.Valid && invite.AcceptedBy.Bytes == user.ID {
			writeJSON(w, http.StatusOK, JoinSharedTripResponse{TripID: trip.ID.String(), Access: "editor"})
			return
		}
		writeJSONError(w, http.StatusNotFound, "invite not found")
		return
	}

	ctx := r.Context()
	tx, err := dbPool.Begin(ctx)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not join trip")
		return
	}
	defer tx.Rollback(ctx)
	qtx := store.New(tx)
	rows, err := qtx.AcceptTripInvite(ctx, store.AcceptTripInviteParams{
		ID: invite.ID, AcceptedBy: pgtype.UUID{Bytes: user.ID, Valid: true},
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not join trip")
		return
	}
	if rows == 0 {
		// Revoked, expired, or lost the single-use race.
		writeJSONError(w, http.StatusNotFound, "invite not found")
		return
	}
	if _, err := qtx.CreateTripCollaborator(ctx, store.CreateTripCollaboratorParams{
		ChatID: invite.ChatID, OwnerID: invite.OwnerID, UserID: user.ID, Role: "editor",
	}); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not join trip")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not join trip")
		return
	}
	safeGo("recordEvent", func() {
		recordEvent(user.ID, "invite_accepted", &trip.ID, map[string]any{
			"owner_id": invite.OwnerID.String(),
		})
	})
	// Tell the owner their invite was redeemed (in-app only; one-time event, no
	// throttle). Best-effort, like the analytics write above.
	safeGo("notifyInviteAccepted", func() { notifyInviteAccepted(invite.OwnerID, user, trip) })
	writeJSON(w, http.StatusOK, JoinSharedTripResponse{TripID: trip.ID.String(), Access: "editor"})
}
