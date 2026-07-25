package main

import "testing"

// TestHashBearerToken locks the exact digest hashBearerToken produces. The
// vector must equal Postgres `encode(sha256('test'::bytea),'hex')` — the
// hashing migration (00050) rewrites existing sessions.id with that SQL, so if
// the Go and SQL digests ever diverged, every already-signed-in session would
// stop validating after the migration.
func TestHashBearerToken(t *testing.T) {
	const wantForTest = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
	if got := hashBearerToken("test"); got != wantForTest {
		t.Fatalf("hashBearerToken(%q) = %q, want %q (must match SQL sha256)", "test", got, wantForTest)
	}
	// 64-char lowercase hex, deterministic, and collision-free across inputs.
	h := hashBearerToken("some-random-session-token")
	if len(h) != 64 {
		t.Fatalf("digest length = %d, want 64", len(h))
	}
	if hashBearerToken("x") != hashBearerToken("x") {
		t.Fatal("hashBearerToken is not deterministic")
	}
	if hashBearerToken("a") == hashBearerToken("b") {
		t.Fatal("distinct tokens hashed to the same digest")
	}
}
