package main

import (
	"net/http"
	"testing"
)

// specs/traveler-baggage — the profile field driven through the real router, so
// the whole chain (JSON tag -> normalizeChoice -> sqlc upsert -> response) is
// exercised rather than just the validator.

func TestPreferencesBaggageRoundTrip(t *testing.T) {
	resetDB(t)
	_, token := createTestUser(t, "baggage-pref@test.local")

	// Unset by default. "Never said" is a real state: it is what makes the
	// search fall back rather than believe the traveler packs nothing.
	got := decode(t, doJSON(t, "GET", "/api/v1/preferences", token, nil))
	if got["baggage"] != nil {
		t.Fatalf("new profile baggage = %v, want null", got["baggage"])
	}

	rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{
		"interests": []string{"food"},
		"baggage":   "carry_on",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("PUT = %d: %s", rec.Code, rec.Body.String())
	}
	if saved := decode(t, rec); saved["baggage"] != "carry_on" {
		t.Fatalf("PUT response baggage = %v, want carry_on", saved["baggage"])
	}

	got = decode(t, doJSON(t, "GET", "/api/v1/preferences", token, nil))
	if got["baggage"] != "carry_on" {
		t.Fatalf("GET after PUT = %v, want carry_on persisted", got["baggage"])
	}

	// Omitted keeps the stored value (the merge semantics every field shares).
	if rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{
		"interests": []string{"food"}, "pace": "relaxed",
	}); rec.Code != http.StatusOK {
		t.Fatalf("partial PUT = %d: %s", rec.Code, rec.Body.String())
	}
	got = decode(t, doJSON(t, "GET", "/api/v1/preferences", token, nil))
	if got["baggage"] != "carry_on" {
		t.Fatalf("omitted baggage was not preserved: %v", got)
	}

	// personal_item is a stated answer, not an absence — it turns bag pricing
	// off for this traveler.
	if rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{
		"interests": []string{"food"}, "baggage": "personal_item",
	}); rec.Code != http.StatusOK {
		t.Fatalf("PUT personal_item = %d: %s", rec.Code, rec.Body.String())
	}
	got = decode(t, doJSON(t, "GET", "/api/v1/preferences", token, nil))
	if got["baggage"] != "personal_item" {
		t.Fatalf("baggage = %v, want personal_item stored", got["baggage"])
	}
}

func TestPreferencesBaggageRejectsBadValues(t *testing.T) {
	resetDB(t)
	_, token := createTestUser(t, "baggage-pref-bad@test.local")

	for _, bad := range []string{"carryon", "hand luggage", "CHECKED BAG"} {
		rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{
			"interests": []string{}, "baggage": bad,
		})
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("PUT baggage=%q = %d, want 400: %s", bad, rec.Code, rec.Body.String())
		}
	}
}
