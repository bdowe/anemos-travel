package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// --- stub: one server answering both the offer search POST and the per-offer
// services GET, counting the GETs (the tier-2 budget under test) ---

type baggageStub struct {
	mu          sync.Mutex
	gets        []string          // offer IDs fetched via GET /air/offers/{id}
	searchBody  string            // response to POST /air/offer_requests
	serviceBody map[string]string // per-offer response to the services GET
	failGETs    bool
}

func (bs *baggageStub) handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, "/air/offer_requests"):
			w.Write([]byte(bs.searchBody))
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/air/offers/"):
			id := strings.TrimPrefix(r.URL.Path, "/air/offers/")
			bs.mu.Lock()
			bs.gets = append(bs.gets, id)
			bs.mu.Unlock()
			if bs.failGETs {
				http.Error(w, `{"errors":[{"title":"boom"}]}`, http.StatusInternalServerError)
				return
			}
			body, ok := bs.serviceBody[id]
			if !ok {
				body = servicesBody("") // airline sells no bags via Duffel
			}
			w.Write([]byte(body))
		default:
			http.NotFound(w, r)
		}
	}
}

func (bs *baggageStub) getCount() int {
	bs.mu.Lock()
	defer bs.mu.Unlock()
	return len(bs.gets)
}

func newBaggageStubService(t *testing.T, bs *baggageStub) *DuffelService {
	t.Helper()
	srv := httptest.NewServer(bs.handler())
	t.Cleanup(srv.Close)
	return &DuffelService{Token: "test-token", BaseURL: srv.URL, Version: "v2",
		Client: &http.Client{Timeout: 5 * time.Second}}
}

// bagSearchOffer renders one offer for the search response. bags is the
// per-passenger baggages JSON (e.g. `{"type":"checked","quantity":1}`), empty
// for a bag-less basic fare. Departure time varies per offer so schedules stay
// distinct through dedup.
func bagSearchOffer(id, amount, departAt, bags string) string {
	return fmt.Sprintf(`{"id":%q,"total_amount":%q,"total_currency":"USD",
		"owner":{"iata_code":"XX","name":"TestAir"},
		"slices":[{"duration":"PT2H","segments":[{
			"origin":{"iata_code":"AAA"},"destination":{"iata_code":"BBB"},
			"departing_at":%q,"arriving_at":"2026-09-01T12:00:00",
			"marketing_carrier":{"name":"TestAir","iata_code":"XX"},
			"marketing_carrier_flight_number":"1",
			"passengers":[{"baggages":[%s]}]}]}]}`, id, amount, departAt, bags)
}

func searchBody(offers ...string) string {
	return `{"data":{"offers":[` + strings.Join(offers, ",") + `]}}`
}

// servicesBody renders a per-offer GET response with one passenger, one
// segment, and the given available_services JSON.
func servicesBody(services string) string {
	return fmt.Sprintf(`{"data":{
		"passengers":[{"id":"pas_1"}],
		"slices":[{"segments":[{"id":"seg_1"}]}],
		"available_services":[%s]}}`, services)
}

func checkedBagService(id, amount, currency string, maxQty int, segIDs, paxIDs []string) string {
	return bagService("checked", id, amount, currency, maxQty, segIDs, paxIDs)
}

func carryOnBagService(id, amount, currency string, maxQty int, segIDs, paxIDs []string) string {
	return bagService("carry_on", id, amount, currency, maxQty, segIDs, paxIDs)
}

func bagService(kind, id, amount, currency string, maxQty int, segIDs, paxIDs []string) string {
	seg, _ := json.Marshal(segIDs)
	pax, _ := json.Marshal(paxIDs)
	return fmt.Sprintf(`{"id":%q,"type":"baggage","total_amount":%q,"total_currency":%q,
		"maximum_quantity":%d,"segment_ids":%s,"passenger_ids":%s,"metadata":{"type":%q}}`,
		id, amount, currency, maxQty, seg, pax, kind)
}

// --- included-baggage parsing ---

func bagSlices(t *testing.T, segsJSON string) []duffelSlice {
	t.Helper()
	var out []duffelSlice
	if err := json.Unmarshal([]byte(segsJSON), &out); err != nil {
		t.Fatalf("bad slices fixture: %v", err)
	}
	return out
}

func TestIncludedBagCountsWorstCase(t *testing.T) {
	// Segment 1 grants carry-on+checked, segment 2 only carry-on: the offer as
	// a whole includes no checked bag (it would be paid on segment 2).
	slices := bagSlices(t, `[
		{"segments":[{"passengers":[{"baggages":[{"type":"carry_on","quantity":1},{"type":"checked","quantity":1}]}]}]},
		{"segments":[{"passengers":[{"baggages":[{"type":"carry_on","quantity":1}]}]}]}]`)
	carryOn, checked := includedBagCounts(slices)
	if carryOn != 1 || checked != 0 {
		t.Fatalf("counts = %d/%d, want 1 carry-on, 0 checked", carryOn, checked)
	}
}

func TestIncludedBagCountsMinAcrossPassengers(t *testing.T) {
	// One passenger has a checked bag, the other doesn't: not included.
	slices := bagSlices(t, `[{"segments":[{"passengers":[
		{"baggages":[{"type":"checked","quantity":2}]},
		{"baggages":[]}]}]}]`)
	if _, checked := includedBagCounts(slices); checked != 0 {
		t.Fatalf("checked = %d, want 0 (worst passenger)", checked)
	}
}

func TestIncludedBagCountsNoPassengerData(t *testing.T) {
	slices := bagSlices(t, `[{"segments":[{"passengers":[]}]}]`)
	carryOn, checked := includedBagCounts(slices)
	if carryOn != 0 || checked != 0 {
		t.Fatalf("counts = %d/%d, want 0/0 when Duffel omits passenger data", carryOn, checked)
	}
}

// --- computeBagFee ---

func parsedServices(t *testing.T, servicesJSON string) []duffelAvailableService {
	t.Helper()
	var out []duffelAvailableService
	if err := json.Unmarshal([]byte("["+servicesJSON+"]"), &out); err != nil {
		t.Fatalf("bad services fixture: %v", err)
	}
	return out
}

func TestComputeBagFeeMultiPassengerMultiSlice(t *testing.T) {
	// 2 passengers × 2 slices, one per-passenger-per-slice service each: four
	// units. Outbound 30, return 40 → (30+40) × 2 pax = 140.
	pairs := []segmentPassenger{
		{"seg_out", "pas_1"}, {"seg_out", "pas_2"},
		{"seg_ret", "pas_1"}, {"seg_ret", "pas_2"},
	}
	services := parsedServices(t, strings.Join([]string{
		checkedBagService("s1", "30.00", "USD", 2, []string{"seg_out"}, []string{"pas_1", "pas_2"}),
		checkedBagService("s2", "40.00", "USD", 2, []string{"seg_ret"}, []string{"pas_1", "pas_2"}),
	}, ","))
	fee, known := computeBagFee(pairs, services, baggageChecked, "USD")
	if !known || fee != 140 {
		t.Fatalf("fee=%v known=%v, want 140/true", fee, known)
	}
}

func TestComputeBagFeeCoversWholeServiceSpan(t *testing.T) {
	// One unit covers both of the service's segments for that passenger — a
	// connection must not double-charge.
	pairs := []segmentPassenger{{"seg_1", "pas_1"}, {"seg_2", "pas_1"}}
	services := parsedServices(t,
		checkedBagService("s1", "55.00", "USD", 1, []string{"seg_1", "seg_2"}, []string{"pas_1"}))
	fee, known := computeBagFee(pairs, services, baggageChecked, "USD")
	if !known || fee != 55 {
		t.Fatalf("fee=%v known=%v, want 55/true", fee, known)
	}
}

func TestComputeBagFeeUnknownWhenUncovered(t *testing.T) {
	pairs := []segmentPassenger{{"seg_1", "pas_1"}, {"seg_2", "pas_1"}}
	services := parsedServices(t,
		checkedBagService("s1", "55.00", "USD", 1, []string{"seg_1"}, []string{"pas_1"}))
	if _, known := computeBagFee(pairs, services, baggageChecked, "USD"); known {
		t.Fatal("fee must be unknown when a segment has no covering service")
	}
}

func TestComputeBagFeeUnknownOnCurrencyMismatch(t *testing.T) {
	pairs := []segmentPassenger{{"seg_1", "pas_1"}}
	services := parsedServices(t,
		checkedBagService("s1", "55.00", "EUR", 1, []string{"seg_1"}, []string{"pas_1"}))
	if _, known := computeBagFee(pairs, services, baggageChecked, "USD"); known {
		t.Fatal("fee must be unknown when the service currency differs from the fare")
	}
}

func TestComputeBagFeeRespectsMaximumQuantity(t *testing.T) {
	// Two passengers, one service capped at 1 unit: the second bag can't be
	// bought, so the fee is unknowable.
	pairs := []segmentPassenger{{"seg_1", "pas_1"}, {"seg_1", "pas_2"}}
	services := parsedServices(t,
		checkedBagService("s1", "55.00", "USD", 1, []string{"seg_1"}, []string{"pas_1", "pas_2"}))
	if _, known := computeBagFee(pairs, services, baggageChecked, "USD"); known {
		t.Fatal("fee must be unknown when maximum_quantity can't cover every passenger")
	}
}

// --- GetOfferBagFee (HTTP shape) ---

func TestGetOfferBagFee(t *testing.T) {
	bs := &baggageStub{serviceBody: map[string]string{
		"off_1": servicesBody(checkedBagService("s1", "45.00", "USD", 3, []string{"seg_1"}, []string{"pas_1"})),
	}}
	d := newBaggageStubService(t, bs)

	fee, known, err := d.GetOfferBagFee(context.Background(), "off_1", baggageChecked, "USD")
	if err != nil || !known || fee != 45 {
		t.Fatalf("fee=%v known=%v err=%v, want 45/true/nil", fee, known, err)
	}
	// No purchasable bags → unknown, not an error.
	fee, known, err = d.GetOfferBagFee(context.Background(), "off_none", baggageChecked, "USD")
	if err != nil || known || fee != 0 {
		t.Fatalf("fee=%v known=%v err=%v, want 0/false/nil for bagless airline", fee, known, err)
	}
}

// --- searchFlightsWithBaggage orchestration ---

const includedCheckedBag = `{"type":"checked","quantity":1}`

func TestSearchWithBaggagePersonalItemMakesNoExtraCalls(t *testing.T) {
	bs := &baggageStub{searchBody: searchBody(
		bagSearchOffer("off_1", "100.00", "2026-09-01T08:00:00", ""),
		bagSearchOffer("off_2", "140.00", "2026-09-01T09:00:00", includedCheckedBag),
	)}
	d := newBaggageStubService(t, bs)

	// States the tier rather than relying on the empty default, which now
	// resolves to carry_on (specs/traveler-baggage).
	offers, err := searchFlightsWithBaggage(context.Background(), d, FlightSearchRequest{
		Origin: "AAA", Destination: "BBB", DepartDate: "2026-09-01", Adults: 1, Baggage: baggagePersonalItem,
	})
	if err != nil {
		t.Fatalf("searchFlightsWithBaggage: %v", err)
	}
	if bs.getCount() != 0 {
		t.Fatalf("personal_item made %d offer GETs, want 0", bs.getCount())
	}
	for _, o := range offers {
		if o.BaggageStatus != "" || o.EffectivePrice != 0 {
			t.Fatalf("personal_item search must not emit baggage fields: %+v", o)
		}
	}
	// Included allowances are still parsed (they're free).
	for _, o := range offers {
		if o.ID == "off_2" && o.IncludedChecked != 1 {
			t.Fatalf("off_2 included checked = %d, want 1", o.IncludedChecked)
		}
	}
}

// The fallback chain has exactly one implementation, and it is also the
// validation boundary for the agent path: an unrecognized tier used to reach
// the classifier, where anything that wasn't personal_item or checked silently
// behaved as carry_on.
func TestResolveBaggageTier(t *testing.T) {
	ptr := func(s string) *string { return &s }
	cases := []struct {
		name      string
		requested string
		saved     *string
		want      string
	}{
		{"stated wins over saved", baggageChecked, ptr(baggageCarryOn), baggageChecked},
		{"stated personal item is honored", baggagePersonalItem, ptr(baggageChecked), baggagePersonalItem},
		{"case and space tolerated", " Carry_On ", nil, baggageCarryOn},
		{"omitted falls back to saved", "", ptr(baggagePersonalItem), baggagePersonalItem},
		{"omitted with no profile is a cabin bag", "", nil, baggageCarryOn},
		{"invented tier falls back to saved", "suitcase", ptr(baggagePersonalItem), baggagePersonalItem},
		{"invented tier with no profile is the default", "suitcase", nil, baggageCarryOn},
		{"junk saved value is ignored", "", ptr("steamer trunk"), baggageCarryOn},
		{"empty saved value is ignored", "", ptr(""), baggageCarryOn},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := resolveBaggageTier(tc.requested, tc.saved); got != tc.want {
				t.Errorf("resolveBaggageTier(%q, %v) = %q, want %q", tc.requested, tc.saved, got, tc.want)
			}
		})
	}
}

func TestSearchWithBaggageEffectivePriceRanking(t *testing.T) {
	// Basic fare 100 + 60 bag fee = 160 effective; fare with the bag included
	// is 140. Ranked on cost, the included fare must win — the exact inversion
	// of bare-fare ranking this feature exists for.
	bs := &baggageStub{
		searchBody: searchBody(
			bagSearchOffer("off_basic", "100.00", "2026-09-01T08:00:00", ""),
			bagSearchOffer("off_incl", "140.00", "2026-09-01T09:00:00", includedCheckedBag),
		),
		serviceBody: map[string]string{
			"off_basic": servicesBody(checkedBagService("s1", "60.00", "USD", 3, []string{"seg_1"}, []string{"pas_1"})),
		},
	}
	d := newBaggageStubService(t, bs)

	offers, err := searchFlightsWithBaggage(context.Background(), d, FlightSearchRequest{
		Origin: "AAA", Destination: "BBB", DepartDate: "2026-09-01", Adults: 1,
		Baggage: baggageChecked, OptimizeFor: "cost",
	})
	if err != nil {
		t.Fatalf("searchFlightsWithBaggage: %v", err)
	}
	if len(offers) != 2 {
		t.Fatalf("offers = %d, want 2", len(offers))
	}
	if offers[0].ID != "off_incl" {
		t.Fatalf("best offer = %s, want off_incl (cheaper effective total)", offers[0].ID)
	}
	if offers[0].BaggageStatus != baggageStatusIncluded || offers[0].EffectivePrice != 140 {
		t.Fatalf("included offer fields wrong: %+v", offers[0])
	}
	if offers[1].BaggageStatus != baggageStatusPaid || offers[1].BagFee != 60 || offers[1].EffectivePrice != 160 {
		t.Fatalf("paid offer fields wrong: %+v", offers[1])
	}
	// Only the bag-less offer earns a fee lookup.
	if bs.getCount() != 1 || bs.gets[0] != "off_basic" {
		t.Fatalf("offer GETs = %v, want exactly [off_basic]", bs.gets)
	}
}

func TestSearchWithBaggageKeepsEffectiveCheaperOnSharedSchedule(t *testing.T) {
	// Two bag-exclusive fares on ONE schedule with inverted effective totals:
	//   P: fare 100 + 80 checked-bag fee = 180 effective
	//   Q: fare 130 + 20 checked-bag fee = 150 effective
	// The old preliminary dedup collapsed both to a single "|bag:0" key and kept
	// P (cheaper BARE fare), so Q never earned a fee lookup and the search
	// reported 180 when 150 existed. Both must now survive to fee pricing and the
	// effective-cheaper Q must be the schedule's survivor.
	depart := "2026-09-01T08:00:00"
	bs := &baggageStub{
		searchBody: searchBody(
			bagSearchOffer("off_p", "100.00", depart, ""),
			bagSearchOffer("off_q", "130.00", depart, ""),
		),
		serviceBody: map[string]string{
			"off_p": servicesBody(checkedBagService("s1", "80.00", "USD", 3, []string{"seg_1"}, []string{"pas_1"})),
			"off_q": servicesBody(checkedBagService("s1", "20.00", "USD", 3, []string{"seg_1"}, []string{"pas_1"})),
		},
	}
	d := newBaggageStubService(t, bs)

	offers, err := searchFlightsWithBaggage(context.Background(), d, FlightSearchRequest{
		Origin: "AAA", Destination: "BBB", DepartDate: "2026-09-01", Adults: 1,
		Baggage: baggageChecked, OptimizeFor: "cost",
	})
	if err != nil {
		t.Fatalf("searchFlightsWithBaggage: %v", err)
	}
	// Both bag-exclusive fares must be fee-priced (neither dropped pre-lookup).
	if bs.getCount() != 2 {
		t.Fatalf("offer GETs = %v, want both off_p and off_q priced", bs.gets)
	}
	// The shared schedule collapses to exactly one survivor: the cheaper effective.
	if len(offers) != 1 {
		t.Fatalf("offers = %d, want 1 (shared schedule collapsed on effective price)", len(offers))
	}
	if offers[0].ID != "off_q" || offers[0].EffectivePrice != 150 {
		t.Fatalf("survivor = %s @ %v, want off_q @ 150 (not off_p @ 180)", offers[0].ID, offers[0].EffectivePrice)
	}
}

func TestSearchPersonalItemSharedScheduleStillCollapses(t *testing.T) {
	// Regression: on a bare-fare (personal_item) search, same-schedule offers
	// still collapse to the cheapest fare and no fee lookups happen at all.
	depart := "2026-09-01T08:00:00"
	bs := &baggageStub{searchBody: searchBody(
		bagSearchOffer("cheap", "100.00", depart, ""),
		bagSearchOffer("dear", "130.00", depart, ""),
	)}
	d := newBaggageStubService(t, bs)

	offers, err := searchFlightsWithBaggage(context.Background(), d, FlightSearchRequest{
		Origin: "AAA", Destination: "BBB", DepartDate: "2026-09-01", Adults: 1, Baggage: baggagePersonalItem,
	})
	if err != nil {
		t.Fatalf("searchFlightsWithBaggage: %v", err)
	}
	if bs.getCount() != 0 {
		t.Fatalf("bare-fare search made %d fee lookups, want 0", bs.getCount())
	}
	if len(offers) != 1 || offers[0].ID != "cheap" {
		t.Fatalf("bare-fare dedup changed: %+v", offers)
	}
}

// An omitted tier prices a CABIN BAG, not a bare fare: quoting a fare that
// excludes the bag the traveler is carrying is the whole bug this feature
// exists to fix, so the fallback must be the safe direction.
func TestSearchWithoutTierDefaultsToCarryOn(t *testing.T) {
	bs := &baggageStub{
		searchBody: searchBody(bagSearchOffer("off_1", "100.00", "2026-09-01T08:00:00", "")),
		serviceBody: map[string]string{
			"off_1": servicesBody(carryOnBagService("s1", "35.00", "USD", 1, []string{"seg_1"}, []string{"pas_1"})),
		},
	}
	d := newBaggageStubService(t, bs)

	offers, err := searchFlightsWithBaggage(context.Background(), d, FlightSearchRequest{
		Origin: "AAA", Destination: "BBB", DepartDate: "2026-09-01", Adults: 1,
	})
	if err != nil {
		t.Fatalf("searchFlightsWithBaggage: %v", err)
	}
	if bs.getCount() != 1 {
		t.Fatalf("default tier made %d fee lookups, want 1 (carry_on)", bs.getCount())
	}
	if len(offers) != 1 || offers[0].BaggageStatus != baggageStatusPaid || offers[0].EffectivePrice != 135 {
		t.Fatalf("default tier did not price the cabin bag: %+v", offers)
	}
}

func TestSearchWithBaggageUnknownDegradesAndSinks(t *testing.T) {
	bs := &baggageStub{
		searchBody: searchBody(
			bagSearchOffer("off_mystery", "100.00", "2026-09-01T08:00:00", ""),
			bagSearchOffer("off_incl", "180.00", "2026-09-01T09:00:00", includedCheckedBag),
		),
		failGETs: true,
	}
	d := newBaggageStubService(t, bs)

	offers, err := searchFlightsWithBaggage(context.Background(), d, FlightSearchRequest{
		Origin: "AAA", Destination: "BBB", DepartDate: "2026-09-01", Adults: 1,
		Baggage: baggageChecked, OptimizeFor: "cost",
	})
	if err != nil {
		t.Fatalf("a failed fee lookup must never fail the search: %v", err)
	}
	// The much cheaper bare fare sinks below the priced offer because its real
	// cost is unknowable.
	if offers[0].ID != "off_incl" || offers[1].BaggageStatus != baggageStatusUnknown {
		t.Fatalf("unknown-fee offer must sort last: %+v", offers)
	}
	if offers[1].EffectivePrice != 0 || offers[1].BagFee != 0 {
		t.Fatalf("unknown offer must carry no effective price: %+v", offers[1])
	}
}

func TestSearchWithBaggageTopKBudget(t *testing.T) {
	var many []string
	for i := 0; i < bagFeeTopK+5; i++ {
		many = append(many, bagSearchOffer(
			fmt.Sprintf("off_%02d", i), fmt.Sprintf("%d.00", 100+i),
			fmt.Sprintf("2026-09-01T%02d:15:00", i), ""))
	}
	bs := &baggageStub{searchBody: searchBody(many...)}
	d := newBaggageStubService(t, bs)

	if _, err := searchFlightsWithBaggage(context.Background(), d, FlightSearchRequest{
		Origin: "AAA", Destination: "BBB", DepartDate: "2026-09-01", Adults: 1,
		Baggage: baggageChecked,
	}); err != nil {
		t.Fatalf("searchFlightsWithBaggage: %v", err)
	}
	if bs.getCount() != bagFeeTopK {
		t.Fatalf("offer GETs = %d, want capped at %d", bs.getCount(), bagFeeTopK)
	}
}

// --- ranking/dedup with baggage ---

func TestDedupKeepsBagInclusiveVariantOfSameSchedule(t *testing.T) {
	basic := offer("basic", 100, "AAA", "BBB", "08:00", "10:00", 120, 0)
	basic.BaggageStatus = baggageStatusUnknown
	withBag := offer("withbag", 150, "AAA", "BBB", "08:00", "10:00", 120, 0)
	withBag.BaggageStatus = baggageStatusIncluded
	withBag.EffectivePrice = 150

	ranked := RankFlightOffers([]FlightOffer{basic, withBag}, "cost")
	if len(ranked) != 2 {
		t.Fatalf("dedup dropped a bag variant: %d offers, want 2", len(ranked))
	}
	// Same schedules with no baggage context still collapse (unchanged).
	plain1 := offer("p1", 100, "AAA", "BBB", "08:00", "10:00", 120, 0)
	plain2 := offer("p2", 150, "AAA", "BBB", "08:00", "10:00", 120, 0)
	if got := RankFlightOffers([]FlightOffer{plain1, plain2}, "cost"); len(got) != 1 || got[0].ID != "p1" {
		t.Fatalf("personal-item dedup changed: %+v", got)
	}
}

func TestRankUnknownSinksBelowWorseScore(t *testing.T) {
	unknown := offer("unknown", 50, "AAA", "BBB", "08:00", "10:00", 120, 0)
	unknown.BaggageStatus = baggageStatusUnknown
	paid := offer("paid", 200, "AAA", "BBB", "09:00", "11:00", 300, 2)
	paid.BaggageStatus = baggageStatusPaid
	paid.BagFee = 40
	paid.EffectivePrice = 240

	ranked := RankFlightOffers([]FlightOffer{unknown, paid}, "cost")
	if ranked[0].ID != "paid" {
		t.Fatalf("unknown-fee offer outranked a priced one: %+v", ranked)
	}
}

// --- handler validation + response shape ---

func TestFlightsSearchHandlerRejectsBadBaggage(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/api/v1/flights/search",
		strings.NewReader(`{"origin":"JFK","destination":"LHR","depart_date":"2026-09-01","baggage":"suitcase"}`))
	w := httptest.NewRecorder()
	flightsSearchHandler(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", w.Code)
	}
	if !strings.Contains(w.Body.String(), "baggage must be one of") {
		t.Fatalf("unexpected error body: %s", w.Body.String())
	}
}

func TestFlightsSearchHandlerBaggageResponse(t *testing.T) {
	bs := &baggageStub{
		searchBody: searchBody(
			bagSearchOffer("off_basic", "100.00", "2026-09-01T08:00:00", ""),
			bagSearchOffer("off_incl", "140.00", "2026-09-01T09:00:00", includedCheckedBag),
		),
		serviceBody: map[string]string{
			"off_basic": servicesBody(checkedBagService("s1", "60.00", "USD", 3, []string{"seg_1"}, []string{"pas_1"})),
		},
	}
	oldDuffel := duffelService
	duffelService = newBaggageStubService(t, bs)
	t.Cleanup(func() { duffelService = oldDuffel })

	req := httptest.NewRequest(http.MethodPost, "/api/v1/flights/search",
		strings.NewReader(`{"origin":"AAA","destination":"BBB","depart_date":"2026-09-01","baggage":"checked","optimize_for":"cost"}`))
	w := httptest.NewRecorder()
	flightsSearchHandler(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, body %s", w.Code, w.Body.String())
	}

	var resp FlightSearchResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("bad response JSON: %v", err)
	}
	if resp.Baggage != baggageChecked {
		t.Fatalf("response baggage = %q, want checked", resp.Baggage)
	}
	if resp.BestOfferID != "off_incl" {
		t.Fatalf("best offer = %s, want off_incl", resp.BestOfferID)
	}
	if resp.Offers[1].EffectivePrice != 160 || resp.Offers[1].BaggageStatus != baggageStatusPaid {
		t.Fatalf("paid offer serialization wrong: %+v", resp.Offers[1])
	}
	// Duffel priced the checked bag itself, so there is nothing to disclaim.
	if resp.BaggageNote != "" {
		t.Fatalf("baggage_note = %q, want empty when the checked bag was priced", resp.BaggageNote)
	}
}

// A client that omits the tier must be told which one it got: the response
// echoes the RESOLVED value, not the posted one, so "cheapest" is never read
// against a bag basis nobody stated.
func TestFlightsSearchHandlerEchoesResolvedBaggage(t *testing.T) {
	bs := &baggageStub{
		searchBody: searchBody(bagSearchOffer("off_1", "100.00", "2026-09-01T08:00:00", "")),
		serviceBody: map[string]string{
			"off_1": servicesBody(carryOnBagService("s1", "35.00", "USD", 1, []string{"seg_1"}, []string{"pas_1"})),
		},
	}
	oldDuffel := duffelService
	duffelService = newBaggageStubService(t, bs)
	t.Cleanup(func() { duffelService = oldDuffel })

	req := httptest.NewRequest(http.MethodPost, "/api/v1/flights/search",
		strings.NewReader(`{"origin":"AAA","destination":"BBB","depart_date":"2026-09-01"}`))
	w := httptest.NewRecorder()
	flightsSearchHandler(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, body %s", w.Code, w.Body.String())
	}
	var resp FlightSearchResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("bad response JSON: %v", err)
	}
	if resp.Baggage != baggageCarryOn {
		t.Fatalf("response baggage = %q, want carry_on", resp.Baggage)
	}
	if len(resp.Offers) != 1 || resp.Offers[0].EffectivePrice != 135 {
		t.Fatalf("omitted tier did not price the cabin bag: %+v", resp.Offers)
	}
}
