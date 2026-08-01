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
// the /flights/search handler, the plan agent's search_flights tool, and the
// price-alert checker all go through it. For the personal_item tier (Duffel
// always allows a personal item) it is exactly search + rank — zero extra
// calls, no baggage fields emitted.
func searchFlightsWithBaggage(ctx context.Context, d *DuffelService, req FlightSearchRequest) ([]FlightOffer, error) {
	offers, err := flightOffersSearch(ctx, d, req)
	if err != nil {
		return nil, err
	}
	tier := normalizeBaggage(req.Baggage)
	if tier == baggagePersonalItem {
		return RankFlightOffers(offers, req.OptimizeFor), nil
	}

	for i := range offers {
		o := &offers[i]
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
		if offers[i].BaggageStatus != baggageStatusIncluded {
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
