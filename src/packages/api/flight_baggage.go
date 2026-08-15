package main

import (
	"context"
	"log"
	"sync"
	"time"
)

// Baggage-aware flight search (specs: baggage-aware effective pricing).
//
// Duffel's cheapest offers are basic fares that exclude bags, so ranking on
// the bare fare hides the price the traveler actually pays. When a search
// names a carry_on or checked tier, every offer is classified against its
// included allowance, and for the top-ranked offers that lack the bag we
// fetch Duffel's purchasable bag price (one extra API call per offer — the
// reason for the top-K budget) and rank on the effective total instead.

const (
	// bagFeeTopK bounds tier-2 GET /air/offers/{id} calls per search: only
	// the K best-ranked offers lacking the bag get a fee lookup; the rest
	// stay "unknown" and sink in the ranking.
	bagFeeTopK        = 10
	bagFeeConcurrency = 4
)

// bagFeeTimeout caps the whole tier-2 fan-out; a var so tests can shorten it.
var bagFeeTimeout = 15 * time.Second

// searchFlightsWithBaggage is the one entry point for baggage-aware search:
// the /flights/search handler and the plan agent's search_flights tool both
// go through it. For the personal_item tier (Duffel
// always allows a personal item) it is exactly search + rank — zero extra
// calls, no baggage fields emitted.
func searchFlightsWithBaggage(ctx context.Context, d *DuffelService, req FlightSearchRequest) ([]FlightOffer, error) {
	// Resolve before the provider call, not after: a provider that can price
	// bags into its own quote (SerpApi's bags parameter) needs the tier on the
	// request it sends, and every later step must read the same value.
	tier := normalizeBaggage(req.Baggage)
	req.Baggage = tier
	offers, err := flightOffersSearch(ctx, d, req)
	if err != nil {
		return nil, err
	}
	if tier == baggagePersonalItem {
		return RankFlightOffers(offers, req.OptimizeFor), nil
	}

	for i := range offers {
		o := &offers[i]
		// A provider that already priced the bag into its quote is the
		// authority on that offer — re-classifying it against an allowance it
		// never reported would demote a covered price to "unknown".
		if o.BaggageStatus != "" {
			continue
		}
		included := o.IncludedCarryOn
		if tier == baggageChecked {
			included = o.IncludedChecked
		}
		if included >= 1 {
			o.BaggageStatus = baggageStatusIncluded
			o.EffectivePrice = o.Price
		} else {
			o.BaggageStatus = baggageStatusUnknown
		}
	}

	// Preliminary rank to decide which offers earn a fee lookup: the K best
	// candidates that still lack the bag. Unknown-fee offers score on the
	// bare fare here, which is exactly the "looks cheapest" list the traveler
	// would otherwise be misled by. collapseUnknown=false keeps every
	// bag-exclusive fare of a schedule distinct so the effective-cheaper one
	// isn't dropped by bare-fare dedup before it can be fee-priced; the final
	// RankFlightOffers below collapses the priced results on effective price.
	offers = rankFlightOffers(offers, req.OptimizeFor, false)
	lookup := make([]int, 0, bagFeeTopK)
	for i := range offers {
		if len(lookup) >= bagFeeTopK {
			break
		}
		// Only offers whose bag is still unpriced earn a lookup — every other
		// status already means "this total covers the bag".
		if offers[i].BaggageStatus == baggageStatusUnknown {
			lookup = append(lookup, i)
		}
	}

	// Bag fees are a Duffel capability: temporary-provider offers carry
	// synthetic IDs that Duffel's /air/offers/{id} would 404 on, so they stay
	// "unknown" (summarizeOffers already warns the model about unknowns).
	if len(lookup) > 0 && !serpapiFlights.Active() {
		fetchBagFees(ctx, d, offers, lookup, tier)
	}
	return RankFlightOffers(offers, req.OptimizeFor), nil
}

// fetchBagFees prices the requested bag for the given offer indexes with
// bounded concurrency. Failures degrade the offer to "unknown" — a bag-fee
// problem must never fail the search.
func fetchBagFees(ctx context.Context, d *DuffelService, offers []FlightOffer, indexes []int, tier string) {
	ctx, cancel := context.WithTimeout(ctx, bagFeeTimeout)
	defer cancel()

	var wg sync.WaitGroup
	sem := make(chan struct{}, bagFeeConcurrency)
	for _, i := range indexes {
		wg.Add(1)
		o := &offers[i]
		safeGo("flight bag fee lookup", func() {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
				defer func() { <-sem }()
			case <-ctx.Done():
				return
			}
			fee, known, err := d.GetOfferBagFee(ctx, o.ID, tier, o.Currency)
			if err != nil {
				log.Printf("flight baggage: fee lookup for offer %s failed: %v", o.ID, err)
				return
			}
			if !known {
				return
			}
			// Offers are only read/written by their own goroutine (disjoint
			// indexes), so no lock is needed.
			o.BaggageStatus = baggageStatusPaid
			o.BagFee = fee
			o.EffectivePrice = o.Price + fee
		})
	}
	wg.Wait()
}

// baggageNoteCheckedNotPriced says the quoted prices cover the cabin bag but
// not the checked bag the traveler asked for. It is a stable CODE, not prose:
// the flight-search response carries it and the client localizes it (same
// idiom as the uptime reason codes), while the model gets the same fact as
// English from baggageBasisClause.
const baggageNoteCheckedNotPriced = "checked_not_priced"

// baggageNoteCode names what a search could NOT price, or "" when the quoted
// prices cover the bags that were asked for. There is exactly one case today:
// Google Flights folds a CARRY-ON fee into its quote on any route but includes
// checked-bag fees on US domestic ones only, and SerpApi exposes no way to ask
// for checked bags — so a checked search comes back cabin-priced. Naming that
// gap is the whole point; inventing a checked-bag estimate is not an option
// (docs/zen.md — refuse the temptation to guess).
func baggageNoteCode(tier string, offers []FlightOffer) string {
	if tier != baggageChecked {
		return ""
	}
	sawInPrice := false
	for _, o := range offers {
		switch o.BaggageStatus {
		case baggageStatusIncluded, baggageStatusPaid:
			// A provider that priced the checked bag itself (Duffel) leaves
			// nothing to warn about.
			return ""
		case baggageStatusInPrice:
			sawInPrice = true
		}
	}
	if sawInPrice {
		return baggageNoteCheckedNotPriced
	}
	return ""
}

// baggageBasisClause states, in one clause, what the listed prices cover with
// respect to bags — the fact the model repeats to the traveler, who sees only
// a result count in the chat. Derived from what came BACK, not from what was
// asked for: a bag the provider could not price must never be described as
// priced.
func baggageBasisClause(tier string, offers []FlightOffer, note string) string {
	if tier == baggagePersonalItem {
		return "these are bare fares covering a personal item only — on many carriers a cabin bag costs extra, so say so whenever you quote one"
	}
	bag := "a cabin bag"
	if tier == baggageChecked {
		bag = "a checked bag"
	}
	covered := false
	for _, o := range offers {
		switch o.BaggageStatus {
		case baggageStatusIncluded, baggageStatusPaid, baggageStatusInPrice:
			covered = true
		}
	}
	switch {
	case !covered:
		return "these prices do NOT cover " + bag + " and the fee could not be priced — tell the traveler to check it with the airline"
	case note == baggageNoteCheckedNotPriced:
		return "prices include the cabin-bag fee but NOT the checked-bag fee, which could not be priced — tell the traveler to check the checked-bag fee with the airline"
	default:
		return "prices cover " + bag + ", including its fee where the airline charges one"
	}
}
