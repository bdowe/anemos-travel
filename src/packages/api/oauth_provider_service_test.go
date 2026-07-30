package main

import (
	"strings"
	"testing"
)

func TestNormalizeOAuthScope(t *testing.T) {
	cases := []struct {
		in     string
		want   string
		wantOK bool
	}{
		{"", oauthDefaultScope, true},
		{"   ", oauthDefaultScope, true},
		{"trips:write", "trips:write", true},
		{"recs:read trips:write", "recs:read trips:write", true},
		{"trips:write trips:write", "trips:write", true}, // deduped
		{"trips:write admin:everything", "", false},      // unknown token fails whole request
		{"openid", "", false},
	}
	for _, c := range cases {
		got, ok := normalizeOAuthScope(c.in)
		if ok != c.wantOK || got != c.want {
			t.Errorf("normalizeOAuthScope(%q) = (%q, %v), want (%q, %v)", c.in, got, ok, c.want, c.wantOK)
		}
	}
}

func TestScopeGranted(t *testing.T) {
	if !scopeGranted("trips:write recs:read", "recs:read") {
		t.Error("granted scope not recognized")
	}
	if scopeGranted("recs:read", "trips:write") {
		t.Error("ungranted scope must not pass")
	}
	if scopeGranted("", "trips:write") {
		t.Error("empty grant must not pass")
	}
	// Substring must not fool the check.
	if scopeGranted("trips:write-extended", "trips:write") {
		t.Error("scope match must be whole-token")
	}
}

func TestNewOAuthSecret(t *testing.T) {
	raw, hash, err := newOAuthSecret(oauthAccessTokenPrefix)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(raw, "gt_at_") {
		t.Errorf("raw = %q, want gt_at_ prefix", raw)
	}
	if hash != hashBearerToken(raw) {
		t.Error("hash must be hashBearerToken(raw)")
	}
	raw2, _, _ := newOAuthSecret(oauthAccessTokenPrefix)
	if raw == raw2 {
		t.Error("secrets must be unique")
	}
}
