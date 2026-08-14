package main

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// insertTestNotification writes one notification row directly (bypassing the
// checker) and returns it.
func insertTestNotification(t *testing.T, userID uuid.UUID, typ string, payload map[string]any, tripID *uuid.UUID) store.Notification {
	t.Helper()
	b, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	var tid pgtype.UUID
	if tripID != nil {
		tid = pgtype.UUID{Bytes: *tripID, Valid: true}
	}
	n, err := store.New(dbPool).InsertNotification(context.Background(), store.InsertNotificationParams{
		UserID: userID, Type: typ, Payload: b, TripID: tid,
	})
	if err != nil {
		t.Fatalf("insert notification: %v", err)
	}
	return n
}

func ageNotification(t *testing.T, id uuid.UUID, by time.Duration) {
	t.Helper()
	if _, err := dbPool.Exec(context.Background(),
		`UPDATE notifications SET created_at = created_at - $2::interval WHERE id = $1`,
		id, by.String()); err != nil {
		t.Fatalf("age notification: %v", err)
	}
}

func decodeNotifList(t *testing.T, body []byte) []map[string]any {
	t.Helper()
	var out []map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatalf("decode notification list %q: %v", body, err)
	}
	return out
}

func notifUnreadCount(t *testing.T, token string) float64 {
	t.Helper()
	rec := doJSON(t, "GET", "/api/v1/notifications/unread-count", token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("unread-count = %d: %s", rec.Code, rec.Body.String())
	}
	n, ok := decode(t, rec)["count"].(float64)
	if !ok {
		t.Fatalf("unread-count body wrong: %s", rec.Body.String())
	}
	return n
}

func TestNotificationsListReadAndIsolation(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "notif-owner@example.com")
	_, otherToken := createTestUser(t, "notif-other@example.com")

	older := insertTestNotification(t, owner.ID, "price_drop", map[string]any{
		"origin": "BOS", "destination": "CDG", "price": 450.0, "currency": "USD",
	}, nil)
	ageNotification(t, older.ID, time.Hour)
	// A second, different type proves the feed is type-agnostic.
	insertTestNotification(t, owner.ID, "trip_reminder", map[string]any{
		"title": "Trip to Paris starts in 3 days",
	}, nil)

	list := doJSON(t, "GET", "/api/v1/notifications", ownerToken, nil)
	if list.Code != http.StatusOK {
		t.Fatalf("list = %d: %s", list.Code, list.Body.String())
	}
	notifs := decodeNotifList(t, list.Body.Bytes())
	if len(notifs) != 2 {
		t.Fatalf("notifications = %d, want 2: %s", len(notifs), list.Body.String())
	}
	// Newest-first: the un-aged trip_reminder leads.
	if notifs[0]["type"] != "trip_reminder" || notifs[1]["type"] != "price_drop" {
		t.Fatalf("not newest-first / wrong types: %s", list.Body.String())
	}
	// Payload is echoed verbatim as a typed object.
	pd, ok := notifs[1]["payload"].(map[string]any)
	if !ok || pd["origin"] != "BOS" || pd["price"] != 450.0 {
		t.Fatalf("price_drop payload wrong: %v", notifs[1]["payload"])
	}
	if notifs[0]["read_at"] != nil {
		t.Fatalf("fresh notification must be unread: %v", notifs[0])
	}

	limited := doJSON(t, "GET", "/api/v1/notifications?limit=1", ownerToken, nil)
	if got := decodeNotifList(t, limited.Body.Bytes()); len(got) != 1 || got[0]["type"] != "trip_reminder" {
		t.Fatalf("limit=1 wrong: %s", limited.Body.String())
	}

	if n := notifUnreadCount(t, ownerToken); n != 2 {
		t.Fatalf("owner unread = %v, want 2", n)
	}

	// Isolation: the other user sees nothing and cannot mark the owner's read.
	otherList := doJSON(t, "GET", "/api/v1/notifications", otherToken, nil)
	if got := decodeNotifList(t, otherList.Body.Bytes()); len(got) != 0 {
		t.Fatalf("cross-user list leaked %d notifications", len(got))
	}
	if n := notifUnreadCount(t, otherToken); n != 0 {
		t.Fatalf("cross-user unread = %v, want 0", n)
	}
	if rec := doJSON(t, "POST", "/api/v1/notifications/read", otherToken, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("other mark-read = %d, want 204", rec.Code)
	}
	if n := notifUnreadCount(t, ownerToken); n != 2 {
		t.Fatalf("cross-user mark-read affected owner: unread = %v, want 2", n)
	}

	// Mark-all-read clears the badge and stamps read_at.
	if rec := doJSON(t, "POST", "/api/v1/notifications/read", ownerToken, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("mark-read = %d, want 204", rec.Code)
	}
	if n := notifUnreadCount(t, ownerToken); n != 0 {
		t.Fatalf("unread after mark-read = %v, want 0", n)
	}
	after := decodeNotifList(t, doJSON(t, "GET", "/api/v1/notifications", ownerToken, nil).Body.Bytes())
	for _, nn := range after {
		if nn["read_at"] == nil {
			t.Fatalf("notification still unread after mark-all: %v", nn)
		}
	}
	// Idempotent: nothing unread is still 204.
	if rec := doJSON(t, "POST", "/api/v1/notifications/read", ownerToken, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("second mark-read = %d, want 204", rec.Code)
	}

	// Anonymous callers are rejected across the surface.
	for _, probe := range []struct{ method, path string }{
		{"GET", "/api/v1/notifications"},
		{"POST", "/api/v1/notifications/read"},
		{"GET", "/api/v1/notifications/unread-count"},
	} {
		if rec := doJSON(t, probe.method, probe.path, "", nil); rec.Code != http.StatusUnauthorized {
			t.Fatalf("anonymous %s %s = %d, want 401", probe.method, probe.path, rec.Code)
		}
	}
}

// readNotificationAgo stamps a row as read `by` ago — the sibling of
// ageNotification for the retention prune's axis (read_at, not created_at).
func readNotificationAgo(t *testing.T, id uuid.UUID, by time.Duration) {
	t.Helper()
	if _, err := dbPool.Exec(context.Background(),
		`UPDATE notifications SET read_at = now() - $2::interval WHERE id = $1`,
		id, by.String()); err != nil {
		t.Fatalf("stamp notification read: %v", err)
	}
}

// Clear-all deletes the caller's whole feed and nothing else: user-scoped,
// idempotent (204 even on an empty feed — no resource is named, so there is
// no 404 case), and auth-gated like its siblings.
func TestNotificationsClearAll(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "notif-clear-owner@example.com")
	other, otherToken := createTestUser(t, "notif-clear-other@example.com")

	read := insertTestNotification(t, owner.ID, "price_drop", map[string]any{"price": 450.0}, nil)
	readNotificationAgo(t, read.ID, time.Hour)
	insertTestNotification(t, owner.ID, "trip_reminder", map[string]any{"title": "soon"}, nil)
	insertTestNotification(t, other.ID, "weekly_nudge", map[string]any{"reason": "resume_planning"}, nil)

	// The other user's clear empties only their own feed.
	if rec := doJSON(t, "DELETE", "/api/v1/notifications", otherToken, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("other clear = %d, want 204: %s", rec.Code, rec.Body.String())
	}
	if got := decodeNotifList(t, doJSON(t, "GET", "/api/v1/notifications", otherToken, nil).Body.Bytes()); len(got) != 0 {
		t.Fatalf("other feed after own clear = %d rows, want 0", len(got))
	}
	if got := decodeNotifList(t, doJSON(t, "GET", "/api/v1/notifications", ownerToken, nil).Body.Bytes()); len(got) != 2 {
		t.Fatalf("owner feed after other's clear = %d rows, want 2 (cross-user clear leaked)", len(got))
	}

	// The owner's clear removes read and unread rows alike.
	if rec := doJSON(t, "DELETE", "/api/v1/notifications", ownerToken, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("owner clear = %d, want 204: %s", rec.Code, rec.Body.String())
	}
	if got := decodeNotifList(t, doJSON(t, "GET", "/api/v1/notifications", ownerToken, nil).Body.Bytes()); len(got) != 0 {
		t.Fatalf("owner feed after clear = %d rows, want 0", len(got))
	}
	if n := notifUnreadCount(t, ownerToken); n != 0 {
		t.Fatalf("unread after clear = %v, want 0", n)
	}

	// Idempotent: clearing an already-empty feed is a success, not a 404.
	if rec := doJSON(t, "DELETE", "/api/v1/notifications", ownerToken, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("second clear = %d, want 204: %s", rec.Code, rec.Body.String())
	}

	if rec := doJSON(t, "DELETE", "/api/v1/notifications", "", nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous clear = %d, want 401", rec.Code)
	}
}

// The retention prune expires READ rows 45 days after read_at and never
// touches unread rows, however old. Runs through janitorTick itself so the
// wiring (not just the query) is pinned — this is the first janitor test.
func TestJanitorPrunesOldReadNotifications(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "notif-prune@example.com")

	expired := insertTestNotification(t, owner.ID, "price_drop", map[string]any{"price": 1.0}, nil)
	readNotificationAgo(t, expired.ID, 46*24*time.Hour)
	readRecent := insertTestNotification(t, owner.ID, "trip_reminder", map[string]any{"title": "kept"}, nil)
	readNotificationAgo(t, readRecent.ID, 10*24*time.Hour)
	// Unread rows never expire — even one far older than the read cutoff.
	unreadOld := insertTestNotification(t, owner.ID, "weekly_nudge", map[string]any{"reason": "resume_planning"}, nil)
	ageNotification(t, unreadOld.ID, 200*24*time.Hour)
	unreadFresh := insertTestNotification(t, owner.ID, "share_joined", map[string]any{"joiner_name": "Ana"}, nil)

	janitorTick(context.Background())

	after := decodeNotifList(t, doJSON(t, "GET", "/api/v1/notifications", ownerToken, nil).Body.Bytes())
	got := map[string]bool{}
	for _, n := range after {
		got[n["id"].(string)] = true
	}
	if got[expired.ID.String()] {
		t.Fatalf("read-46-days-ago row survived the prune: %v", after)
	}
	for name, id := range map[string]uuid.UUID{
		"read-10-days-ago": readRecent.ID, "unread-200-days-old": unreadOld.ID, "unread-fresh": unreadFresh.ID,
	} {
		if !got[id.String()] {
			t.Fatalf("%s row was pruned but must survive: %v", name, after)
		}
	}
	if len(after) != 3 {
		t.Fatalf("rows after prune = %d, want 3: %v", len(after), after)
	}
}

// Deleting a user cascades their notifications away (ON DELETE CASCADE).
func TestNotificationsCascadeOnUserDelete(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "notif-cascade@example.com")
	insertTestNotification(t, owner.ID, "price_drop", map[string]any{"price": 412.0}, nil)

	var before int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM notifications WHERE user_id = $1`, owner.ID).Scan(&before); err != nil || before != 1 {
		t.Fatalf("notifications before = %d (%v), want 1", before, err)
	}
	if _, err := dbPool.Exec(context.Background(), `DELETE FROM users WHERE id = $1`, owner.ID); err != nil {
		t.Fatalf("delete user: %v", err)
	}
	var after int
	if err := dbPool.QueryRow(context.Background(),
		`SELECT count(*) FROM notifications`).Scan(&after); err != nil || after != 0 {
		t.Fatalf("notifications after user delete = %d (%v), want 0", after, err)
	}
}
