package main

import (
	"errors"
	"testing"
	"time"
)

// The classifier leads with the SMTP reply code because provider prose changes
// without notice. An unrecognized error must never classify fatal — the same
// call ai_health.go makes for unfamiliar envelopes.

func TestClassifyEmailError(t *testing.T) {
	cases := []struct {
		name       string
		err        error
		wantClass  emailErrorClass
		wantReason string
	}{
		{"success", nil, emailClassOK, ""},

		// Permanent rejections — deterministic, never retried, don't self-heal.
		{"auth failure", errors.New("535 5.7.8 Authentication credentials invalid"), emailClassFatal, "authentication"},
		{"sender rejected", errors.New("550 5.7.1 The from address domain is not verified"), emailClassFatal, "sender rejected"},
		{"mailbox unavailable", errors.New("553 5.1.8 Sender address rejected"), emailClassFatal, "sender rejected"},
		{"transaction failed", errors.New("554 5.7.1 Message rejected"), emailClassFatal, "transaction failed"},
		{"code with a hyphen continuation", errors.New("550-5.7.1 rejected"), emailClassFatal, "sender rejected"},

		// 4xx is "try later" by definition.
		{"service unavailable", errors.New("421 4.7.0 Try again later"), emailClassTransient, "temporary"},
		{"greylisted", errors.New("450 4.2.0 Greylisted"), emailClassTransient, "temporary"},
		{"mailbox busy", errors.New("451 4.3.0 Temporary failure"), emailClassTransient, "temporary"},
		{"insufficient storage", errors.New("452 4.2.2 Over quota"), emailClassTransient, "temporary"},

		// No reply code at all: dial/TLS/timeout.
		{"connection refused", errors.New("dial tcp 1.2.3.4:587: connect: connection refused"), emailClassTransient, "transport"},
		{"dns failure", errors.New("dial tcp: lookup smtp.example.com: no such host"), emailClassTransient, "transport"},
		{"timeout", errors.New("read tcp: i/o timeout"), emailClassTransient, "transport"},
		{"tls failure", errors.New("tls: first record does not look like a TLS handshake"), emailClassTransient, "transport"},

		// Unrecognized shapes are counted, never alerted.
		{"unknown shape", errors.New("something nobody has seen before"), emailClassUnknown, ""},
		// A bare number in prose must not be read as a reply code.
		{"number inside prose", errors.New("550abc not a reply code"), emailClassUnknown, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			class, reason := classifyEmailError(c.err)
			if class != c.wantClass || reason != c.wantReason {
				t.Fatalf("classifyEmailError(%v) = (%s, %q), want (%s, %q)",
					c.err, class, reason, c.wantClass, c.wantReason)
			}
		})
	}
}

func TestEmailHealthTrackerTransitions(t *testing.T) {
	tr := &emailHealthTracker{}
	base := time.Date(2026, 8, 15, 12, 0, 0, 0, time.UTC)

	if tr.state().Failing {
		t.Fatal("a tracker with no sends must not report failing")
	}

	tr.record(base, emailClassOK, "")
	if tr.state().Failing {
		t.Fatal("a success must not report failing")
	}

	tr.record(base.Add(time.Minute), emailClassFatal, "sender rejected")
	st := tr.state()
	if !st.Failing || st.Reason != "sender rejected" {
		t.Fatalf("a fatal send must flip the signal: %+v", st)
	}

	// A blip during a real outage must not fake a recovery.
	tr.record(base.Add(2*time.Minute), emailClassTransient, "transport")
	tr.record(base.Add(3*time.Minute), emailClassUnknown, "")
	if !tr.state().Failing {
		t.Fatal("transient/unknown results must not clear a fatal state")
	}

	// Only a real success clears it.
	tr.record(base.Add(4*time.Minute), emailClassOK, "")
	st = tr.state()
	if st.Failing {
		t.Fatal("a successful send must clear the failing state")
	}
	if st.SuccessTotal != 2 || st.FatalTotal != 1 || st.TransientTotal != 2 {
		t.Fatalf("counters wrong: %+v", st)
	}
}

func TestRecordEmailResultFeedsTheSharedTracker(t *testing.T) {
	saved := emailHealth
	emailHealth = &emailHealthTracker{}
	defer func() { emailHealth = saved }()

	// What the send site calls, once per attempt.
	if class, _ := recordEmailResult(errors.New("550 5.7.1 domain not verified")); class != emailClassFatal {
		t.Fatalf("class = %s, want fatal", class)
	}
	if !emailHealth.state().Failing {
		t.Fatal("the shared tracker did not see the failure")
	}

	// And it is what the ops verdict reads — the whole point of the exercise.
	state := computeHealthState(true, false, aiHealthState{}, emailHealth.state())
	if !state.degraded {
		t.Fatal("a rejected sender must degrade the ops verdict")
	}
	found := false
	for _, r := range state.reasons {
		if r == "email failing: sender rejected" {
			found = true
		}
	}
	if !found {
		t.Fatalf("reason missing from %v", state.reasons)
	}

	if _, _ = recordEmailResult(nil); emailHealth.state().Failing {
		t.Fatal("a successful send must clear it")
	}
}
