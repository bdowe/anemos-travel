package main

import (
	"context"
	"html/template"
	"net/http"

	"github.com/google/uuid"
	"github.com/gorilla/mux"

	"travel-route-planner/store"
)

// One-click email unsubscribe. PUBLIC (no authMiddleware): the signed token in
// the path IS the capability. Both verbs do the same thing — GET is the plain
// link a human clicks in the footer (answered with a friendly HTML page), POST
// is the RFC 8058 List-Unsubscribe-Post "One-Click" flow a mail client fires
// automatically (answered 200, body ignored). Idempotent: unsubscribing an
// already-unsubscribed user still succeeds.

// ptrTrue is a reusable *bool for the SetUserEmailOptOut narg params (a nil arg
// leaves that category's flag untouched).
var ptrTrue = func() *bool { b := true; return &b }()

// applyUnsubscribe flips the opt-out flag(s) for the category. Returns false if
// the user no longer exists (deleted account) — treated as a clean 404 rather
// than leaking existence.
func applyUnsubscribe(ctx context.Context, userID uuid.UUID, category string) bool {
	q := store.New(dbPool)
	params := store.SetUserEmailOptOutParams{ID: userID}
	switch category {
	case unsubReminders:
		params.RemindersOptOut = ptrTrue
	case unsubNudges:
		params.NudgesOptOut = ptrTrue
	case unsubAll:
		params.RemindersOptOut = ptrTrue
		params.NudgesOptOut = ptrTrue
	default:
		return false
	}
	if _, err := q.SetUserEmailOptOut(ctx, params); err != nil {
		return false
	}
	return true
}

// unsubscribeCategoryLabel is the human phrase shown on the confirmation page.
func unsubscribeCategoryLabel(category string) string {
	switch category {
	case unsubReminders:
		return "trip reminders"
	case unsubNudges:
		return "weekly planning ideas"
	case unsubAll:
		return "all marketing emails"
	default:
		return "these emails"
	}
}

var unsubscribePage = template.Must(template.New("unsub").Parse(`<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Unsubscribed — Anemos</title>
<style>
  body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#f6f7f9;color:#1a1a1a;margin:0;padding:2rem;display:flex;justify-content:center}
  .card{background:#fff;max-width:32rem;width:100%;border-radius:16px;padding:2rem 2.25rem;box-shadow:0 1px 3px rgba(0,0,0,.08);margin-top:3rem}
  h1{font-size:1.35rem;margin:0 0 .75rem}
  p{line-height:1.55;color:#41474d}
  a{color:#0b6e4f;font-weight:600;text-decoration:none}
  a:hover{text-decoration:underline}
</style></head>
<body><div class="card">
  <h1>You've been unsubscribed ✓</h1>
  <p>You'll no longer receive <strong>{{.Label}}</strong> from Anemos.</p>
  <p>Changed your mind, or want to fine-tune which emails you get? Manage your
     preferences any time in <a href="{{.AppURL}}">your account settings</a>.</p>
</div></body></html>`))

func unsubscribeHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		// Nothing we can persist; still answer human-friendly, not a 500 loop.
		writeUnsubResult(w, r, "", http.StatusServiceUnavailable)
		return
	}
	token := mux.Vars(r)["token"]
	userID, category, ok := verifyUnsubscribeToken(token)
	if !ok {
		writeUnsubResult(w, r, "", http.StatusNotFound)
		return
	}
	if !applyUnsubscribe(r.Context(), userID, category) {
		// User gone (deleted account) — opaque 404, same as a bad token.
		writeUnsubResult(w, r, "", http.StatusNotFound)
		return
	}
	writeUnsubResult(w, r, category, http.StatusOK)
}

// writeUnsubResult renders the outcome: POST (one-click) callers get a terse
// text/plain body (mail clients ignore it); GET callers get the HTML page on
// success or a small HTML notice on failure.
func writeUnsubResult(w http.ResponseWriter, r *http.Request, category string, status int) {
	if r.Method == http.MethodPost {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(status)
		if status == http.StatusOK {
			w.Write([]byte("unsubscribed"))
		} else {
			w.Write([]byte("could not unsubscribe"))
		}
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if status != http.StatusOK {
		w.WriteHeader(status)
		w.Write([]byte("<!doctype html><html><body style=\"font-family:system-ui;padding:2rem\">" +
			"<h2>This unsubscribe link is invalid or expired</h2>" +
			"<p>Manage your email preferences in your account settings instead.</p></body></html>"))
		return
	}
	// 200 is implicit on first write; render the friendly page.
	unsubscribePage.Execute(w, struct {
		Label  string
		AppURL string
	}{
		Label:  unsubscribeCategoryLabel(category),
		AppURL: publicAppURL(),
	})
}
