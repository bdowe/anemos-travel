package main

import (
	"log"
	"net/http"
	"os"

	"travel-route-planner/store"
)

// daily_spend_handler.go — GET /trips/{id}/budget/daily-spend
//
// editableTrip, not viewableTrip: this endpoint spends a model call, and the
// only thing you can DO with the answer is file a planned expense, which a
// viewer cannot. The two budget GETs stay viewable; this one is for the person
// who can act on it.
//
// It DEGRADES, never errors (the hotel-search rule). No API key, a provider
// failure, or a trip with no dated cities all answer 200 with an empty city
// list and a stable reason code, and the Budget tab simply does not grow the
// section. A suggestion that cannot be produced is not an error the traveler
// did anything to cause.

// tripLegKeyExists moved to expense_leg_key.go when 00072 made leg tagging a
// budget-wide concern rather than a daily-spend one.

func dailySpendHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	q := store.New(dbPool)

	currency := "USD"
	if b, err := q.GetBudgetByTrip(r.Context(), trip.ID); err == nil {
		currency = b.Currency
	}

	// The tier ladder needs the traveler's saved level. A profile that fails to
	// load is not fatal — resolveSpendTier lands on the default and says so via
	// tier_source, so the card never claims a preference the traveler didn't
	// set.
	var saved *string
	if user, ok := userFromContext(r.Context()); ok {
		if prefs, err := q.GetPreferences(r.Context(), user.ID); err == nil {
			saved = prefs.Budget
		}
	}
	var requested *string
	if raw := r.URL.Query().Get("tier"); raw != "" {
		requested = &raw
	}
	tier, tierSource, err := resolveSpendTier(requested, saved)
	if err != nil {
		// The one real 400 here: the CALLER asked for something we don't
		// understand. Everything else degrades.
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}

	guide := DailySpendGuide{
		Currency:   currency,
		Tier:       tier,
		TierSource: tierSource,
		Basis:      dailySpendBasisEstimate,
	}

	items, err := q.GetItineraryItemsByTrip(r.Context(), trip.ID)
	if err != nil {
		guide.Unavailable = dailySpendNoCities
		writeJSON(w, http.StatusOK, guide)
		return
	}
	stays, _ := q.ListAccommodationsByTrip(r.Context(), trip.ID)

	// computeTripLegs is THE leg derivation (trip_render_legs.go) — the same
	// one that produces the date span and nights the city headers show. Nights
	// re-derived any other way would put a different number on the Budget tab
	// than the one three inches up the page.
	legs := computeTripLegs(trip, items, stays)
	type pending struct {
		key, label string
		nights     int
	}
	var wanted []pending
	var cities []string
	seen := map[string]bool{}
	for _, l := range legs {
		// "Other places" is a sentinel for items with no locality, not a city
		// anyone eats in; every per-city section skips it.
		if l.Label == otherPlacesLabel || l.Hub == nil {
			continue
		}
		if l.Start == nil || l.End == nil {
			continue
		}
		nights := nightsBetween(*l.Start, *l.End)
		if nights <= 0 {
			// A zero-night stop is a pass-through (or a squeezed leg mid-edit).
			// There is no day of eating to plan for and no total to file.
			continue
		}
		wanted = append(wanted, pending{key: l.Key, label: l.Label, nights: nights})
		if !seen[l.Label] {
			seen[l.Label] = true
			cities = append(cities, l.Label)
		}
	}
	if len(wanted) == 0 {
		guide.Unavailable = dailySpendNoCities
		writeJSON(w, http.StatusOK, guide)
		return
	}

	apiKey := os.Getenv("ANTHROPIC_API_KEY")
	if apiKey == "" {
		guide.Unavailable = dailySpendNotConfigured
		writeJSON(w, http.StatusOK, guide)
		return
	}

	// One call for every city at once. A revisited city (Rome, Rome#2) is asked
	// about once and both legs read the same estimate.
	estimates, err := estimateDailyFoodSpend(r.Context(), newAnthropicClient(apiKey), cities, currency, tier)
	if err != nil {
		log.Printf("daily spend: %v", err)
	}
	for _, p := range wanted {
		est, ok := estimates[p.label]
		if !ok {
			// Dropped upstream (unrecognized city, implausible number, or the
			// call failed). The city is simply absent — never a borrowed or
			// averaged figure.
			continue
		}
		guide.Cities = append(guide.Cities, DailySpendCity{
			LegKey:      p.key,
			Label:       p.label,
			Nights:      p.nights,
			DailyAmount: est.DailyAmount,
			Includes:    est.Includes,
		})
	}
	if len(guide.Cities) == 0 {
		guide.Unavailable = dailySpendProviderError
	}
	writeJSON(w, http.StatusOK, guide)
}
