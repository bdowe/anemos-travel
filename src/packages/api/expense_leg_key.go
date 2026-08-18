package main

import (
	"context"
	"strings"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// expense_leg_key.go — which city leg does a budget expense belong to.
//
// Since 00072 any expense can carry a leg_key (the spend-per-city breakdown),
// so the questions "is this key one of the trip's legs?" and "which leg does
// this stay sit in?" are budget-wide concerns, not daily-spend ones. Every
// answer here goes through computeTripLegs — the ONE leg derivation
// (trip_render_legs.go) — so a canonicalized key and a server-stamped key can
// never come from two different rules.

// tripRenderLegs loads the trip's items + stays and returns computeTripLegs's
// answer. Items arrive in position order (GetItineraryItemsByTrip's ORDER BY),
// which computeTripLegs requires. A stays load failure degrades to no stays,
// matching the pre-00072 tripLegKeyExists behaviour: stays only refine leg
// SPANS, never leg identity, so the key set is unaffected.
func tripRenderLegs(ctx context.Context, q *store.Queries, trip store.Trip) ([]RenderLeg, []store.Accommodation, error) {
	items, err := q.GetItineraryItemsByTrip(ctx, trip.ID)
	if err != nil {
		return nil, nil, err
	}
	stays, _ := q.ListAccommodationsByTrip(ctx, trip.ID)
	return computeTripLegs(trip, items, stays), stays, nil
}

// tripLegKeyExists reports whether key names one of the trip's CURRENT rendered
// legs. It is the canonicalization boundary for every expense write that names
// a city (POST and, since 00072, PATCH): the client proposes a key, the server
// confirms it against computeTripLegs, and an unrecognized one is refused
// rather than stored. Without this a stale bundle could file "Rome#2" against
// a trip that no longer has one, and the line would sit in the list forever
// with no leg able to claim it.
func tripLegKeyExists(ctx context.Context, q *store.Queries, trip store.Trip, key string) (bool, error) {
	legs, _, err := tripRenderLegs(ctx, q, trip)
	if err != nil {
		return false, err
	}
	for _, l := range legs {
		if l.Key == key {
			return true, nil
		}
	}
	return false, nil
}

// legKeyForStay returns the key of the first leg whose hub this stay matches,
// or nil when none does. stayMatchesHub (plan_leg_dates.go) is the SAME
// predicate computeTripLegs uses to give a leg its dates, so a hotel's expense
// lands under the header its own check-in dates drew. Hubless legs (the
// "Other places" run) are skipped — a stay can't match a leg that names no
// city. No match returns nil: an untagged line is the honest answer, and
// guessing a city is how the leg-dates arc started.
func legKeyForStay(legs []RenderLeg, acc store.Accommodation) *string {
	for i := range legs {
		if legs[i].Hub == nil {
			continue
		}
		if stayMatchesHub(acc, strings.ToLower(*legs[i].Hub)) {
			return &legs[i].Key
		}
	}
	return nil
}

// stayLegKeyByID resolves the leg an accommodation sits in, for the server-side
// city stamp on a stay-linked expense (00072). Every failure degrades to nil:
// the money on a booked-flip expense is the point, and a grouping is not worth
// losing it over — the traveler can always tag the line by hand.
func stayLegKeyByID(ctx context.Context, q *store.Queries, trip store.Trip, accID uuid.UUID) *string {
	legs, stays, err := tripRenderLegs(ctx, q, trip)
	if err != nil {
		return nil
	}
	for i := range stays {
		if stays[i].ID == accID {
			return legKeyForStay(legs, stays[i])
		}
	}
	return nil
}
