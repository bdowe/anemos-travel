package main

// ai_health.go — passive AI-provider health tracking for the ops degradation
// self-check. Prod ran for days with /plan completely down because the
// Anthropic account ran out of credits: every call failed with a 400
// "credit balance is too low" and nothing alerted — providerStatuses reports
// key PRESENCE, not key USABILITY, and the health monitor watches only DB +
// backups. This file closes that gap without breaking the monitor's
// never-ping-paid-providers invariant: the real AI call sites classify the
// errors they already observe and fold them into a process-lifetime tracker;
// computeHealthState reads the tracker, so a fatal (billing/auth) failure
// flips the shared degraded verdict and the existing transition alerts fire.
//
// Classes: fatal failures (billing, auth, permission) alert — they are
// deterministic, never retried by the SDK, and don't heal on their own.
// Transient failures (overload, rate limit, 5xx, timeouts) and unknown shapes
// are counted for /admin/ops/metrics but never alert (owner decision).

import (
	"context"
	"errors"
	"strings"
	"sync"
	"time"

	anthropic "github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/shared"
)

// aiErrorClass buckets one AI-provider call result for health tracking.
type aiErrorClass string

const (
	aiClassOK        aiErrorClass = "ok"
	aiClassFatal     aiErrorClass = "fatal"     // billing/auth — account-level, alerts
	aiClassTransient aiErrorClass = "transient" // overload/rate-limit/5xx/timeout — never alerts
	aiClassUnknown   aiErrorClass = "unknown"   // unrecognized shape — never alerts
)

// classifyAIError maps one AI call error to a health class plus a short
// human reason ("credit balance", "authentication", ...). Pure — the
// pgconn.SafeToRetry-style helper for the AI provider.
//
// Classification leads with the API error TYPE, not the HTTP status: mid-stream
// SSE errors arrive as *anthropic.Error carrying the stream response's
// StatusCode 200, so status alone would misread every mid-stream overload.
// The status fallback exists only for unrecognized envelopes — with
// ANTHROPIC_BASE_URL pointing at an Anthropic-compatible provider (Moonshot/
// Kimi) the error body may not match Anthropic's shapes, and an unrecognized
// error must never classify fatal (false alert) — only universal HTTP
// semantics (401/403) are trusted cross-provider.
//
// MUST NOT call err.Error() on the *anthropic.Error branch: apierror.Error
// stringification dereferences Request/Response unconditionally, which are nil
// on test-constructed errors. Only Type(), StatusCode, and RawJSON() are read.
func classifyAIError(err error) (aiErrorClass, string) {
	if err == nil {
		return aiClassOK, ""
	}

	var apierr *anthropic.Error
	if errors.As(err, &apierr) {
		switch apierr.Type() {
		case shared.ErrorTypeBillingError:
			return aiClassFatal, "credit balance"
		case shared.ErrorTypeInvalidRequestError:
			// The real credit outage arrived as a generic
			// invalid_request_error whose message names the credit balance.
			// WITHOUT that marker, an invalid request is OUR malformed
			// payload — a bug, not a provider outage — and must not alert.
			if strings.Contains(strings.ToLower(apierr.RawJSON()), "credit balance") {
				return aiClassFatal, "credit balance"
			}
			return aiClassUnknown, "invalid request"
		case shared.ErrorTypeAuthenticationError:
			return aiClassFatal, "authentication"
		case shared.ErrorTypePermissionError:
			return aiClassFatal, "permission"
		case shared.ErrorTypeRateLimitError:
			return aiClassTransient, "rate limited"
		case shared.ErrorTypeOverloadedError:
			return aiClassTransient, "overloaded"
		case shared.ErrorTypeTimeoutError:
			return aiClassTransient, "timeout"
		case shared.ErrorTypeAPIError:
			return aiClassTransient, "api error"
		case shared.ErrorTypeNotFoundError:
			return aiClassTransient, "not found"
		}
		// Unrecognized envelope: trust only universal HTTP semantics.
		switch {
		case apierr.StatusCode == 401:
			return aiClassFatal, "authentication"
		case apierr.StatusCode == 403:
			return aiClassFatal, "permission"
		case apierr.StatusCode == 408, apierr.StatusCode == 429, apierr.StatusCode >= 500:
			return aiClassTransient, "provider error"
		default:
			return aiClassUnknown, "unrecognized error"
		}
	}

	// Not an API error: local deadline, client disconnect, transport failure.
	// All transient — none says anything about account health.
	if errors.Is(err, context.DeadlineExceeded) {
		return aiClassTransient, "timeout"
	}
	if errors.Is(err, context.Canceled) {
		return aiClassTransient, "canceled"
	}
	return aiClassTransient, "network"
}

// aiHealthTracker is the process-lifetime AI-provider result tracker
// (upstreamCallCounters/opsRegistry precedent: zero on boot, reset on
// restart — a restart mid-outage re-alerts once after the next fatal call
// plus one monitor tick, same acceptance as healthMonitor.lastDegraded).
//
// A mutex rather than atomics: the state is multi-field with cross-field
// invariants (Failing compares two timestamps that must be written
// consistently; the fatal reason pairs with its timestamp; the consecutive
// counter resets on success). Write rate is a handful per user turn.
type aiHealthTracker struct {
	mu               sync.Mutex
	lastSuccessAt    time.Time
	lastFatalAt      time.Time
	lastFatalReason  string
	successTotal     int64
	transientTotal   int64
	fatalTotal       int64
	consecutiveFatal int64
}

// aiHealth is the process-wide tracker every AI call site records into.
var aiHealth = &aiHealthTracker{}

// aiHealthState is a consistent read snapshot; a plain value struct so
// computeHealthState stays pure and tests construct it literally.
type aiHealthState struct {
	Failing          bool
	Reason           string
	LastFatalAt      time.Time
	LastSuccessAt    time.Time
	SuccessTotal     int64
	TransientTotal   int64
	FatalTotal       int64
	ConsecutiveFatal int64
}

// record folds one classified call result in. Transient/unknown results touch
// neither timestamp: an occasional network blip during a credit outage cannot
// fake a recovery, and a rate-limit storm cannot fake an outage.
func (t *aiHealthTracker) record(now time.Time, class aiErrorClass, reason string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	switch class {
	case aiClassOK:
		t.lastSuccessAt = now
		t.successTotal++
		t.consecutiveFatal = 0
	case aiClassFatal:
		t.lastFatalAt = now
		t.lastFatalReason = reason
		t.fatalTotal++
		t.consecutiveFatal++
	case aiClassTransient, aiClassUnknown:
		t.transientTotal++
	}
}

// state returns the snapshot the ops-health verdict and metrics read. Failing
// clears only on the next successful AI call — with zero AI traffic a fatal
// state persists, which is correct for billing/auth outages (they don't fix
// themselves) and is the price of the monitor never pinging paid providers.
func (t *aiHealthTracker) state() aiHealthState {
	t.mu.Lock()
	defer t.mu.Unlock()
	return aiHealthState{
		Failing:          !t.lastFatalAt.IsZero() && t.lastFatalAt.After(t.lastSuccessAt),
		Reason:           t.lastFatalReason,
		LastFatalAt:      t.lastFatalAt,
		LastSuccessAt:    t.lastSuccessAt,
		SuccessTotal:     t.successTotal,
		TransientTotal:   t.transientTotal,
		FatalTotal:       t.fatalTotal,
		ConsecutiveFatal: t.consecutiveFatal,
	}
}

// recordAIResult is the one-liner every AI call site uses, exactly once per
// SDK call (nil err records a success). Returns the class + reason so the
// /plan handler can pick its user-facing message without reclassifying.
func recordAIResult(err error) (aiErrorClass, string) {
	class, reason := classifyAIError(err)
	aiHealth.record(time.Now(), class, reason)
	return class, reason
}
