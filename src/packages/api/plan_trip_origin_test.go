package main

// set_trip_origin (specs/trip-endpoint-airports): where a saved trip DEPARTS
// from and RETURNS to. The headline case is the one that produced the bug —
// "update the flight to Amsterdam to be from ALB" — where the agent previously
// had no tool and added a duplicate checklist item instead.

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// syncHomeLegs posts what the trip screen derives for a one-city round trip, so
// the tool operates on real derived rows rather than hand-built ones.
func syncHomeLegs(t *testing.T, tripID, token, home, city string) []map[string]any {
	t.Helper()
	rec := doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/booking-todos", token, homeLegPayload(home, city))
	if rec.Code != http.StatusOK {
		t.Fatalf("sync booking todos = %d: %s", rec.Code, rec.Body.String())
	}
	return decodeTodoList(t, rec)
}

// decodeTodoListFromTrip pulls the checklist out of a full trip response, so
// the assertions read what any client would see rather than a private query.
func decodeTodoListFromTrip(t *testing.T, rec *httptest.ResponseRecorder) []map[string]any {
	t.Helper()
	if rec.Code != http.StatusOK {
		t.Fatalf("get trip = %d: %s", rec.Code, rec.Body.String())
	}
	raw, _ := decode(t, rec)["booking_todos"].([]any)
	out := make([]map[string]any, 0, len(raw))
	for _, r := range raw {
		m, _ := r.(map[string]any)
		out = append(out, m)
	}
	return out
}

func tripEndpointsOf(t *testing.T, tripID string) (origin, dep, arr *string) {
	t.Helper()
	if err := dbPool.QueryRow(context.Background(),
		`SELECT origin, origin_airport, return_airport FROM trips WHERE id = $1`, tripID).
		Scan(&origin, &dep, &arr); err != nil {
		t.Fatalf("read trip endpoints: %v", err)
	}
	return origin, dep, arr
}

// The reported bug, end to end: the traveler asks to leave from ALB instead of
// EWR. The existing derived leg must be RENAMED, keeping everything the
// traveler invested in it — and no duplicate may appear.
func TestSetTripOriginRenamesTheDepartureLegInPlace(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "origintool@example.com")
	trip := createTestTrip(t, user.ID, 0)
	tripID := trip.ID.String()
	base := "/api/v1/trips/" + tripID

	if rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{"home_airport": "EWR"}); rec.Code != http.StatusOK {
		t.Fatalf("save home airport = %d", rec.Code)
	}
	rows := syncHomeLegs(t, tripID, token, "EWR", "Amsterdam")
	outboundID := rows[0]["id"].(string)
	if rec := doJSON(t, "PATCH", base+"/booking-todos/"+outboundID, token, map[string]any{"booked": true}); rec.Code != http.StatusOK {
		t.Fatalf("book outbound = %d", rec.Code)
	}

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetTripOriginTool(s, []byte(`{"airport":"ALB"}`))
	if isErr {
		t.Fatalf("set_trip_origin errored: %s", msg)
	}
	// The result has to state the post-state, not just "done" — a success with
	// no derived state is what let a wrong mental model survive before.
	for _, want := range []string{"ALB", "EWR → Amsterdam", "ALB → Amsterdam", "still marked booked"} {
		if !strings.Contains(msg, want) {
			t.Errorf("result does not state %q: %s", want, msg)
		}
	}
	if !strings.Contains(msg, "Do NOT add a checklist item") {
		t.Errorf("result must warn off the duplicate that caused this bug: %s", msg)
	}

	_, dep, arr := tripEndpointsOf(t, tripID)
	if dep == nil || *dep != "ALB" || arr == nil || *arr != "ALB" {
		t.Fatalf("stored endpoints = %v/%v, want ALB/ALB (one stated airport states both)", dep, arr)
	}

	rec := doJSON(t, "GET", base, token, nil)
	after := decodeTodoListFromTrip(t, rec)
	if len(after) != 3 {
		t.Fatalf("rows = %d, want 3 — a duplicate means the leg was recreated: %v", len(after), after)
	}
	if after[0]["id"] != outboundID {
		t.Fatalf("departure leg was replaced rather than renamed: %v", after[0])
	}
	if after[0]["title"] != "ALB → Amsterdam" || after[0]["booked"] != true {
		t.Fatalf("departure leg wrong after rename: %v", after[0])
	}
	if after[2]["title"] != "Amsterdam → ALB" {
		t.Fatalf("return leg did not follow: %v", after[2])
	}
	// A per-trip origin never touches the standing preference.
	rec = doJSON(t, "GET", "/api/v1/preferences", token, nil)
	if home := decode(t, rec)["home_airport"]; home != "EWR" {
		t.Fatalf("saved home airport = %v, want EWR untouched", home)
	}
}

// Out of ALB, home into EWR: both columns are written, and only the departure
// leg is renamed.
func TestSetTripOriginAsymmetricEndpoints(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "asym@example.com")
	trip := createTestTrip(t, user.ID, 0)
	tripID := trip.ID.String()

	if rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{"home_airport": "EWR"}); rec.Code != http.StatusOK {
		t.Fatalf("save home airport = %d", rec.Code)
	}
	rows := syncHomeLegs(t, tripID, token, "EWR", "Amsterdam")
	returnID := rows[2]["id"].(string)

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	msg, isErr := runSetTripOriginTool(s, []byte(`{"airport":"ALB","return_airport":"EWR"}`))
	if isErr {
		t.Fatalf("set_trip_origin errored: %s", msg)
	}
	if !strings.Contains(msg, "different airport") {
		t.Errorf("result must call out the asymmetry: %s", msg)
	}
	_, dep, arr := tripEndpointsOf(t, tripID)
	if dep == nil || *dep != "ALB" || arr == nil || *arr != "EWR" {
		t.Fatalf("endpoints = %v/%v, want ALB/EWR", dep, arr)
	}

	rec := doJSON(t, "GET", "/api/v1/trips/"+tripID, token, nil)
	after := decodeTodoListFromTrip(t, rec)
	if after[0]["title"] != "ALB → Amsterdam" {
		t.Fatalf("departure did not move: %v", after[0])
	}
	if after[2]["id"] != returnID || after[2]["title"] != "Amsterdam → EWR" {
		t.Fatalf("return leg must be untouched by a departure-only change: %v", after[2])
	}
}

// An airport is the wrong kind of origin for a drive. This is the "EWR →
// Montreal" incident migration 00062 was written for, so it must be refused
// outright rather than written and explained away.
func TestSetTripOriginRefusesAirportOnGroundTrip(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "ground@example.com")
	trip := createTestTrip(t, user.ID, 0)

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	s.travelMode = "car"
	msg, isErr := runSetTripOriginTool(s, []byte(`{"airport":"ALB"}`))
	if !isErr || !strings.Contains(msg, "place") {
		t.Fatalf("ground trip + airport = %q (err=%v), want a refusal pointing at place", msg, isErr)
	}
	if _, dep, _ := tripEndpointsOf(t, trip.ID.String()); dep != nil {
		t.Fatalf("a refused call must write nothing, got %v", *dep)
	}

	// And again with the mode only in the DATABASE, not the session — a later
	// turn of a fresh chat has an empty session mode, and the refusal must not
	// depend on whether they happened to say "we're driving" this conversation.
	if rec := doJSON(t, "PATCH", "/api/v1/trips/"+trip.ID.String(), token,
		map[string]any{"travel_mode": "car"}); rec.Code != http.StatusOK {
		t.Fatalf("set travel mode = %d: %s", rec.Code, rec.Body.String())
	}
	s2, _ := testPlanSession(true, user.ID)
	s2.boundTripID = &trip.ID
	if msg, isErr := runSetTripOriginTool(s2, []byte(`{"airport":"ALB"}`)); !isErr || !strings.Contains(msg, "place") {
		t.Fatalf("saved ground mode + airport = %q (err=%v), want a refusal", msg, isErr)
	}

	// The free-text origin is the right field, and it works on a car trip.
	msg, isErr = runSetTripOriginTool(s, []byte(`{"place":"Lake George, NY"}`))
	if isErr {
		t.Fatalf("place on a ground trip errored: %s", msg)
	}
	origin, dep, arr := tripEndpointsOf(t, trip.ID.String())
	if origin == nil || *origin != "Lake George, NY" || dep != nil || arr != nil {
		t.Fatalf("endpoints = %v/%v/%v, want the stated place and no airports", origin, dep, arr)
	}
}

// Guards, and the atomicity that keeps a typo from half-changing a trip.
func TestSetTripOriginGuards(t *testing.T) {
	s, _ := testPlanSession(false, uuid.Nil)
	if msg, isErr := runSetTripOriginTool(s, []byte(`{"airport":"ALB"}`)); !isErr || !strings.Contains(msg, "signed in") {
		t.Fatalf("anonymous = %q (err=%v)", msg, isErr)
	}

	resetDB(t)
	user, _ := createTestUser(t, "guards@example.com")
	trip := createTestTrip(t, user.ID, 0)
	s2, _ := testPlanSession(true, user.ID)
	s2.boundTripID = &trip.ID

	if msg, isErr := runSetTripOriginTool(s2, []byte(`{}`)); !isErr || !strings.Contains(msg, "airport") {
		t.Fatalf("empty input = %q (err=%v)", msg, isErr)
	}
}

// resolveIATA waves ANY three letters through — it is built for flight search,
// where a wrong code just returns no offers. Here a bad code would title a leg
// and then silently never pin on the map, so the tool confirms it against the
// airport lookup first. With no provider configured it has to fall back to
// trusting the input: a provider outage must not stop a traveler saying where
// they leave from.
func TestSetTripOriginConfirmsTheCodeIsReal(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "realcode@example.com")
	trip := createTestTrip(t, user.ID, 0)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Duffel's place suggestions: ALB exists, XQZ matches nothing.
		if strings.Contains(r.URL.RawQuery, "ALB") {
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"data":[{"id":"arp_alb","name":"Albany International Airport","iata_code":"ALB","type":"airport"}]}`))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"data":[]}`))
	}))
	t.Cleanup(srv.Close)
	old := duffelService
	duffelService = &DuffelService{
		Token: "test-token", BaseURL: srv.URL, Version: "v2",
		Client:      &http.Client{Timeout: 5 * time.Second},
		placesCache: newTTLCache[[]Airport](time.Minute, 10),
	}
	t.Cleanup(func() { duffelService = old })

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &trip.ID
	if msg, isErr := runSetTripOriginTool(s, []byte(`{"airport":"XQZ"}`)); !isErr {
		t.Fatalf("unresolvable code accepted: %s", msg)
	}
	if _, dep, _ := tripEndpointsOf(t, trip.ID.String()); dep != nil {
		t.Fatalf("a rejected code must write nothing, got %v", *dep)
	}
	if msg, isErr := runSetTripOriginTool(s, []byte(`{"airport":"ALB"}`)); isErr {
		t.Fatalf("a real code was rejected: %s", msg)
	}
	if _, dep, _ := tripEndpointsOf(t, trip.ID.String()); dep == nil || *dep != "ALB" {
		t.Fatalf("endpoint = %v, want ALB", dep)
	}
}

// A trip that doesn't exist yet: the endpoints ride on the session into
// create_itinerary, exactly as a stated travel mode does. Dropping them here is
// how they would vanish at the next version save.
func TestSetTripOriginCarriesToCreateItinerary(t *testing.T) {
	resetDB(t)
	user, _ := createTestUser(t, "carry@example.com")

	s, _ := testPlanSession(true, user.ID)
	msg, isErr := runSetTripOriginTool(s, []byte(`{"airport":"ALB"}`))
	if isErr {
		t.Fatalf("unsaved trip errored: %s", msg)
	}
	if !strings.Contains(msg, "stored with the itinerary") {
		t.Errorf("result must say it is not saved yet: %s", msg)
	}
	if s.endpoints.OriginAirport != "ALB" {
		t.Fatalf("session endpoints = %+v, want ALB carried", s.endpoints)
	}

	tripID, _, err := persistTrip(context.Background(), user.ID, "chat-carry",
		"Amsterdam", "", "", "", "", s.endpoints,
		[]map[string]any{{"name": "Rijksmuseum", "city": "Amsterdam"}})
	if err != nil {
		t.Fatalf("persistTrip: %v", err)
	}
	if _, dep, arr := tripEndpointsOf(t, tripID); dep == nil || *dep != "ALB" || arr == nil || *arr != "ALB" {
		t.Fatalf("endpoints lost at persist: %v/%v", dep, arr)
	}
}

// get_trip must show the endpoints — the model improvised precisely because it
// could not see them, and "not stated" has to be distinguishable from a code.
func TestTripEndpointSummaryIsExplicitAboutAbsence(t *testing.T) {
	ptr := func(s string) *string { return &s }
	cases := []struct {
		name string
		trip store.Trip
		want string
	}{
		{"asymmetric", store.Trip{OriginAirport: ptr("ALB"), ReturnAirport: ptr("EWR")}, "Departs from ALB and returns to EWR"},
		{"symmetric", store.Trip{OriginAirport: ptr("ALB"), ReturnAirport: ptr("ALB")}, "departs from and returns to ALB"},
		{"stated place", store.Trip{Origin: ptr("Lake George, NY")}, "no airport, so no map pin"},
		{"nothing stated", store.Trip{}, "not stated for this trip"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := tripEndpointSummary(tc.trip)
			if !strings.Contains(strings.ToLower(got), strings.ToLower(tc.want)) {
				t.Fatalf("summary = %q, want it to mention %q", got, tc.want)
			}
		})
	}
}
