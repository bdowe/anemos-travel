package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestSenderDomainState(t *testing.T) {
	cases := []struct {
		name    string
		from    string
		baseURL string
		want    string
	}{
		// The regression this exists for: prod sent as @goldentempo.co while
		// serving goldentempotravel.com, and nothing anywhere noticed.
		{"the 2026-08 outage", "alerts@goldentempo.co", "https://goldentempotravel.com", senderCheckMismatch},
		{"matching domain", "alerts@anemos.travel", "https://anemos.travel", senderCheckOK},
		{"www on the site side", "alerts@anemos.travel", "https://www.anemos.travel", senderCheckOK},
		{"sending subdomain", "alerts@mail.anemos.travel", "https://anemos.travel", senderCheckOK},
		{"site is a subdomain of the sender", "alerts@anemos.travel", "https://app.anemos.travel", senderCheckOK},
		// The dot boundary is the whole reason this isn't strings.HasSuffix.
		{"lookalike domain", "alerts@notanemos.travel", "https://anemos.travel", senderCheckMismatch},
		{"different TLD", "alerts@anemos.com", "https://anemos.travel", senderCheckMismatch},
		{"case is insignificant", "Alerts@ANEMOS.travel", "https://anemos.travel", senderCheckOK},
		// The documented form is a bare address, but don't punish the other one.
		{"display-name form", "Anemos <alerts@anemos.travel>", "https://anemos.travel", senderCheckOK},

		// "skipped" must stay distinguishable from "ok": a check that never
		// ran is not a check that passed.
		{"no sender configured", "", "https://anemos.travel", senderCheckSkipped},
		{"sender is not an address", "alerts", "https://anemos.travel", senderCheckSkipped},
		{"localhost dev", "alerts@anemos.travel", "http://localhost:3000", senderCheckSkipped},
		{"loopback dev", "alerts@anemos.travel", "http://127.0.0.1:8080", senderCheckSkipped},
		{"no base url", "alerts@anemos.travel", "", senderCheckSkipped},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := senderDomainState(c.from, c.baseURL); got != c.want {
				t.Fatalf("senderDomainState(%q, %q) = %q, want %q", c.from, c.baseURL, got, c.want)
			}
		})
	}
}

func TestEmailAvailabilityEndpoint(t *testing.T) {
	t.Setenv("SMTP_HOST", "smtp.resend.com")
	t.Setenv("SMTP_FROM", "alerts@example.test")
	t.Setenv("PUBLIC_BASE_URL", "https://example.test")
	// The singleton snapshots env at construction, so rebuild it for the test.
	saved := emailService
	emailService = NewEmailService()
	defer func() { emailService = saved }()

	rec := httptest.NewRecorder()
	emailAvailabilityHandler(rec, httptest.NewRequest(http.MethodGet, "/api/v1/email/availability", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}

	var got EmailAvailabilityResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v (body %s)", err, rec.Body.String())
	}
	if !got.Available || got.SenderDomainCheck != senderCheckOK {
		t.Fatalf("got %+v, want available with an ok sender", got)
	}
	// Public and unauthenticated, so it must carry verdicts only — never the
	// address, host, or credentials.
	for _, leaked := range []string{"alerts@", "smtp.resend.com", "example.test"} {
		if bodyContains(rec.Body.String(), leaked) {
			t.Fatalf("response leaks %q: %s", leaked, rec.Body.String())
		}
	}
}

func bodyContains(body, needle string) bool {
	return len(needle) > 0 && len(body) >= len(needle) &&
		func() bool {
			for i := 0; i+len(needle) <= len(body); i++ {
				if body[i:i+len(needle)] == needle {
					return true
				}
			}
			return false
		}()
}
