package main

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// Generalized notifications read API (Wave 16): the notification-center spine.
// Type-agnostic: each row carries a `type` discriminator and a `payload` JSON
// bag the client switches on. Writers: the re-engagement checkers (trip
// reminders, weekly nudge), collab/share activity (notifications_writer.go),
// and the ops self-check monitor (admin-only rows). This file only reads and
// marks. All routes require auth.

const (
	defaultNotificationsLimit = 50
	maxNotificationsLimit     = 200
)

// NotificationResponse is one feed row. Payload is echoed verbatim as a typed
// JSON object the client switches on by `type` — the server never reshapes it.
type NotificationResponse struct {
	ID        string          `json:"id"`
	Type      string          `json:"type"`
	Payload   json.RawMessage `json:"payload"`
	TripID    *string         `json:"trip_id"`
	ReadAt    *string         `json:"read_at"`
	CreatedAt string          `json:"created_at"`
}

func toNotificationResponse(row store.Notification) NotificationResponse {
	resp := NotificationResponse{
		ID:        row.ID.String(),
		Type:      row.Type,
		Payload:   json.RawMessage(row.Payload),
		CreatedAt: row.CreatedAt.Format(time.RFC3339),
	}
	// jsonb NOT NULL DEFAULT '{}' means Payload is never nil, but guard anyway
	// so a client always receives a valid object.
	if len(resp.Payload) == 0 {
		resp.Payload = json.RawMessage(`{}`)
	}
	if row.TripID.Valid {
		s := uuid.UUID(row.TripID.Bytes).String()
		resp.TripID = &s
	}
	if row.ReadAt.Valid {
		s := row.ReadAt.Time.Format(time.RFC3339)
		resp.ReadAt = &s
	}
	return resp
}

func listNotificationsHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	user, _ := userFromContext(r.Context())

	limit := defaultNotificationsLimit
	if l, err := strconv.Atoi(r.URL.Query().Get("limit")); err == nil && l > 0 {
		limit = min(l, maxNotificationsLimit)
	}
	rows, err := store.New(dbPool).ListNotificationsByUser(r.Context(), store.ListNotificationsByUserParams{
		UserID: user.ID, Limit: int32(limit),
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load notifications")
		return
	}
	out := make([]NotificationResponse, 0, len(rows))
	for _, row := range rows {
		out = append(out, toNotificationResponse(row))
	}
	writeJSON(w, http.StatusOK, out)
}

func markNotificationsReadHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	user, _ := userFromContext(r.Context())
	if _, err := store.New(dbPool).MarkNotificationsRead(r.Context(), user.ID); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not mark notifications read")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func unreadNotificationsCountHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	user, _ := userFromContext(r.Context())
	n, err := store.New(dbPool).CountUnreadNotifications(r.Context(), user.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not count unread notifications")
		return
	}
	writeJSON(w, http.StatusOK, map[string]int64{"count": n})
}
