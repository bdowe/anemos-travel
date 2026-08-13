package main

import (
	"strings"
	"testing"
)

// summarizeOffers is the ONLY place the model learns what a flight price
// means: the chat UI renders no prices (count-only chip), so the header must
// label trip type, dates, and party size explicitly. Both providers return
// totals for the WHOLE party, and round-trip searches return round-trip
// totals — an unlabeled number reads as a per-person one-way fare (the
// EWR→PRG 2x misquote these tests pin against).

func summarizeOfferFixture() FlightOffer {
	return FlightOffer{
		Airlines: []string{"Lufthansa"}, Currency: "USD", Price: 1027,
		Stops: 1, DurationMin: 610, Score: 8.4,
	}
}

func TestSummarizeOffersOneWaySingleTraveler(t *testing.T) {
	text := summarizeOffers(FlightSearchRequest{
		Origin: "EWR", Destination: "PRG", DepartDate: "2026-08-24", Adults: 1,
	}, []FlightOffer{summarizeOfferFixture()})

	for _, want := range []string{
		"EWR→PRG one-way 2026-08-24",
		"prices are one-way totals for 1 traveler",
		"1. Lufthansa — USD 1027, 1 stop, 10h10m (score 8.4)",
		"never a per-person fare",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("one-way summary missing %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "⇄") || strings.Contains(text, "round") {
		t.Errorf("one-way summary must not mention round trips:\n%s", text)
	}
	if strings.Contains(text, "saved with their trip") {
		t.Errorf("nothing persists these offers; the closing line must not claim so:\n%s", text)
	}
}

func TestSummarizeOffersRoundTripParty(t *testing.T) {
	text := summarizeOffers(FlightSearchRequest{
		Origin: "EWR", Destination: "PRG",
		DepartDate: "2026-08-24", ReturnDate: "2026-09-02",
		Adults: 2, ChildAges: []int{7},
	}, []FlightOffer{summarizeOfferFixture()})

	for _, want := range []string{
		"EWR⇄PRG round trip 2026-08-24 → 2026-09-02",
		"3 travelers",
		"round-trip totals for all 3 travelers",
		"outbound leg",
		"round-trip total for all 3 travelers, never a per-person fare",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("round-trip summary missing %q:\n%s", want, text)
		}
	}
}

// Zero/absent adults must still read as one traveler, never "0 travelers".
// runSearchFlightsTool clamps today, but summarizeOffers must not rely on
// its only caller staying polite.
func TestSummarizeOffersClampsPartySize(t *testing.T) {
	text := summarizeOffers(FlightSearchRequest{
		Origin: "EWR", Destination: "PRG", DepartDate: "2026-08-24",
	}, []FlightOffer{summarizeOfferFixture()})
	if !strings.Contains(text, "1 traveler") || strings.Contains(text, "0 traveler") {
		t.Errorf("party size not clamped to 1:\n%s", text)
	}
}

// The baggage suffixes are load-bearing (flight_baggage.go's effective-total
// contract) and must survive the header rewrite byte-for-byte.
func TestSummarizeOffersBaggageSuffixes(t *testing.T) {
	unknown := summarizeOfferFixture()
	unknown.BaggageStatus = baggageStatusUnknown
	paid := summarizeOfferFixture()
	paid.BaggageStatus = baggageStatusPaid
	paid.BagFee = 60
	paid.EffectivePrice = 1087

	text := summarizeOffers(FlightSearchRequest{
		Origin: "EWR", Destination: "PRG", DepartDate: "2026-08-24", Adults: 1,
	}, []FlightOffer{unknown, paid})

	for _, want := range []string{
		"(bag NOT included; fee unknown — warn the traveler)",
		"USD 1087 (incl. USD 60 bag fee)",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("baggage suffix missing %q:\n%s", want, text)
		}
	}
}

func TestSummarizeOffersNoFlights(t *testing.T) {
	oneWay := summarizeOffers(FlightSearchRequest{
		Origin: "EWR", Destination: "PRG", DepartDate: "2026-08-24", Adults: 1,
	}, nil)
	if oneWay != "No flights found from EWR to PRG departing 2026-08-24 (one-way)." {
		t.Errorf("one-way no-flights = %q", oneWay)
	}
	roundTrip := summarizeOffers(FlightSearchRequest{
		Origin: "EWR", Destination: "PRG",
		DepartDate: "2026-08-24", ReturnDate: "2026-09-02", Adults: 1,
	}, nil)
	if roundTrip != "No flights found from EWR to PRG for 2026-08-24 → 2026-09-02 (round trip)." {
		t.Errorf("round-trip no-flights = %q", roundTrip)
	}
}
