package main

import "testing"

func TestRedactPath(t *testing.T) {
	cases := []struct{ in, want string }{
		// Token segment scrubbed, trailing path kept.
		{"/api/v1/export/abc123secret/print.html", "/api/v1/export/[redacted]/print.html"},
		{"/api/v1/export/abc123secret/event/stay/42.ics", "/api/v1/export/[redacted]/event/stay/42.ics"},
		{"/api/v1/shared/tok/join", "/api/v1/shared/[redacted]/join"},
		// Terminal token (no trailing path).
		{"/api/v1/shared/tok", "/api/v1/shared/[redacted]"},
		{"/api/v1/invites/tok", "/api/v1/invites/[redacted]"},
		{"/api/v1/unsubscribe/tok", "/api/v1/unsubscribe/[redacted]"},
		{"/api/v1/share-preview/tok", "/api/v1/share-preview/[redacted]"},
		// Prefix present but no segment after it — left alone.
		{"/api/v1/export/", "/api/v1/export/"},
		// Non-token paths pass through untouched.
		{"/api/v1/trips/123", "/api/v1/trips/123"},
		{"/api/v1/health", "/api/v1/health"},
		{"/api/v1/exported/xyz", "/api/v1/exported/xyz"}, // not a prefix match
	}
	for _, c := range cases {
		if got := redactPath(c.in); got != c.want {
			t.Errorf("redactPath(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestRedactQuery(t *testing.T) {
	cases := []struct{ in, want string }{
		{"token=abc", "token=[redacted]"},
		{"code=xyz&state=csrf", "code=[redacted]&state=[redacted]"},
		// Non-sensitive keys preserved verbatim, order intact.
		{"q=paris&page=2", "q=paris&page=2"},
		// Mixed: only sensitive value scrubbed, others kept in place.
		{"foo=1&token=secret&bar=2", "foo=1&token=[redacted]&bar=2"},
		// Case-insensitive key match.
		{"Token=secret", "Token=[redacted]"},
		// Bare sensitive key with no value.
		{"token", "token=[redacted]"},
		{"", ""},
	}
	for _, c := range cases {
		if got := redactQuery(c.in); got != c.want {
			t.Errorf("redactQuery(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestMaskEmail(t *testing.T) {
	cases := []struct{ in, want string }{
		{"brian@gmail.com", "b***n@gmail.com"},
		{"bo@example.com", "b***@example.com"}, // 2-char local
		{"a@x.io", "a***@x.io"},                // 1-char local
		{"first.last@sub.domain.co", "f***t@sub.domain.co"},
		{"nolocal", "[redacted-email]"},   // no @
		{"trailing@", "[redacted-email]"}, // @ at end, empty domain
		{"@nodomain", "[redacted-email]"}, // empty local
	}
	for _, c := range cases {
		if got := maskEmail(c.in); got != c.want {
			t.Errorf("maskEmail(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
