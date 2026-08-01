package main

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	anthropic "github.com/anthropics/anthropic-sdk-go"
)

// aiAPIErr constructs a typed SDK error the way the wire produces one:
// UnmarshalJSON populates the private errorType and RawJSON. StatusCode is set
// AFTER (untagged field). Request/Response stay nil on purpose — that also
// regression-guards the classifier's never-call-Error() rule, since
// stringifying such an error panics.
func aiAPIErr(t *testing.T, status int, body string) *anthropic.Error {
	t.Helper()
	e := &anthropic.Error{}
	if err := e.UnmarshalJSON([]byte(body)); err != nil {
		t.Fatalf("construct api error: %v", err)
	}
	e.StatusCode = status
	return e
}

func errBody(errType, message string) string {
	return fmt.Sprintf(`{"type":"error","error":{"type":%q,"message":%q}}`, errType, message)
}

// resetAIHealth zeroes the process-global tracker for a test and again on
// cleanup, so fatal-writing tests can't leak Failing into later tests (the
// ops-health handler tests assert not-degraded).
func resetAIHealth(t *testing.T) {
	t.Helper()
	zero := func() {
		aiHealth.mu.Lock()
		defer aiHealth.mu.Unlock()
		aiHealth.lastSuccessAt = time.Time{}
		aiHealth.lastFatalAt = time.Time{}
		aiHealth.lastFatalReason = ""
		aiHealth.successTotal = 0
		aiHealth.transientTotal = 0
		aiHealth.fatalTotal = 0
		aiHealth.consecutiveFatal = 0
	}
	zero()
	t.Cleanup(zero)
}

const prodCreditBody = `{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."},"request_id":"req_x"}`

func TestClassifyAIError(t *testing.T) {
	cases := []struct {
		name   string
		err    error
		class  aiErrorClass
		reason string
	}{
		{"nil is ok", nil, aiClassOK, ""},
		{"billing_error", aiAPIErr(t, 400, errBody("billing_error", "insufficient funds")), aiClassFatal, "credit balance"},
		{"the real prod credit 400", aiAPIErr(t, 400, prodCreditBody), aiClassFatal, "credit balance"},
		// A plain invalid_request without the credit marker is OUR bug, not an
		// outage — it must never alert.
		{"plain invalid_request", aiAPIErr(t, 400, errBody("invalid_request_error", "max_tokens: field required")), aiClassUnknown, "invalid request"},
		{"authentication_error", aiAPIErr(t, 401, errBody("authentication_error", "invalid x-api-key")), aiClassFatal, "authentication"},
		{"permission_error", aiAPIErr(t, 403, errBody("permission_error", "key disabled")), aiClassFatal, "permission"},
		{"rate limit", aiAPIErr(t, 429, errBody("rate_limit_error", "slow down")), aiClassTransient, "rate limited"},
		// Mid-stream SSE errors carry the 200 stream response's status — the
		// type must win.
		{"mid-stream overloaded at 200", aiAPIErr(t, 200, errBody("overloaded_error", "Overloaded")), aiClassTransient, "overloaded"},
		{"timeout_error", aiAPIErr(t, 408, errBody("timeout_error", "timed out")), aiClassTransient, "timeout"},
		{"api_error", aiAPIErr(t, 500, errBody("api_error", "internal")), aiClassTransient, "api error"},
		// Anthropic-compatible providers (Kimi/Moonshot) may use envelopes we
		// don't recognize: only universal HTTP semantics may classify fatal.
		{"unknown envelope 401", aiAPIErr(t, 401, `{"code":7,"msg":"bad key"}`), aiClassFatal, "authentication"},
		{"unknown envelope 403", aiAPIErr(t, 403, `{"code":8,"msg":"forbidden"}`), aiClassFatal, "permission"},
		{"unknown envelope 402 never fatal", aiAPIErr(t, 402, `{"code":9,"msg":"insufficient balance"}`), aiClassUnknown, "unrecognized error"},
		{"unknown envelope 529", aiAPIErr(t, 529, `{"whatever":true}`), aiClassTransient, "provider error"},
		{"zero-value api error no panic", &anthropic.Error{}, aiClassUnknown, "unrecognized error"},
		// errors.As must reach through the call sites' fmt.Errorf wraps.
		{"wrapped fatal", fmt.Errorf("extraction model call: %w", aiAPIErr(t, 401, errBody("authentication_error", "nope"))), aiClassFatal, "authentication"},
		{"context deadline", context.DeadlineExceeded, aiClassTransient, "timeout"},
		{"context canceled", context.Canceled, aiClassTransient, "canceled"},
		{"transport error", errors.New("dial tcp 1.2.3.4:443: connection refused"), aiClassTransient, "network"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			class, reason := classifyAIError(c.err)
			if class != c.class || reason != c.reason {
				t.Fatalf("classifyAIError = (%s, %q), want (%s, %q)", class, reason, c.class, c.reason)
			}
		})
	}
}

func TestAIHealthTrackerStateMachine(t *testing.T) {
	tr := &aiHealthTracker{}
	clock := time.Date(2026, 8, 1, 12, 0, 0, 0, time.UTC)
	tick := func() time.Time { clock = clock.Add(time.Minute); return clock }

	// Success first: healthy.
	tr.record(tick(), aiClassOK, "")
	if s := tr.state(); s.Failing || s.SuccessTotal != 1 {
		t.Fatalf("after success: %+v", s)
	}

	// Fatal flips Failing and carries the reason.
	tr.record(tick(), aiClassFatal, "credit balance")
	s := tr.state()
	if !s.Failing || s.Reason != "credit balance" || s.ConsecutiveFatal != 1 || s.FatalTotal != 1 {
		t.Fatalf("after fatal: %+v", s)
	}

	// A second fatal accumulates.
	tr.record(tick(), aiClassFatal, "credit balance")
	if s := tr.state(); s.ConsecutiveFatal != 2 || s.FatalTotal != 2 {
		t.Fatalf("after second fatal: %+v", s)
	}

	// Transient during the outage: still failing, consecutive untouched — a
	// network blip must not fake a recovery.
	tr.record(tick(), aiClassTransient, "network")
	if s := tr.state(); !s.Failing || s.ConsecutiveFatal != 2 || s.TransientTotal != 1 {
		t.Fatalf("after transient during outage: %+v", s)
	}

	// Unknown counts as transient traffic and changes nothing else.
	tr.record(tick(), aiClassUnknown, "unrecognized error")
	if s := tr.state(); !s.Failing || s.TransientTotal != 2 {
		t.Fatalf("after unknown during outage: %+v", s)
	}

	// Success recovers and resets the streak.
	tr.record(tick(), aiClassOK, "")
	if s := tr.state(); s.Failing || s.ConsecutiveFatal != 0 || s.SuccessTotal != 2 {
		t.Fatalf("after recovery: %+v", s)
	}

	// Fatal with no prior success on a fresh tracker still fails.
	fresh := &aiHealthTracker{}
	fresh.record(tick(), aiClassFatal, "authentication")
	if s := fresh.state(); !s.Failing || s.Reason != "authentication" {
		t.Fatalf("fatal-only tracker: %+v", s)
	}
}
