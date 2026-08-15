package main

// PUT /trips/{id}/endpoints (specs/trip-endpoint-airports, wave 2): the trip
// page's way to change where a trip departs from and returns into. The headline
// case is the friction that produced it — on the page, the only affordance on a
// derived "EWR → Amsterdam" row was "Add details…", which posts a segment, so
// correcting the airport there produced a SECOND row contradicting the first.

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"travel-route-planner/store"
)

func putEndpoints(t *testing.T, tripID, token string, body any) *httptest.ResponseRecorder {
	t.Helper()
	return doJSON(t, "PUT", "/api/v1/trips/"+tripID+"/endpoints", token, body)
}

// legTitles reads the checklist the way a client does.
func legTitles(t *testing.T, tripID, token string) []map[string]any {
	t.Helper()
	return decodeTodoListFromTrip(t, doJSON(t, "GET", "/api/v1/trips/"+tripID, token, nil))
}

// The reported friction, end to end: from the trip page, change the departure
// airport. The existing derived leg must be RENAMED — keeping everything the
// traveler invested in it — and no second row may appear.
func TestPutTripEndpointsRenamesTheDepartureLegInPlace(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "endpointspage@example.com")
	trip := createTestTrip(t, user.ID, 0)
	tripID := trip.ID.String()
	base := "/api/v1/trips/" + tripID

	if rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{"home_airport": "EWR"}); rec.Code != http.StatusOK {
		t.Fatalf("save home airport = %d", rec.Code)
	}
	rows := syncHomeLegs(t, tripID, token, "EWR", "Amsterdam")
	outboundID, returnID := rows[0]["id"].(string), rows[2]["id"].(string)

	// Everything a traveler can invest in a row: booked, a per-leg mode, and a
	// budget expense linked to it.
	if rec := doJSON(t, "PATCH", base+"/booking-todos/"+outboundID, token, map[string]any{"booked": true}); rec.Code != http.StatusOK {
		t.Fatalf("book outbound = %d: %s", rec.Code, rec.Body.String())
	}
	if rec := doJSON(t, "PATCH", base+"/booking-todos/"+outboundID, token, map[string]any{
		"mode": "train", "origin": "EWR", "destination": "Amsterdam", "depart_date": "2026-09-01",
	}); rec.Code != http.StatusOK {
		t.Fatalf("set mode = %d: %s", rec.Code, rec.Body.String())
	}
	rec := doJSON(t, "POST", base+"/budget/expenses", token, map[string]any{
		"label": "EWR → Amsterdam", "category": "flights", "amount": 344,
		"source_kind": "booking_todo", "source_id": outboundID})
	if rec.Code != http.StatusCreated {
		t.Fatalf("link expense = %d: %s", rec.Code, rec.Body.String())
	}
	expenseID := decode(t, rec)["id"].(string)

	rec = putEndpoints(t, tripID, token, map[string]any{
		"origin_airport": "ALB", "return_airport": "ALB"})
	if rec.Code != http.StatusOK {
		t.Fatalf("put endpoints = %d: %s", rec.Code, rec.Body.String())
	}
	// The response states the post-state, not just "done": which airports the
	// trip now holds and exactly which rows moved, booked state included.
	body := decode(t, rec)
	if body["origin_airport"] != "ALB" || body["return_airport"] != "ALB" {
		t.Fatalf("response does not state the stored endpoints: %v", body)
	}
	renamed, _ := body["legs_renamed"].([]any)
	if len(renamed) != 2 {
		t.Fatalf("legs_renamed = %v, want both home legs", body["legs_renamed"])
	}
	first, _ := renamed[0].(map[string]any)
	if first["before"] != "EWR → Amsterdam" || first["after"] != "ALB → Amsterdam" || first["booked"] != true {
		t.Fatalf("renamed leg not described honestly: %v", first)
	}

	_, dep, arr := tripEndpointsOf(t, tripID)
	if dep == nil || *dep != "ALB" || arr == nil || *arr != "ALB" {
		t.Fatalf("stored endpoints = %v/%v, want ALB/ALB", dep, arr)
	}

	after := legTitles(t, tripID, token)
	if len(after) != 3 {
		t.Fatalf("rows = %d, want 3 — a duplicate is the bug this exists to end: %v", len(after), after)
	}
	if after[0]["id"] != outboundID || after[2]["id"] != returnID {
		t.Fatalf("a leg was replaced rather than renamed: %v", after)
	}
	if after[0]["title"] != "ALB → Amsterdam" || after[2]["title"] != "Amsterdam → ALB" {
		t.Fatalf("titles did not follow the airport: %v / %v", after[0]["title"], after[2]["title"])
	}
	if after[0]["booked"] != true || after[0]["mode"] != "train" {
		t.Fatalf("booked flag or per-leg mode lost: %v", after[0])
	}
	// And the money is still attached to a row that exists.
	rec = doJSON(t, "GET", base+"/budget/expenses", token, nil)
	var found bool
	for _, e := range decodeList(t, rec) {
		if e["id"] == expenseID && e["source_id"] == outboundID {
			found = true
		}
	}
	if !found {
		t.Fatalf("linked expense lost its row: %s", rec.Body.String())
	}
	// A per-trip airport never touches the standing preference.
	rec = doJSON(t, "GET", "/api/v1/preferences", token, nil)
	if home := decode(t, rec)["home_airport"]; home != "EWR" {
		t.Fatalf("saved home airport = %v, want EWR untouched", home)
	}
}

// The paired rule, on the wire. CHECK trips_endpoint_airport_pair makes "both
// or neither" a database invariant; the handler must refuse a one-sided body
// rather than let columns() quietly copy one end onto the other — that silent
// copy is how a client asking to change the outbound would rewrite the return
// leg too.
func TestPutTripEndpointsRefusesOneAirportWithoutTheOther(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "paired@example.com")
	trip := createTestTrip(t, user.ID, 0)
	tripID := trip.ID.String()
	syncHomeLegs(t, tripID, token, "EWR", "Amsterdam")

	for _, body := range []map[string]any{
		{"origin_airport": "ALB"},
		{"origin_airport": "ALB", "return_airport": nil},
		{"return_airport": "EWR"},
		{"origin_airport": "", "return_airport": "EWR"},
	} {
		rec := putEndpoints(t, tripID, token, body)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("one-sided body %v = %d, want 400: %s", body, rec.Code, rec.Body.String())
		}
		if _, dep, _ := tripEndpointsOf(t, tripID); dep != nil {
			t.Fatalf("a refused body wrote %v", *dep)
		}
	}
}

// Out of ALB, home into EWR. Then move ONLY the departure: the return leg keeps
// its id and its title, because the two directions are distinct rows.
func TestPutTripEndpointsAsymmetricAndIndependent(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "pageasym@example.com")
	trip := createTestTrip(t, user.ID, 0)
	tripID := trip.ID.String()

	if rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{"home_airport": "EWR"}); rec.Code != http.StatusOK {
		t.Fatalf("save home airport = %d", rec.Code)
	}
	rows := syncHomeLegs(t, tripID, token, "EWR", "Amsterdam")
	returnID := rows[2]["id"].(string)

	if rec := putEndpoints(t, tripID, token, map[string]any{
		"origin_airport": "ALB", "return_airport": "EWR"}); rec.Code != http.StatusOK {
		t.Fatalf("put asymmetric = %d: %s", rec.Code, rec.Body.String())
	}
	_, dep, arr := tripEndpointsOf(t, tripID)
	if dep == nil || *dep != "ALB" || arr == nil || *arr != "EWR" {
		t.Fatalf("endpoints = %v/%v, want ALB/EWR", dep, arr)
	}
	after := legTitles(t, tripID, token)
	if after[0]["title"] != "ALB → Amsterdam" {
		t.Fatalf("departure did not move: %v", after[0])
	}
	if after[2]["id"] != returnID || after[2]["title"] != "Amsterdam → EWR" {
		t.Fatalf("return leg must be untouched by a departure-only change: %v", after[2])
	}

	// Move the departure again; the return still must not follow.
	rec := putEndpoints(t, tripID, token, map[string]any{
		"origin_airport": "BOS", "return_airport": "EWR"})
	if rec.Code != http.StatusOK {
		t.Fatalf("second put = %d: %s", rec.Code, rec.Body.String())
	}
	renamed, _ := decode(t, rec)["legs_renamed"].([]any)
	if len(renamed) != 1 {
		t.Fatalf("legs_renamed = %v, want only the departure", renamed)
	}
	after = legTitles(t, tripID, token)
	if after[0]["title"] != "BOS → Amsterdam" || after[2]["title"] != "Amsterdam → EWR" {
		t.Fatalf("second change disturbed the wrong leg: %v / %v", after[0]["title"], after[2]["title"])
	}
}

// "Use my home airport instead": both cleared, and the legs fall back down the
// ladder rather than freezing on the last code the trip held.
func TestPutTripEndpointsClearsBackToTheFallback(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "clearendpoints@example.com")
	trip := createTestTrip(t, user.ID, 0)
	tripID := trip.ID.String()

	if rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{"home_airport": "EWR"}); rec.Code != http.StatusOK {
		t.Fatalf("save home airport = %d", rec.Code)
	}
	syncHomeLegs(t, tripID, token, "EWR", "Amsterdam")
	if rec := putEndpoints(t, tripID, token, map[string]any{
		"origin_airport": "ALB", "return_airport": "ALB"}); rec.Code != http.StatusOK {
		t.Fatalf("set = %d: %s", rec.Code, rec.Body.String())
	}

	rec := putEndpoints(t, tripID, token, map[string]any{
		"origin_airport": nil, "return_airport": nil})
	if rec.Code != http.StatusOK {
		t.Fatalf("clear = %d: %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	if body["origin_airport"] != nil || body["return_airport"] != nil {
		t.Fatalf("response must state the cleared post-state: %v", body)
	}
	_, dep, arr := tripEndpointsOf(t, tripID)
	if dep != nil || arr != nil {
		t.Fatalf("endpoints = %v/%v, want both null", dep, arr)
	}
	after := legTitles(t, tripID, token)
	if after[0]["title"] != "EWR → Amsterdam" || after[2]["title"] != "Amsterdam → EWR" {
		t.Fatalf("legs did not fall back to the saved home airport: %v / %v", after[0]["title"], after[2]["title"])
	}
}

// Nobody sets out for a drive from a terminal — the "EWR → Montreal" incident
// migration 00062 was written for. The page must be refused exactly as the chat
// is, and write nothing.
func TestPutTripEndpointsRefusesAirportOnGroundTrip(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "pageground@example.com")
	trip := createTestTrip(t, user.ID, 0)
	tripID := trip.ID.String()
	if rec := doJSON(t, "PATCH", "/api/v1/trips/"+tripID, token, map[string]any{"travel_mode": "car"}); rec.Code != http.StatusOK {
		t.Fatalf("set travel mode = %d: %s", rec.Code, rec.Body.String())
	}

	rec := putEndpoints(t, tripID, token, map[string]any{
		"origin_airport": "ALB", "return_airport": "ALB"})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("ground trip + airport = %d, want 422: %s", rec.Code, rec.Body.String())
	}
	if msg, _ := decode(t, rec)["message"].(string); !strings.Contains(strings.ToLower(msg), "car") {
		t.Fatalf("refusal must name the mode: %q", msg)
	}
	if _, dep, _ := tripEndpointsOf(t, tripID); dep != nil {
		t.Fatalf("a refused ground trip wrote %v", *dep)
	}
}

// resolveIATA passes any three letters straight through, so a code is confirmed
// against the airport lookup before it can title a leg the map will never pin.
func TestPutTripEndpointsConfirmsTheCodeIsReal(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "pagerealcode@example.com")
	trip := createTestTrip(t, user.ID, 0)
	tripID := trip.ID.String()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.Contains(r.URL.RawQuery, "ALB") {
			w.Write([]byte(`{"data":[{"id":"arp_alb","name":"Albany International Airport","iata_code":"ALB","type":"airport"}]}`))
			return
		}
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

	rec := putEndpoints(t, tripID, token, map[string]any{
		"origin_airport": "XQZ", "return_airport": "XQZ"})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("unresolvable code = %d, want 422: %s", rec.Code, rec.Body.String())
	}
	if msg, _ := decode(t, rec)["message"].(string); !strings.Contains(msg, "XQZ") {
		t.Fatalf("refusal must name what was typed: %q", msg)
	}
	if _, dep, _ := tripEndpointsOf(t, tripID); dep != nil {
		t.Fatalf("a rejected code wrote %v", *dep)
	}

	// A return airport that resolves to nothing must not leave the departure
	// half-written either.
	if rec := putEndpoints(t, tripID, token, map[string]any{
		"origin_airport": "ALB", "return_airport": "XQZ"}); rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("bad return airport = %d, want 422: %s", rec.Code, rec.Body.String())
	}
	if _, dep, _ := tripEndpointsOf(t, tripID); dep != nil {
		t.Fatalf("a rejected return airport half-wrote %v", *dep)
	}

	if rec := putEndpoints(t, tripID, token, map[string]any{
		"origin_airport": "ALB", "return_airport": "ALB"}); rec.Code != http.StatusOK {
		t.Fatalf("a real code was rejected: %s", rec.Body.String())
	}
}

// The same authorization every other trip mutation uses: a non-member gets the
// same 404 they get everywhere else.
func TestPutTripEndpointsRefusesANonMember(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "endpointsowner@example.com")
	_, strangerToken := createTestUser(t, "endpointsstranger@example.com")
	trip := createTestTrip(t, owner.ID, 0)

	if rec := putEndpoints(t, trip.ID.String(), strangerToken, map[string]any{
		"origin_airport": "ALB", "return_airport": "ALB"}); rec.Code != http.StatusNotFound {
		t.Fatalf("stranger = %d, want 404: %s", rec.Code, rec.Body.String())
	}
	if _, dep, _ := tripEndpointsOf(t, trip.ID.String()); dep != nil {
		t.Fatalf("a stranger wrote %v", *dep)
	}
}

// The parity contract for the extraction: the chat tool and the page's PUT call
// ONE implementation, so the same input has to leave two trips in the same
// state. Two paths that can disagree is the failure mode 00064 exists to end.
func TestPageAndChatWriteTheSameEndpoints(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "parityendpoints@example.com")
	if rec := doJSON(t, "PUT", "/api/v1/preferences", token, map[string]any{"home_airport": "EWR"}); rec.Code != http.StatusOK {
		t.Fatalf("save home airport = %d", rec.Code)
	}

	viaChat := createTestTrip(t, user.ID, 0)
	viaPage := createTestTrip(t, user.ID, 0)
	for _, trip := range []store.Trip{viaChat, viaPage} {
		syncHomeLegs(t, trip.ID.String(), token, "EWR", "Amsterdam")
	}

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &viaChat.ID
	if msg, isErr := runSetTripOriginTool(s, []byte(`{"airport":"ALB","return_airport":"BOS"}`)); isErr {
		t.Fatalf("set_trip_origin errored: %s", msg)
	}
	if rec := putEndpoints(t, viaPage.ID.String(), token, map[string]any{
		"origin_airport": "ALB", "return_airport": "BOS"}); rec.Code != http.StatusOK {
		t.Fatalf("put endpoints = %d: %s", rec.Code, rec.Body.String())
	}

	_, chatDep, chatArr := tripEndpointsOf(t, viaChat.ID.String())
	_, pageDep, pageArr := tripEndpointsOf(t, viaPage.ID.String())
	if strPtrVal(chatDep) != strPtrVal(pageDep) || strPtrVal(chatArr) != strPtrVal(pageArr) {
		t.Fatalf("stored endpoints diverge: chat %v/%v vs page %v/%v", chatDep, chatArr, pageDep, pageArr)
	}
	chatRows := legTitles(t, viaChat.ID.String(), token)
	pageRows := legTitles(t, viaPage.ID.String(), token)
	if len(chatRows) != len(pageRows) {
		t.Fatalf("row counts diverge: %d vs %d", len(chatRows), len(pageRows))
	}
	for i := range chatRows {
		if chatRows[i]["title"] != pageRows[i]["title"] || chatRows[i]["role"] != pageRows[i]["role"] {
			t.Fatalf("row %d diverges: chat %v/%v vs page %v/%v", i,
				chatRows[i]["title"], chatRows[i]["role"], pageRows[i]["title"], pageRows[i]["role"])
		}
	}
}

// The client decides which rows can offer "change departure airport" from the
// role the SERVER already stores as identity. Without it on the wire it would
// re-infer which row is the flight home — and be wrong in exactly the case the
// server handles, where a key collision demotes a home leg to inter_city.
func TestBookingTodoResponseCarriesTheLegRole(t *testing.T) {
	resetDB(t)
	user, token := createTestUser(t, "legrole@example.com")
	trip := createTestTrip(t, user.ID, 0)
	rows := syncHomeLegs(t, trip.ID.String(), token, "EWR", "Amsterdam")

	want := []string{roleHomeOutbound, roleStay, roleHomeReturn}
	for i, w := range want {
		if rows[i]["role"] != w {
			t.Fatalf("row %d role = %v, want %q: %v", i, rows[i]["role"], w, rows[i])
		}
	}
	// And it survives the trip read the page actually loads.
	for i, row := range legTitles(t, trip.ID.String(), token) {
		if row["role"] != want[i] {
			t.Fatalf("trip response row %d role = %v, want %q", i, row["role"], want[i])
		}
	}
}
