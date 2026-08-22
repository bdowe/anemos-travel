package main

import (
	"encoding/json"
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/mux"

	"travel-route-planner/store"
)

// Generalized notifications API (Wave 16): the notification-center spine.
// Type-agnostic: each row carries a `type` discriminator and a `payload` JSON
// bag the client switches on. Writers: the re-engagement checkers (trip
// reminders, weekly nudge), collab/share activity (notifications_writer.go),
// and the ops self-check monitor (admin-only rows). This file reads, marks,
// and deletes — wholesale (clear-all) or one row at a time. All routes require
// auth.

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

// clearNotificationsHandler deletes every notification belonging to the
// caller ("Clear all"). It mirrors mark-all-read, not the single-resource
// deletes (which 404 on zero rows): clear-all names no resource, ownership is
// structural in the query's WHERE clause, and an empty feed is a valid
// pre-state — so the result is an idempotent 204 either way. The client
// observes post-state by refetching the list and unread count.
func clearNotificationsHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	user, _ := userFromContext(r.Context())
	if _, err := store.New(dbPool).DeleteNotificationsByUser(r.Context(), user.ID); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not clear notifications")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// deleteNotificationHandler dismisses ONE notification. The single-resource
// counterpart to clear-all, and it takes the opposite convention deliberately:
// this one names a resource, so zero affected rows means the named thing was
// not the caller's to delete and the answer is 404, matching the other
// single-resource deletes in this API.
//
// The 404 is the same for "no such id", "someone else's row", and "already
// gone", because ownership lives in the query's WHERE clause — there is no
// fetch-then-check that could tell those apart, and no response that leaks
// which notification ids exist.
//
// No confirmation gate, unlike clear-all: dismissing one row of an ephemeral
// signal is not the same act as emptying the feed, and a dialog per row would
// make the affordance unusable. The client refetches the feed on 204 and leaves
// the row in place on any failure, so a failed dismiss never reads as a
// successful one.
func deleteNotificationHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	user, _ := userFromContext(r.Context())
	// An unparseable id is a 404 rather than a 400: it names no notification,
	// which is the same outcome as naming one that isn't yours (the
	// deleteAccommodationHandler convention).
	id, err := uuid.Parse(mux.Vars(r)["id"])
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "notification not found")
		return
	}
	n, err := store.New(dbPool).DeleteNotification(r.Context(), store.DeleteNotificationParams{
		ID: id, UserID: user.ID,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not delete notification")
		return
	}
	if n == 0 {
		writeJSONError(w, http.StatusNotFound, "notification not found")
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
