package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"runtime/debug"
	"strings"
	"time"

	"github.com/getsentry/sentry-go"
	"github.com/google/uuid"
)

const requestIDContextKey contextKey = "request_id"

// requestIDFromContext returns the request ID stamped by requestIDMiddleware,
// or "" outside a request.
func requestIDFromContext(ctx context.Context) string {
	id, _ := ctx.Value(requestIDContextKey).(string)
	return id
}

// ctxLog returns a logger pre-tagged with the request ID, for handlers that
// want correlated log lines. Falls back to the default logger untagged.
func ctxLog(ctx context.Context) *slog.Logger {
	if id := requestIDFromContext(ctx); id != "" {
		return slog.Default().With("request_id", id)
	}
	return slog.Default()
}

// statusRecorder captures the response status for the request log. It must
// forward Flush: the SSE /plan handler type-asserts http.Flusher on the
// writer it receives, and losing that capability here would break streaming.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Flush() {
	if f, ok := s.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// tokenPathPrefixes are URL path prefixes whose NEXT segment is a secret — a
// signed export token, a share/invite/unsubscribe token, or a share-preview
// token. redactPath scrubs that segment so capability tokens never reach the
// request log (from where they could be replayed).
var tokenPathPrefixes = []string{
	"/api/v1/export/",
	"/api/v1/shared/",
	"/api/v1/invites/",
	"/api/v1/unsubscribe/",
	"/api/v1/share-preview/",
}

// redactPath replaces the secret segment following a known token-bearing
// prefix with "[redacted]", keeping the rest of the path for debugging
// (e.g. /api/v1/export/[redacted]/print.html). Paths without such a prefix
// pass through unchanged.
func redactPath(p string) string {
	for _, prefix := range tokenPathPrefixes {
		if !strings.HasPrefix(p, prefix) {
			continue
		}
		rest := p[len(prefix):]
		if rest == "" {
			return p
		}
		if i := strings.IndexByte(rest, '/'); i >= 0 {
			return prefix + "[redacted]" + rest[i:]
		}
		return prefix + "[redacted]"
	}
	return p
}

// sensitiveQueryKeys are query parameters whose values are secrets or
// single-use capability codes (email-verify token, OAuth code/state, and the
// OAuth token echoes some providers append).
var sensitiveQueryKeys = map[string]bool{
	"token":        true,
	"code":         true,
	"state":        true,
	"access_token": true,
	"id_token":     true,
}

// redactQuery replaces the values of sensitive query keys with "[redacted]",
// leaving every other parameter — and the original order — intact. Splitting on
// the raw "&" is safe because a literal "&" inside a value is always
// percent-encoded. A query with no sensitive keys is returned verbatim.
func redactQuery(raw string) string {
	parts := strings.Split(raw, "&")
	changed := false
	for i, p := range parts {
		key := p
		if eq := strings.IndexByte(p, '='); eq >= 0 {
			key = p[:eq]
		}
		decoded := key
		if u, err := url.QueryUnescape(key); err == nil {
			decoded = u
		}
		if sensitiveQueryKeys[strings.ToLower(decoded)] {
			parts[i] = key + "=[redacted]"
			changed = true
		}
	}
	if !changed {
		return raw
	}
	return strings.Join(parts, "&")
}

// requestIDMiddleware assigns each request an ID (honoring an inbound
// X-Request-ID from the gateway), echoes it on the response, and emits the
// structured request log line.
func requestIDMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := r.Header.Get("X-Request-ID")
		if id == "" || len(id) > 128 {
			id = uuid.NewString()
		}
		w.Header().Set("X-Request-ID", id)

		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		start := time.Now()
		next.ServeHTTP(rec, r.WithContext(context.WithValue(r.Context(), requestIDContextKey, id)))

		attrs := []any{
			"request_id", id,
			"method", r.Method,
			"path", redactPath(r.URL.Path),
			"status", rec.status,
			"duration_ms", time.Since(start).Milliseconds(),
			"remote", clientIP(r),
		}
		if q := r.URL.RawQuery; q != "" {
			attrs = append(attrs, "query", redactQuery(q))
		}
		slog.Info("request", attrs...)
	})
}

// Request body caps. Generous headroom over the largest legitimate payloads:
// a full 50-location optimize-route or an admin ingest of raw research text is
// tens of KB; /plan resends the whole chat history so it gets a wider lane.
//
// The /plan lane must comfortably cover everything plan_handler.go's own
// rune caps admit: planMaxMessages (60) x planMaxMessageChars (20,000 runes)
// of 4-byte UTF-8 is ~4.6 MiB of content plus JSON framing. Image attachments
// widen the lane: the client downscales to ~100-300 KB base64 per image, but
// the per-image cap admits up to ~6.8 MB, so this body cap — not the
// planMaxImagesPerRequest count — is the effective aggregate byte bound for
// image-heavy histories. A 413 here still beats dying at the model API, but
// conversations within plan_handler.go's own caps should normally clear this
// lane and get friendly SSE error events instead. nginx's client_max_body_size
// (dockerize/*/nginx) must stay >= this value or the gateway 413s first.
const (
	maxRequestBodyBytes       = 256 << 10 // 256 KiB, all endpoints by default
	planMaxRequestBodyBytes   = 20 << 20  // 20 MiB for the /plan chat history incl. images (see above)
	transcribeMaxRequestBytes = 10 << 20  // 10 MiB for /transcribe audio clips (60s opus is well under)
	importMaxRequestBodyBytes = 2 << 20   // 2 MiB for /trips/import pasted transcripts (server truncates to 60k chars)
)

// bodyLimitMiddleware caps request body size. It wraps the request body ONLY
// (http.MaxBytesReader) — the response path is untouched, so SSE streaming on
// /plan and the server's WriteTimeout=0 invariant are unaffected. A declared
// Content-Length over the cap is rejected up front with a clean 413; chunked
// or lying clients are stopped by MaxBytesReader mid-read, which surfaces as
// the handler's normal decode-error response.
func bodyLimitMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		limit := int64(maxRequestBodyBytes)
		switch r.URL.Path {
		case "/api/v1/plan":
			limit = planMaxRequestBodyBytes
		case "/api/v1/transcribe":
			limit = transcribeMaxRequestBytes
		case "/api/v1/trips/import":
			limit = importMaxRequestBodyBytes
		}
		if r.ContentLength > limit {
			writeJSONError(w, http.StatusRequestEntityTooLarge, "request body too large")
			return
		}
		if r.Body != nil {
			r.Body = http.MaxBytesReader(w, r.Body, limit)
		}
		next.ServeHTTP(w, r)
	})
}

// recoveryMiddleware converts a handler panic into a JSON 500 instead of a
// dropped connection, logging the stack with the request ID. net/http already
// keeps the process alive on handler panics; the value here is the clean
// response and the structured log. For a stream that has already committed
// headers (SSE), the 500 write is a harmless no-op on the wire.
func recoveryMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			rec := recover()
			if rec == nil {
				return
			}
			if rec == http.ErrAbortHandler {
				// net/http uses this sentinel to abort silently; preserve it.
				panic(rec)
			}
			slog.Error("panic recovered",
				"request_id", requestIDFromContext(r.Context()),
				"method", r.Method,
				"path", r.URL.Path,
				"panic", fmt.Sprint(rec),
				"stack", string(debug.Stack()),
			)
			writeJSONError(w, http.StatusInternalServerError, "internal server error")
			// Report the panic to Sentry after the response is written so
			// the synchronous flush never delays the client. Guarded on
			// sentryEnabled: with SENTRY_DSN unset this branch never runs
			// and the recovery path is unchanged. (Hub.Recover and
			// Hub.Flush are also no-ops on an uninitialized hub —
			// sentry-go v0.47.0 hub.go:323-326 and hub.go:356-360 return
			// early when no client is bound — the guard is belt and
			// braces.)
			if sentryEnabled {
				sentry.CurrentHub().Recover(rec)
				sentry.Flush(2 * time.Second)
			}
		}()
		next.ServeHTTP(w, r)
	})
}
