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

// Clock times: the model schedules the traveler's first and last day around
// them, and a summary without them cannot tell a dawn departure from a
// red-eye. Both providers have always filled DepartTime/ArriveTime; only this
// summary withheld them.
func TestSummarizeOffersRendersClockTimes(t *testing.T) {
	o := summarizeOfferFixture()
	o.DepartTime = "2026-08-24T06:40:00"
	o.ArriveTime = "2026-08-24T11:15:00"

	text := summarizeOffers(FlightSearchRequest{
		Origin: "EWR", Destination: "PRG", DepartDate: "2026-08-24", Adults: 1,
	}, []FlightOffer{o})

	if !strings.Contains(text, "10h10m, 06:40→11:15 (score 8.4)") {
		t.Errorf("one-way line missing its clock window:\n%s", text)
	}
	if !strings.Contains(text, "local to each airport") {
		t.Errorf("closing line must say the times are airport-local:\n%s", text)
	}
}

// An overnight leg must say so — "22:50→06:10" alone reads as a 7h flight
// landing the same morning, and that is the offer most likely to eat a day.
func TestSummarizeOffersMarksNextDayArrival(t *testing.T) {
	o := summarizeOfferFixture()
	o.DepartTime = "2026-08-24T22:50:00"
	o.ArriveTime = "2026-08-25T06:10:00"

	text := summarizeOffers(FlightSearchRequest{
		Origin: "EWR", Destination: "PRG", DepartDate: "2026-08-24", Adults: 1,
	}, []FlightOffer{o})

	if !strings.Contains(text, "22:50→06:10+1") {
		t.Errorf("next-day arrival not marked:\n%s", text)
	}
	// Marking it is only half the job: the +1 had existed here for months with
	// nowhere to go. The closing line must tell the model what to DO with it,
	// or the fact dies with the turn and the trip page keeps showing the
	// landing day as if it were the departure.
	if !strings.Contains(text, "add_transport_segment's depart_date and arrive_date") {
		t.Errorf("closing line does not tell the model to record the +1:\n%s", text)
	}
}

// On a round trip the top-level times describe the OUTBOUND slice, so the
// return slice needs its own label: its departure is the one that decides how
// much of the traveler's last day is theirs.
func TestSummarizeOffersLabelsReturnDeparture(t *testing.T) {
	o := summarizeOfferFixture()
	o.DepartTime = "2026-08-24T06:40:00"
	o.ArriveTime = "2026-08-24T11:15:00"
	o.ReturnSegments = []FlightLeg{
		{From: "PRG", To: "FRA", DepartTime: "2026-09-02T20:05:00", ArriveTime: "2026-09-02T21:10:00"},
		{From: "FRA", To: "EWR", DepartTime: "2026-09-02T22:00:00", ArriveTime: "2026-09-03T01:30:00"},
	}

	text := summarizeOffers(FlightSearchRequest{
		Origin: "EWR", Destination: "PRG",
		DepartDate: "2026-08-24", ReturnDate: "2026-09-02", Adults: 1,
	}, []FlightOffer{o})

	// The return window spans the FIRST leg's departure to the LAST leg's
	// arrival, so a connection can't hide the real door-to-door shape.
	if !strings.Contains(text, "out 06:40→11:15, back 20:05→01:30+1") {
		t.Errorf("return departure not labeled:\n%s", text)
	}
}

// A provider that sends no times (or an unparseable one) must leave the line
// exactly as it was — the fixture the other tests in this file pin.
func TestSummarizeOffersOmitsUnparseableTimes(t *testing.T) {
	blank := summarizeOfferFixture()
	junk := summarizeOfferFixture()
	junk.DepartTime = "sometime tuesday"
	junk.ArriveTime = "later"

	text := summarizeOffers(FlightSearchRequest{
		Origin: "EWR", Destination: "PRG", DepartDate: "2026-08-24", Adults: 1,
	}, []FlightOffer{blank, junk})

	if !strings.Contains(text, "1. Lufthansa — USD 1027, 1 stop, 10h10m (score 8.4)") ||
		!strings.Contains(text, "2. Lufthansa — USD 1027, 1 stop, 10h10m (score 8.4)") {
		t.Errorf("timeless offers must keep the pre-times line:\n%s", text)
	}
	if strings.Contains(text, "→") && !strings.Contains(text, "EWR→PRG") {
		t.Errorf("no clock window should appear:\n%s", text)
	}
}

// Half a window is still worth having: an arrival we can't read must not cost
// the traveler the departure time, which is the field the last-day rule needs.
func TestSummarizeOffersDepartureAloneSurvivesMissingArrival(t *testing.T) {
	o := summarizeOfferFixture()
	o.DepartTime = "2026-08-24T06:40:00"

	text := summarizeOffers(FlightSearchRequest{
		Origin: "EWR", Destination: "PRG", DepartDate: "2026-08-24", Adults: 1,
	}, []FlightOffer{o})

	if !strings.Contains(text, "10h10m, 06:40 (score 8.4)") {
		t.Errorf("bare departure not rendered:\n%s", text)
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
