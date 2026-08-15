package main

import (
	"context"
	"net/http"
	"strings"
	"testing"
)

// trips.origin is where the traveler said they set out from. It exists because
// the app otherwise assumes the saved home airport, which turned a stated drive
// to Montreal into "EWR → Montreal" (2026-08-14). Create-only by design — the
// derived transport todos take their identity from this string, so a later edit
// would orphan them along with their booked flag and mode override.

// tripOriginOf reads the column straight back, so the assertions are about
// what landed in Postgres rather than what a response mapper chose to show.
func tripOriginOf(t *testing.T, tripID string) *string {
	t.Helper()
	var origin *string
	if err := dbPool.QueryRow(context.Background(),
		`SELECT origin FROM trips WHERE id = $1`, tripID).Scan(&origin); err != nil {
		t.Fatalf("read trip origin: %v", err)
	}
	return origin
}

func TestPersistTripStoresOrigin(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "origin@example.com")

	tripID, _, err := persistTrip(context.Background(), user.ID, "chat-origin",
		"Montreal Weekend", "", "2026-08-15", "2026-08-17", "car", tripEndpoints{Origin: "  Lake George, NY  "},
		[]map[string]any{{"name": "Schwartz's Deli", "city": "Montreal"}})
	if err != nil {
		t.Fatalf("persistTrip: %v", err)
	}

	got := tripOriginOf(t, tripID)
	if got == nil {
		t.Fatal("origin not persisted")
	}
	// Trimmed, but otherwise kept exactly as the traveler phrased it — the
	// booking legs render it verbatim.
	if *got != "Lake George, NY" {
		t.Fatalf("origin = %q, want %q", *got, "Lake George, NY")
	}
}

func TestPersistTripOmittedOriginStaysNull(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "noorigin@example.com")

	tripID, _, err := persistTrip(context.Background(), user.ID, "chat-noorigin",
		"Lisbon", "", "", "", "", tripEndpoints{Origin: "   "},
		[]map[string]any{{"name": "Belém Tower", "city": "Lisbon"}})
	if err != nil {
		t.Fatalf("persistTrip: %v", err)
	}

	// Whitespace is not a statement: NULL keeps the home-airport default.
	if o := tripOriginOf(t, tripID); o != nil {
		t.Fatalf("origin = %q, want NULL", *o)
	}
}

func TestPersistTripBoundsOriginLength(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "longorigin@example.com")

	tripID, _, err := persistTrip(context.Background(), user.ID, "chat-longorigin",
		"Trip", "", "", "", "", tripEndpoints{Origin: strings.Repeat("x", maxTripOriginLen+50)},
		[]map[string]any{{"name": "Belém Tower", "city": "Lisbon"}})
	if err != nil {
		t.Fatalf("persistTrip: %v", err)
	}

	// It lands in a leg title, so a runaway model can't write an essay there.
	if got := len(*tripOriginOf(t, tripID)); got != maxTripOriginLen {
		t.Fatalf("origin length = %d, want %d", got, maxTripOriginLen)
	}
}

func TestTripResponseCarriesOrigin(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "originjson@example.com")

	tripID, _, err := persistTrip(context.Background(), user.ID, "chat-originjson",
		"Montreal Weekend", "", "", "", "car", tripEndpoints{Origin: "Lake George, NY"},
		[]map[string]any{{"name": "Schwartz's Deli", "city": "Montreal"}})
	if err != nil {
		t.Fatalf("persistTrip: %v", err)
	}

	// The Flutter derivation reads this off the trip GET to title the legs.
	rec := doJSON(t, http.MethodGet, "/api/v1/trips/"+tripID, token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("get trip: status = %d, body %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"origin":"Lake George, NY"`) {
		t.Fatalf("trip JSON missing origin: %s", rec.Body.String())
	}

	// The airports ride the same response: the Flutter map resolves them to
	// pins and the derivation titles the legs from them, so a field that never
	// reaches the wire is a trip that silently keeps using the saved home
	// airport (migration 00064).
	airportsID, _, err := persistTrip(context.Background(), user.ID, "chat-airports",
		"Amsterdam", "", "", "", "", tripEndpoints{OriginAirport: "ALB", ReturnAirport: "EWR"},
		[]map[string]any{{"name": "Rijksmuseum", "city": "Amsterdam"}})
	if err != nil {
		t.Fatalf("persistTrip: %v", err)
	}
	rec = doJSON(t, http.MethodGet, "/api/v1/trips/"+airportsID, token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("get trip: status = %d, body %s", rec.Code, rec.Body.String())
	}
	for _, want := range []string{`"origin_airport":"ALB"`, `"return_airport":"EWR"`} {
		if !strings.Contains(rec.Body.String(), want) {
			t.Fatalf("trip JSON missing %s: %s", want, rec.Body.String())
		}
	}

	// Absent stays absent rather than serializing as null — for the airports
	// too, so a client can tell "states none" from a stated code.
	plainID, _, err := persistTrip(context.Background(), user.ID, "chat-plain",
		"Lisbon", "", "", "", "", tripEndpoints{Origin: ""},
		[]map[string]any{{"name": "Belém Tower", "city": "Lisbon"}})
	if err != nil {
		t.Fatalf("persistTrip: %v", err)
	}
	plain := doJSON(t, http.MethodGet, "/api/v1/trips/"+plainID, token, nil)
	for _, absent := range []string{`"origin"`, `"origin_airport"`, `"return_airport"`} {
		if strings.Contains(plain.Body.String(), absent) {
			t.Fatalf("unstated %s should be omitted: %s", absent, plain.Body.String())
		}
	}
}

func TestPatchTripCannotSetOrigin(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "patchorigin@example.com")

	tripID, _, err := persistTrip(context.Background(), user.ID, "chat-patchorigin",
		"Montreal Weekend", "", "", "", "", tripEndpoints{Origin: "Lake George, NY"},
		[]map[string]any{{"name": "Schwartz's Deli", "city": "Montreal"}})
	if err != nil {
		t.Fatalf("persistTrip: %v", err)
	}

	// Origin is deliberately not PATCH-able: the transport todos are keyed by
	// it, so a rewrite would delete them (DeleteStaleAutoBookingTodos) and take
	// the booked flag and per-leg mode override with them. An unknown field is
	// ignored, so the stored value must survive untouched.
	rec := doJSON(t, http.MethodPatch, "/api/v1/trips/"+tripID, token,
		map[string]any{"origin": "Newark, NJ"})
	if rec.Code != http.StatusOK {
		t.Fatalf("patch: status = %d, body %s", rec.Code, rec.Body.String())
	}
	if o := tripOriginOf(t, tripID); o == nil || *o != "Lake George, NY" {
		t.Fatalf("origin changed via PATCH: %v", o)
	}
}
