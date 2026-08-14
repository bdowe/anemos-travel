package main

import (
	"net/http"
	"testing"
)

// specs/active-profile — the three fields added by migration 00062, driven
// through the real router so the whole chain (JSON tags -> normalizeChoice ->
// sqlc upsert -> response mapping) is exercised, not just the validators.

func TestPreferencesActiveProfileRoundTrip(t *testing.T) {
	resetDB(t)
	_, token := createTestUser(t, "active-profile@test.local")

	// Unset by default: the profile starts empty, not defaulted.
	got := decode(t, doJSON(t, "GET", "/api/v1/preferences", token, nil))
	for _, f := range []string{"fitness_routine", "outdoor_intensity", "companions"} {
		if got[f] != nil {
			t.Fatalf("new profile %s = %v, want null", f, got[f])
		}
	}

	rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{
		"interests":         []string{"hiking"},
		"fitness_routine":   "gym",
		"outdoor_intensity": "challenging",
		"companions":        "family_with_kids",
	})
	if rec.Code != http.StatusOK {
		t.Fatalf("PUT = %d: %s", rec.Code, rec.Body.String())
	}
	saved := decode(t, rec)
	if saved["fitness_routine"] != "gym" || saved["outdoor_intensity"] != "challenging" || saved["companions"] != "family_with_kids" {
		t.Fatalf("PUT response = %v, want the three values echoed back", saved)
	}

	// Persisted, not just echoed.
	got = decode(t, doJSON(t, "GET", "/api/v1/preferences", token, nil))
	if got["fitness_routine"] != "gym" || got["outdoor_intensity"] != "challenging" || got["companions"] != "family_with_kids" {
		t.Fatalf("GET after PUT = %v, want the three values persisted", got)
	}

	// Partial update: an omitted field keeps its stored value (the merge
	// semantics every field on this profile shares).
	if rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{
		"interests":       []string{"hiking"},
		"fitness_routine": "running",
	}); rec.Code != http.StatusOK {
		t.Fatalf("partial PUT = %d: %s", rec.Code, rec.Body.String())
	}
	got = decode(t, doJSON(t, "GET", "/api/v1/preferences", token, nil))
	if got["fitness_routine"] != "running" {
		t.Fatalf("fitness_routine = %v, want the updated value", got["fitness_routine"])
	}
	if got["outdoor_intensity"] != "challenging" || got["companions"] != "family_with_kids" {
		t.Fatalf("omitted fields were not preserved: %v", got)
	}

	// "none" is a stored answer, distinct from unset.
	if rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{
		"interests": []string{"hiking"}, "fitness_routine": "none",
	}); rec.Code != http.StatusOK {
		t.Fatalf("PUT none = %d: %s", rec.Code, rec.Body.String())
	}
	got = decode(t, doJSON(t, "GET", "/api/v1/preferences", token, nil))
	if got["fitness_routine"] != "none" {
		t.Fatalf("fitness_routine = %v, want \"none\" stored", got["fitness_routine"])
	}
}

func TestPreferencesActiveProfileRejectsBadValues(t *testing.T) {
	resetDB(t)
	_, token := createTestUser(t, "active-profile-bad@test.local")

	bad := []map[string]any{
		{"fitness_routine": "lifting"},
		{"outdoor_intensity": "extreme"},
		{"companions": "family with kids"}, // the pre-00062 spaced spelling
	}
	for _, body := range bad {
		body["interests"] = []string{}
		rec := doJSON(t, "PUT", "/api/v1/preferences", token, body)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("PUT %v = %d, want 400: %s", body, rec.Code, rec.Body.String())
		}
	}
}
