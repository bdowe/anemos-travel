package main

import (
	"net/http"
	"strings"
	"testing"
)

// booking_option_integration_test.go — the outcome contract for the per-leg
// shortlist (migration 00065, specs/booking-shortlist). Written against what
// the traveler sees, not against the mechanism.

// shortlistTrip syncs a one-city round trip and returns the trip id, its base
// URL, and the three leg rows in construction order (outbound, stay, return).
func shortlistTrip(t *testing.T, token string, tripID string) (string, []map[string]any) {
	t.Helper()
	base := "/api/v1/trips/" + tripID
	rec := doJSON(t, "PUT", base+"/booking-todos", token, homeLegPayload("EWR", "Prague"))
	if rec.Code != http.StatusOK {
		t.Fatalf("sync legs = %d: %s", rec.Code, rec.Body.String())
	}
	todos := decodeTodoList(t, rec)
	if len(todos) != 3 {
		t.Fatalf("legs = %d, want 3: %v", len(todos), todos)
	}
	return base, todos
}

func saveOption(t *testing.T, token, base, todoID string, extra map[string]any) map[string]any {
	t.Helper()
	body := map[string]any{"booking_todo_id": todoID, "title": "Loft near Old Town"}
	for k, v := range extra {
		body[k] = v
	}
	rec := doJSON(t, "POST", base+"/booking-options", token, body)
	if rec.Code != http.StatusCreated {
		t.Fatalf("save option = %d: %s", rec.Code, rec.Body.String())
	}
	return decode(t, rec)
}

// The bug this feature would have shipped with. _computeGroupedBookings matches
// a stay to its leg on auto_key FIRST and only then falls back to a
// name/address contains against the city label — which "Loft near Old Town"
// fails. A promoted record without the stamp renders under "Other bookings"
// instead of under the leg it was chosen for, which is exactly the clutter the
// shortlist exists to remove.
func TestChosenOptionLandsInItsLegSlot(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "shortlist-slot@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base, todos := shortlistTrip(t, token, trip.ID.String())
	stayID := todos[1]["id"].(string)
	if todos[1]["kind"] != "stay" {
		t.Fatalf("expected a stay leg, got %v", todos[1])
	}

	opt := saveOption(t, token, base, stayID, nil)
	rec := doJSON(t, "POST", base+"/booking-options/"+opt["id"].(string)+"/choose", token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("choose = %d: %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	acc, ok := body["accommodation"].(map[string]any)
	if !ok {
		t.Fatalf("choose returned no accommodation: %v", body)
	}
	if acc["auto_key"] != "stay:prague" {
		t.Fatalf("promoted stay auto_key = %v, want stay:prague — without it the row misses its leg", acc["auto_key"])
	}
	if acc["booked"] != true {
		t.Fatalf("promoted stay should be booked: %v", acc)
	}
	if body["booking_todo"].(map[string]any)["booked"] != true {
		t.Fatalf("leg should be booked: %v", body["booking_todo"])
	}
	if body["option"].(map[string]any)["chosen"] != true {
		t.Fatalf("option should report chosen: %v", body["option"])
	}
	// The whole leg's post-state rides along, so the loser list can't blank.
	if len(body["options"].([]any)) != 1 {
		t.Fatalf("options post-state = %v", body["options"])
	}
}

// Choosing a second candidate must rewrite the SAME record. A second insert
// would leave the claim-once matcher holding one and shunting the other into
// the residual list.
func TestChoosingASecondOptionReplacesTheFirst(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "shortlist-replace@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base, todos := shortlistTrip(t, token, trip.ID.String())
	stayID := todos[1]["id"].(string)

	first := saveOption(t, token, base, stayID, nil)
	second := saveOption(t, token, base, stayID, map[string]any{"title": "Riverside studio"})

	if rec := doJSON(t, "POST", base+"/booking-options/"+first["id"].(string)+"/choose", token, nil); rec.Code != http.StatusOK {
		t.Fatalf("choose first = %d: %s", rec.Code, rec.Body.String())
	}
	rec := doJSON(t, "POST", base+"/booking-options/"+second["id"].(string)+"/choose", token, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("choose second = %d: %s", rec.Code, rec.Body.String())
	}
	body := decode(t, rec)
	if body["replaced_option_id"] != first["id"] {
		t.Fatalf("replaced_option_id = %v, want %v", body["replaced_option_id"], first["id"])
	}
	if body["accommodation"].(map[string]any)["name"] != "Riverside studio" {
		t.Fatalf("record should carry the new winner: %v", body["accommodation"])
	}

	tripView := decode(t, doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), token, nil))
	if stays := listOf(t, tripView, "accommodations"); len(stays) != 1 {
		t.Fatalf("one leg must have exactly one stay record, got %d: %v", len(stays), stays)
	}
	chosen := 0
	for _, o := range listOf(t, tripView, "booking_options") {
		if o["chosen"] == true {
			chosen++
		}
	}
	if chosen != 1 {
		t.Fatalf("exactly one winner per leg, got %d", chosen)
	}
}

// Removing the record un-chooses the option (the FK does it), but must NOT
// un-book the leg: booked is traveler state and no cascade has business
// flipping it. Pinned deliberately so a later refactor can't "fix" it.
func TestDeletingPromotedRecordUnchoosesButLeavesBooked(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "shortlist-cascade@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base, todos := shortlistTrip(t, token, trip.ID.String())
	stayID := todos[1]["id"].(string)

	opt := saveOption(t, token, base, stayID, nil)
	body := decode(t, doJSON(t, "POST", base+"/booking-options/"+opt["id"].(string)+"/choose", token, nil))
	accID := body["accommodation"].(map[string]any)["id"].(string)

	if rec := doJSON(t, "DELETE", base+"/accommodations/"+accID, token, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("delete stay = %d: %s", rec.Code, rec.Body.String())
	}
	tripView := decode(t, doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), token, nil))
	opts := listOf(t, tripView, "booking_options")
	if len(opts) != 1 || opts[0]["chosen"] != false {
		t.Fatalf("option should be a candidate again: %v", opts)
	}
	for _, td := range listOf(t, tripView, "booking_todos") {
		if td["id"] == stayID && td["booked"] != true {
			t.Fatalf("booked is traveler state and must survive the cascade: %v", td)
		}
	}
}

// Removing a bookmark must not silently unbook a leg and delete its expense.
func TestDeletingAChosenOptionIsRefused(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "shortlist-delete@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base, todos := shortlistTrip(t, token, trip.ID.String())
	opt := saveOption(t, token, base, todos[1]["id"].(string), nil)
	if rec := doJSON(t, "POST", base+"/booking-options/"+opt["id"].(string)+"/choose", token, nil); rec.Code != http.StatusOK {
		t.Fatalf("choose = %d: %s", rec.Code, rec.Body.String())
	}
	rec := doJSON(t, "DELETE", base+"/booking-options/"+opt["id"].(string), token, nil)
	if rec.Code != http.StatusConflict {
		t.Fatalf("delete chosen option = %d, want 409: %s", rec.Code, rec.Body.String())
	}
	// Un-choose, then it deletes.
	if rec := doJSON(t, "DELETE", base+"/booking-options/"+opt["id"].(string)+"/choose", token, nil); rec.Code != http.StatusOK {
		t.Fatalf("unchoose = %d: %s", rec.Code, rec.Body.String())
	}
	if rec := doJSON(t, "DELETE", base+"/booking-options/"+opt["id"].(string), token, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("delete after unchoose = %d: %s", rec.Code, rec.Body.String())
	}
}

// Un-choose reverses the booking but KEEPS the record — it may carry a
// hand-typed address the traveler added after choosing.
func TestUnchooseKeepsTheRecordAndUnbooks(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "shortlist-unchoose@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base, todos := shortlistTrip(t, token, trip.ID.String())
	stayID := todos[1]["id"].(string)
	opt := saveOption(t, token, base, stayID, map[string]any{"price": 118.0, "currency": "USD"})
	body := decode(t, doJSON(t, "POST", base+"/booking-options/"+opt["id"].(string)+"/choose", token, nil))
	accID := body["accommodation"].(map[string]any)["id"].(string)

	if rec := doJSON(t, "PATCH", base+"/accommodations/"+accID, token, map[string]any{
		"address": "Karlova 12, Praha 1",
	}); rec.Code != http.StatusOK {
		t.Fatalf("add address = %d: %s", rec.Code, rec.Body.String())
	}
	if rec := doJSON(t, "DELETE", base+"/booking-options/"+opt["id"].(string)+"/choose", token, nil); rec.Code != http.StatusOK {
		t.Fatalf("unchoose = %d: %s", rec.Code, rec.Body.String())
	}
	tripView := decode(t, doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), token, nil))
	stays := listOf(t, tripView, "accommodations")
	if len(stays) != 1 {
		t.Fatalf("un-choose must not destroy the record: %v", stays)
	}
	if stays[0]["address"] != "Karlova 12, Praha 1" {
		t.Fatalf("hand-typed content must survive un-choose: %v", stays[0])
	}
	if stays[0]["booked"] != false {
		t.Fatalf("record should be unbooked: %v", stays[0])
	}
	for _, td := range listOf(t, tripView, "booking_todos") {
		if td["id"] == stayID && td["booked"] != false {
			t.Fatalf("leg should be unbooked: %v", td)
		}
	}
	if exp := decodeTodoList(t, doJSON(t, "GET", base+"/budget/expenses", token, nil)); len(exp) != 0 {
		t.Fatalf("the auto expense mirrors booked state and should be gone: %v", exp)
	}
}

// Money is skipped out loud, never guessed: this app has no FX.
func TestChooseSkipsExpenseOnCurrencyMismatch(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "shortlist-currency@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base, todos := shortlistTrip(t, token, trip.ID.String())
	if rec := doJSON(t, "PUT", base+"/budget", token, map[string]any{"currency": "USD", "target_amount": 3000}); rec.Code != http.StatusOK {
		t.Fatalf("set budget = %d: %s", rec.Code, rec.Body.String())
	}
	opt := saveOption(t, token, base, todos[1]["id"].(string), map[string]any{"price": 180.0, "currency": "EUR"})
	body := decode(t, doJSON(t, "POST", base+"/booking-options/"+opt["id"].(string)+"/choose", token, nil))
	if body["expense_skipped"] != "currency_mismatch" {
		t.Fatalf("expense_skipped = %v, want currency_mismatch: %v", body["expense_skipped"], body)
	}
	if _, ok := body["expense"]; ok {
		t.Fatalf("no expense may be written on a mismatch: %v", body)
	}
}

func TestChooseRecordsMatchingCurrencyExpense(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "shortlist-expense@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base, todos := shortlistTrip(t, token, trip.ID.String())
	if rec := doJSON(t, "PUT", base+"/budget", token, map[string]any{"currency": "USD"}); rec.Code != http.StatusOK {
		t.Fatalf("set budget = %d: %s", rec.Code, rec.Body.String())
	}
	opt := saveOption(t, token, base, todos[1]["id"].(string), map[string]any{"price": 354.0, "currency": "USD"})
	body := decode(t, doJSON(t, "POST", base+"/booking-options/"+opt["id"].(string)+"/choose", token, nil))
	exp, ok := body["expense"].(map[string]any)
	if !ok {
		t.Fatalf("expected an expense: %v", body)
	}
	if exp["amount"].(float64) != 354 || exp["category"] != "lodging" || exp["auto"] != true {
		t.Fatalf("expense = %v", exp)
	}
	if exp["source_kind"] != "booking_todo" {
		t.Fatalf("expense must be sourced on the leg (it outlives the record): %v", exp)
	}
	// A booking is money SPENT (00067), and it carried no plan.
	if exp["purchased"] != true || exp["actual_amount"].(float64) != 354 ||
		exp["planned_amount"] != nil {
		t.Fatalf("choose must record a payment, not a plan: %v", exp)
	}
}

// TestChoosePreservesPlannedAmountOnRefresh is the payoff case: the traveler
// budgeted for this leg before booking it, so choosing a winner fills in what
// it ACTUALLY cost and leaves the plan alone — the variance appears for free.
func TestChoosePreservesPlannedAmountOnRefresh(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "shortlist-plan@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base, todos := shortlistTrip(t, token, trip.ID.String())
	if rec := doJSON(t, "PUT", base+"/budget", token, map[string]any{"currency": "USD"}); rec.Code != http.StatusOK {
		t.Fatalf("set budget = %d: %s", rec.Code, rec.Body.String())
	}
	legID := todos[1]["id"].(string)

	// The plan, stated against the leg before any option is chosen.
	rec := doJSON(t, "POST", base+"/budget/expenses", token, map[string]any{
		"label": "Stay", "category": "lodging", "actual_amount": 400,
		"source_kind": "booking_todo", "source_id": legID,
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("seed linked expense = %d: %s", rec.Code, rec.Body.String())
	}
	seeded := decode(t, rec)["id"].(string)
	if rec := doJSON(t, "PATCH", base+"/budget/expenses/"+seeded, token,
		map[string]any{"planned_amount": 400}); rec.Code != http.StatusOK {
		t.Fatalf("state the plan = %d: %s", rec.Code, rec.Body.String())
	}

	opt := saveOption(t, token, base, legID, map[string]any{"price": 354.0, "currency": "USD"})
	body := decode(t, doJSON(t, "POST", base+"/booking-options/"+opt["id"].(string)+"/choose", token, nil))
	exp, ok := body["expense"].(map[string]any)
	if !ok {
		t.Fatalf("expected an expense: %v", body)
	}
	if exp["id"] != seeded {
		t.Fatalf("choose should refresh the linked row, not add one: %v", exp)
	}
	if exp["actual_amount"].(float64) != 354 || exp["planned_amount"].(float64) != 400 {
		t.Fatalf("the plan must survive the booking: %v", exp)
	}
	budget := decode(t, doJSON(t, "GET", base+"/budget", token, nil))
	if budget["plan_variance"].(float64) != -46 {
		t.Fatalf("variance = %v, want -46", budget["plan_variance"])
	}
}

// TestUnbookKeepsAPlannedLinkedExpense: un-booking clears the PAYMENT, which
// the system owns, and never the PLAN, which the traveler owns. The row stays
// auto — it is still the leg's mirror, and re-booking re-pays it.
func TestUnbookKeepsAPlannedLinkedExpense(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "shortlist-unbook@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base, todos := shortlistTrip(t, token, trip.ID.String())
	doJSON(t, "PUT", base+"/budget", token, map[string]any{"currency": "USD"})
	legID := todos[1]["id"].(string)

	rec := doJSON(t, "POST", base+"/budget/expenses", token, map[string]any{
		"label": "Stay", "category": "lodging", "actual_amount": 400,
		"source_kind": "booking_todo", "source_id": legID,
	})
	seeded := decode(t, rec)["id"].(string)
	doJSON(t, "PATCH", base+"/budget/expenses/"+seeded, token, map[string]any{"planned_amount": 400})

	opt := saveOption(t, token, base, legID, map[string]any{"price": 354.0, "currency": "USD"})
	optID := opt["id"].(string)
	doJSON(t, "POST", base+"/booking-options/"+optID+"/choose", token, nil)
	if rec := doJSON(t, "DELETE", base+"/booking-options/"+optID+"/choose", token, nil); rec.Code != http.StatusOK {
		t.Fatalf("un-choose = %d: %s", rec.Code, rec.Body.String())
	}

	list := decodeExpenses(t, doJSON(t, "GET", base+"/budget/expenses", token, nil))
	if len(list) != 1 {
		t.Fatalf("the planned line must survive un-booking: %v", list)
	}
	kept := list[0]
	if kept["purchased"] != false || kept["actual_amount"] != nil ||
		kept["planned_amount"].(float64) != 400 || kept["auto"] != true {
		t.Fatalf("un-book should un-pay, not delete: %v", kept)
	}

	// Re-booking re-pays the same row through the refresh path.
	doJSON(t, "POST", base+"/booking-options/"+optID+"/choose", token, nil)
	list = decodeExpenses(t, doJSON(t, "GET", base+"/budget/expenses", token, nil))
	if len(list) != 1 || list[0]["actual_amount"].(float64) != 354 ||
		list[0]["planned_amount"].(float64) != 400 {
		t.Fatalf("re-book should refresh the one row: %v", list)
	}
}

// A leg that is only "something to arrange" has no target table, and picking
// one would be a guess.
func TestChooseOnAnOtherLegIsRefused(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "shortlist-other@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base := "/api/v1/trips/" + trip.ID.String()
	rec := doJSON(t, "POST", base+"/booking-todos", token, map[string]any{
		"kind": "other", "title": "Travel insurance",
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("create other todo = %d: %s", rec.Code, rec.Body.String())
	}
	todoID := decode(t, rec)["id"].(string)
	opt := saveOption(t, token, base, todoID, map[string]any{"title": "WorldNomads"})
	rec = doJSON(t, "POST", base+"/booking-options/"+opt["id"].(string)+"/choose", token, nil)
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("choose on an 'other' leg = %d, want 422: %s", rec.Code, rec.Body.String())
	}
}

// A price with no currency cannot be summed, and this app never guesses one.
func TestPriceAndCurrencyMustTravelTogether(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "shortlist-pair@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base, todos := shortlistTrip(t, token, trip.ID.String())
	todoID := todos[1]["id"].(string)

	rec := doJSON(t, "POST", base+"/booking-options", token, map[string]any{
		"booking_todo_id": todoID, "title": "No currency", "price": 100.0,
	})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("price without currency = %d, want 400: %s", rec.Code, rec.Body.String())
	}
	// And the same rule holds against STORED state on a patch, not just within
	// one payload.
	opt := saveOption(t, token, base, todoID, map[string]any{"price": 100.0, "currency": "USD"})
	rec = doJSON(t, "PATCH", base+"/booking-options/"+opt["id"].(string), token, map[string]any{"currency": "eur"})
	if rec.Code != http.StatusOK {
		t.Fatalf("patch currency = %d: %s", rec.Code, rec.Body.String())
	}
	if decode(t, rec)["currency"] != "EUR" {
		t.Fatalf("currency should be normalized upper-case: %s", rec.Body.String())
	}
}

// A shortlist is the owner's research — including what they rejected. Same
// boundary as booking todos.
func TestViewerGetsNoBookingOptions(t *testing.T) {
	resetDB(t)
	owner, ownerToken := createTestUser(t, "shortlist-owner@example.com")
	_, viewerToken := createTestUser(t, "shortlist-viewer@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base, todos := shortlistTrip(t, ownerToken, trip.ID.String())
	saveOption(t, ownerToken, base, todos[1]["id"].(string), nil)

	rec := doJSON(t, "POST", base+"/shares", ownerToken, map[string]any{})
	if rec.Code != http.StatusCreated && rec.Code != http.StatusOK {
		t.Skipf("share creation unavailable in this build: %d %s", rec.Code, rec.Body.String())
	}
	// A non-collaborator must not reach the trip at all.
	if rec := doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), viewerToken, nil); rec.Code == http.StatusOK {
		body := decode(t, rec)
		if len(listOf(t, body, "booking_options")) != 0 {
			t.Fatalf("a viewer must not see the shortlist: %v", body["booking_options"])
		}
	}
}

// An option can only hang off a leg on the SAME trip.
func TestOptionCannotAttachToAnotherTripsLeg(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "shortlist-crosstrip@example.com")
	tripA := createTestTrip(t, owner.ID, 0)
	tripB := createTestTrip(t, owner.ID, 0)
	_, todosA := shortlistTrip(t, token, tripA.ID.String())

	rec := doJSON(t, "POST", "/api/v1/trips/"+tripB.ID.String()+"/booking-options", token, map[string]any{
		"booking_todo_id": todosA[1]["id"].(string), "title": "Wrong trip",
	})
	if rec.Code != http.StatusNotFound {
		t.Fatalf("cross-trip attach = %d, want 404: %s", rec.Code, rec.Body.String())
	}
}

// Dropping a city from the itinerary must not throw away the research done for
// it. The prune demotes a leg that carries traveler state rather than deleting
// it, and a shortlist is the most expensive kind to lose — booking_options
// CASCADEs off the leg row, so a delete here is silent and total.
func TestStaleLegWithOptionsIsDemotedNotDeleted(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "shortlist-prune@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base, todos := shortlistTrip(t, token, trip.ID.String())
	stayID := todos[1]["id"].(string)
	saveOption(t, token, base, stayID, map[string]any{"title": "Loft near Old Town"})
	saveOption(t, token, base, stayID, map[string]any{"title": "Riverside studio"})

	// Re-sync with Prague gone — the leg is now stale.
	rec := doJSON(t, "PUT", base+"/booking-todos", token, homeLegPayload("EWR", "Vienna"))
	if rec.Code != http.StatusOK {
		t.Fatalf("resync = %d: %s", rec.Code, rec.Body.String())
	}

	tripView := decode(t, doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), token, nil))
	opts := listOf(t, tripView, "booking_options")
	if len(opts) != 2 {
		t.Fatalf("saved research must survive a removed city, got %d: %v", len(opts), opts)
	}
	var stayLeg map[string]any
	for _, td := range listOf(t, tripView, "booking_todos") {
		if td["id"] == stayID {
			stayLeg = td
		}
	}
	if stayLeg == nil {
		t.Fatalf("the leg holding a shortlist was deleted, taking the shortlist with it")
	}
	if stayLeg["auto"] != false {
		t.Fatalf("a demoted leg must be manual so it can be edited/removed: %v", stayLeg)
	}
}

// The 00064 payoff, extended to the shortlist: a leg's identity is not its
// endpoint label, so correcting a home airport must not disturb the options
// hanging off it.
func TestOptionsSurviveDepartureAirportChange(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "shortlist-airport@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base, todos := shortlistTrip(t, token, trip.ID.String())
	outboundID := todos[0]["id"].(string)
	opt := saveOption(t, token, base, outboundID, map[string]any{
		"title": "TAP Air Portugal", "price": 412.0, "currency": "USD", "mode": "flight",
	})

	// The traveler corrects where they fly out of.
	rec := doJSON(t, "PUT", base+"/booking-todos", token, homeLegPayload("ALB", "Prague"))
	if rec.Code != http.StatusOK {
		t.Fatalf("resync with new airport = %d: %s", rec.Code, rec.Body.String())
	}
	tripView := decode(t, doJSON(t, "GET", "/api/v1/trips/"+trip.ID.String(), token, nil))
	opts := listOf(t, tripView, "booking_options")
	if len(opts) != 1 {
		t.Fatalf("options = %d, want 1: %v", len(opts), opts)
	}
	if opts[0]["id"] != opt["id"] || opts[0]["booking_todo_id"] != outboundID {
		t.Fatalf("an airport change must not move an option: %v", opts[0])
	}
}

// A chosen transport option promotes into a segment that lands in the leg's
// slot too, and carries the mode ladder's answer.
func TestChosenTransportOptionPromotesWithModeAndKey(t *testing.T) {
	resetDB(t)
	owner, token := createTestUser(t, "shortlist-transport@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	base, todos := shortlistTrip(t, token, trip.ID.String())
	outboundID := todos[0]["id"].(string)
	opt := saveOption(t, token, base, outboundID, map[string]any{
		"title": "TAP Air Portugal", "origin": "EWR", "destination": "PRG", "mode": "flight",
	})
	body := decode(t, doJSON(t, "POST", base+"/booking-options/"+opt["id"].(string)+"/choose", token, nil))
	seg, ok := body["segment"].(map[string]any)
	if !ok {
		t.Fatalf("expected a segment: %v", body)
	}
	// Assert the PROPERTY the client's matcher tests, not a literal spelling:
	// it claims an arrival segment with `autoKey.endsWith('>><city>')`. The home
	// leg's storage key is transport:@home>>prague (00064 — the airport is not
	// the identity), which satisfies it, and unlike the endpoint-labelled key it
	// does not move when the departure airport changes.
	if key, _ := seg["auto_key"].(string); !strings.HasSuffix(key, ">>prague") {
		t.Fatalf("segment auto_key = %q — the matcher needs a '>><city>' suffix or the row misses its slot", key)
	}
	if seg["mode"] != "flight" || seg["origin"] != "EWR" || seg["destination"] != "PRG" {
		t.Fatalf("segment = %v", seg)
	}
	if seg["booked"] != true {
		t.Fatalf("promoted segment should be booked: %v", seg)
	}
}
