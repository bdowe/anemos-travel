package main

// The `legs` payload (specs/server-leg-dates stage 1a): full trip views carry
// the server-computed city legs; list responses don't. Values here must agree
// with the trip_render_legs_test.go twin fixtures — the payload is just
// computeTripLegs serialized.

import (
	"net/http"
	"strings"
	"testing"
)

func TestTripResponseCarriesLegs(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "legspayload@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	seedMultiCityTrip(t, trip, owner.ID)

	rec := doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET trip = %d", rec.Code)
	}
	body := rec.Body.String()
	for _, want := range []string{
		`"legs":[`,
		`"key":"Panama City"`,
		`"key":"Los Angeles"`,
		// PC: stay-anchored (Hotel Casco Viejo, address match).
		`"start_date":"2026-09-15"`,
		`"end_date":"2026-09-20"`,
		// LA: stay-anchored by NAME ("Stay in Los Angeles").
		`"start_date":"2026-09-20"`,
		`"end_date":"2026-09-24"`,
		`"date_source":"stay"`,
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("trip response missing %q:\n%s", want, body)
		}
	}

	// The LIST response never carries legs (partial data would yield
	// anchor-less values).
	list := doJSON(t, "GET", "/api/v1/trips", token, nil)
	if list.Code != http.StatusOK {
		t.Fatalf("GET trips = %d", list.Code)
	}
	if strings.Contains(list.Body.String(), `"legs"`) {
		t.Fatalf("list response leaked legs:\n%s", list.Body.String())
	}
}

func TestSharedTripCarriesLegs(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "legsshare@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	seedMultiCityTrip(t, trip, owner.ID)

	shareRec := doJSON(t, "POST", "/api/v1/trips/"+trip.ID.String()+"/share", token, map[string]any{})
	if shareRec.Code != http.StatusCreated && shareRec.Code != http.StatusOK {
		t.Fatalf("create share = %d: %s", shareRec.Code, shareRec.Body.String())
	}
	tok := decode(t, shareRec)["token"]
	if tok == nil {
		t.Fatalf("no share token in %s", shareRec.Body.String())
	}

	view := doJSON(t, "GET", "/api/v1/shared/"+tok.(string), "", nil)
	if view.Code != http.StatusOK {
		t.Fatalf("shared view = %d: %s", view.Code, view.Body.String())
	}
	body := view.Body.String()
	for _, want := range []string{`"legs":[`, `"key":"Panama City"`, `"date_source":"stay"`} {
		if !strings.Contains(body, want) {
			t.Fatalf("shared view missing %q:\n%s", want, body)
		}
	}
}
