package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math"
	"strings"
	"time"

	anthropic "github.com/anthropics/anthropic-sdk-go"
)

// daily_spend_service.go — "roughly what does a day of eating cost here?", per
// city on a trip (specs/daily-spend-guide).
//
// WHY THE NUMBER IS A MODEL ESTIMATE, written down so nobody re-opens it:
// there is no free, global, currency-denominated meal-price feed. Numbeo's is
// paid, the free alternatives are US-only indices, and this API talks to the
// LEGACY Google Places API whose price_level is an ordinal 0-4 — a $-sign, not
// a rate. hotel_search_service.go already refused to map that onto money for
// the same reason. So the estimate comes from aiModelLight(), and the ONE
// thing that makes that honest is that it never pretends otherwise: Basis
// rides on the result, the card says "an estimate, not a quote", and nothing
// downstream may present it as a looked-up price.
//
// The unit is fixed and total: ONE person, ONE day, in the trip's budget
// currency — the flight-price-semantics lesson (a number in a result arrives
// with what it means attached). Party size is applied by the client, which is
// the only place that knows it; this file never multiplies.

const (
	// A city's food costs move on a scale of seasons, not hours — far slower
	// than a hotel rate set (6 h) or a fare (15 min). The cache is also the
	// only real spend guard on this endpoint, so it is generous on purpose.
	dailySpendCacheTTL = 30 * 24 * time.Hour
	dailySpendCacheMax = 2000

	dailySpendTimeout   = 45 * time.Second
	dailySpendMaxCities = 12
	// A day of eating that costs more than this in any real currency is the
	// model having lost the plot (or answering in minor units). Dropped, not
	// clamped: a wrong number presented confidently is the failure mode this
	// whole file is arranged against.
	dailySpendMaxDaily   = 5000
	dailySpendMaxInclude = 160

	dailySpendToolName = "record_daily_food_estimates"
)

// Tier vocabulary. These are the SAME three values as
// traveler_preferences.budget (allowedBudgets) on purpose — the profile is one
// of the two things that can answer "which tier", so a second spelling would
// need a mapping table that could drift.
const (
	spendTierBudget = "budget"
	spendTierMid    = "mid"
	spendTierLuxury = "luxury"

	// defaultSpendTier is what answers when nothing else does. "mid" rather
	// than "budget" because this number becomes a PLANNED expense: a plan set
	// too low reads as a surprise overrun later, which is the thing the
	// planned-vs-paid comparison exists to make visible, not to manufacture.
	defaultSpendTier = spendTierMid
)

// Where the resolved tier came from. Stated on the wire rather than left for
// the client to guess, so the card can say "from your saved budget level"
// truthfully — and so a profile that silently failed to load is visible as
// "default" instead of looking like a deliberate choice.
const (
	tierSourceRequest = "request"
	tierSourceProfile = "profile"
	tierSourceDefault = "default"
)

// Reason codes for an answer we could not produce. A closed vocabulary, never
// prose: the client localizes it, and the section simply does not render.
const (
	dailySpendNotConfigured = "not_configured"
	dailySpendProviderError = "provider_error"
	dailySpendNoCities      = "no_cities"
)

// DailySpendGuide is the whole answer for one trip.
type DailySpendGuide struct {
	Currency string `json:"currency"`
	// Tier is the RESOLVED tier — what actually produced these numbers, never
	// what was asked for (resolveBaggageTier's rule, same reason).
	Tier       string `json:"tier"`
	TierSource string `json:"tier_source"`
	// Basis names where the money came from. One value today; it exists so
	// that swapping in a real cost-of-living provider is a new value here
	// rather than a silent change of meaning under the client's feet.
	Basis  string           `json:"basis"`
	Cities []DailySpendCity `json:"cities"`
	// Unavailable is set exactly when Cities is empty for a reason worth
	// naming. Absent otherwise.
	Unavailable string `json:"unavailable_reason,omitempty"`
}

// DailySpendCity is one city leg, ready to render.
type DailySpendCity struct {
	// LegKey is RenderLeg.Key — the identity the accepted plan is stored
	// under (00070), so the card can find its own line without matching on a
	// label it generated itself.
	LegKey string `json:"leg_key"`
	Label  string `json:"label"`
	// Nights, not days. Legs SHARE their transition day (Rome ends the morning
	// Florence begins), so counting days bills that day twice and the section
	// could never reconcile with the trip's own length. Nights per leg sum
	// exactly to the trip's nights.
	Nights int `json:"nights"`
	// DailyAmount is per person, per day, in Currency.
	DailyAmount float64 `json:"daily_amount"`
	Includes    string  `json:"includes"`
}

const dailySpendBasisEstimate = "estimate"

// dailyFoodEstimate is the cached unit: one city at one tier in one currency.
type dailyFoodEstimate struct {
	DailyAmount float64
	Includes    string
}

var dailySpendCache = newTTLCache[dailyFoodEstimate](dailySpendCacheTTL, dailySpendCacheMax)

func dailySpendCacheKey(city, currency, tier string) string {
	return strings.ToLower(strings.TrimSpace(city)) + "|" + currency + "|" + tier
}

// resolveSpendTier is the ONE fallback chain for "which spend level", modelled
// on resolveBaggageTier (duffel_service.go) and explicit for the same reason:
// a tier that is merely implied is a number nobody can check. An unrecognized
// REQUESTED tier is refused rather than quietly becoming the default — the
// caller stated something we do not understand, and silently answering a
// different question is how a wrong tier survives forever.
func resolveSpendTier(requested *string, saved *string) (tier string, source string, err error) {
	if requested != nil {
		r := strings.ToLower(strings.TrimSpace(*requested))
		if r != "" {
			if !allowedBudgets[r] {
				return "", "", fmt.Errorf("tier must be one of: %s, %s, %s",
					spendTierBudget, spendTierMid, spendTierLuxury)
			}
			return r, tierSourceRequest, nil
		}
	}
	if saved != nil {
		s := strings.ToLower(strings.TrimSpace(*saved))
		// The profile is data we already stored, not a caller's claim: a value
		// that somehow fell outside the set falls through to the default
		// rather than failing a read the traveler did not make.
		if allowedBudgets[s] {
			return s, tierSourceProfile, nil
		}
	}
	return defaultSpendTier, tierSourceDefault, nil
}

const dailySpendSystemPrompt = "You estimate typical daily food and drink spending for travelers, city by city. " +
	"Call " + dailySpendToolName + " exactly once, with one entry per city you were given, using the city names EXACTLY as given. " +
	"Each daily_amount is what ONE traveler typically spends on food and drink in ONE full day in that city — " +
	"all meals plus coffee and a drink — at the stated spending level, expressed in the stated currency. " +
	"Do not include lodging, transport, tickets, or shopping. " +
	"Spending levels: 'budget' is markets, bakeries, street food and cheap set menus; " +
	"'mid' is a casual lunch and an ordinary sit-down dinner with a drink; " +
	"'luxury' is good restaurants without checking prices. " +
	"Write `includes` as ONE short phrase (under 120 characters) naming the meals that amount covers, in the same style for every city. " +
	"Estimate real local prices — a cheap city must come out cheaper than an expensive one. " +
	"If you genuinely do not recognize a city, OMIT it entirely rather than guessing a number."

// estimateDailyFoodSpend answers for every city in one shot, taking cache hits
// off the top and making at most ONE model call for whatever is left. Cities
// the model omits or answers implausibly are DROPPED — never back-filled with
// a neighbouring city's number or a global average, because a plausible wrong
// figure is exactly what a traveler cannot audit.
//
// The currency is ours and is only ever sent TO the model; nothing here reads
// a currency back out of the response. There is no FX anywhere in this app and
// this is not the place to invent some.
func estimateDailyFoodSpend(ctx context.Context, client anthropic.Client, cities []string, currency, tier string) (map[string]dailyFoodEstimate, error) {
	out := make(map[string]dailyFoodEstimate, len(cities))
	var missing []string
	for _, c := range cities {
		if hit, ok := dailySpendCache.get(dailySpendCacheKey(c, currency, tier)); ok {
			out[c] = hit
			continue
		}
		missing = append(missing, c)
	}
	if len(missing) == 0 {
		return out, nil
	}
	if len(missing) > dailySpendMaxCities {
		missing = missing[:dailySpendMaxCities]
	}

	ctx, cancel := context.WithTimeout(ctx, dailySpendTimeout)
	defer cancel()

	tool := anthropic.ToolParam{
		Name:        dailySpendToolName,
		Description: anthropic.String("Record the typical per-person daily food and drink spend for each city."),
		InputSchema: anthropic.ToolInputSchemaParam{
			Properties: map[string]any{
				"estimates": map[string]any{
					"type": "array",
					"items": map[string]any{
						"type": "object",
						"properties": map[string]any{
							"city":         map[string]any{"type": "string", "description": "The city name exactly as given"},
							"daily_amount": map[string]any{"type": "number", "description": "Per person, per day, in " + currency},
							"includes":     map[string]any{"type": "string", "description": "One short phrase naming the meals covered"},
						},
						"required": []string{"city", "daily_amount", "includes"},
					},
				},
			},
			Required: []string{"estimates"},
		},
	}

	ask := fmt.Sprintf("Spending level: %s.\nCurrency: %s.\nCities:\n- %s",
		tier, currency, strings.Join(missing, "\n- "))

	resp, err := client.Messages.New(ctx, anthropic.MessageNewParams{
		Model:      aiModelLight(),
		MaxTokens:  1024,
		System:     []anthropic.TextBlockParam{{Text: dailySpendSystemPrompt}},
		Tools:      []anthropic.ToolUnionParam{{OfTool: &tool}},
		ToolChoice: anthropic.ToolChoiceParamOfTool(dailySpendToolName),
		Thinking:   forcedToolThinking(),
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock(ask)),
		},
	})
	// ai_health.go: every Anthropic SDK call site records exactly once, so a
	// billing/auth outage here shows up in the shared ops verdict instead of
	// looking like a quiet feature that stopped rendering.
	recordAIResult(err)
	if err != nil {
		return out, fmt.Errorf("daily spend: model call: %w", err)
	}

	var in struct {
		Estimates []struct {
			City        string  `json:"city"`
			DailyAmount float64 `json:"daily_amount"`
			Includes    string  `json:"includes"`
		} `json:"estimates"`
	}
	found := false
	for _, block := range resp.Content {
		if variant, ok := block.AsAny().(anthropic.ToolUseBlock); ok && variant.Name == dailySpendToolName {
			if err := json.Unmarshal(variant.Input, &in); err != nil {
				return out, fmt.Errorf("daily spend: parse tool input: %w", err)
			}
			found = true
			break
		}
	}
	if !found {
		return out, fmt.Errorf("daily spend: model returned no %s call", dailySpendToolName)
	}

	// Match back onto the cities WE asked for. The model is told to echo the
	// names verbatim, but a case or whitespace difference must not lose a city
	// — and a name we never asked about is discarded outright rather than
	// rendered under a heading nobody's trip has.
	wanted := make(map[string]string, len(missing))
	for _, c := range missing {
		wanted[strings.ToLower(strings.TrimSpace(c))] = c
	}
	for _, e := range in.Estimates {
		city, ok := wanted[strings.ToLower(strings.TrimSpace(e.City))]
		if !ok {
			log.Printf("daily spend: model returned unrequested city %q (dropped)", e.City)
			continue
		}
		if !(e.DailyAmount > 0) || math.IsNaN(e.DailyAmount) || e.DailyAmount > dailySpendMaxDaily {
			log.Printf("daily spend: implausible amount %v for %q (dropped)", e.DailyAmount, city)
			continue
		}
		est := dailyFoodEstimate{
			DailyAmount: math.Round(e.DailyAmount),
			Includes:    truncateRunes(strings.TrimSpace(e.Includes), dailySpendMaxInclude),
		}
		out[city] = est
		dailySpendCache.set(dailySpendCacheKey(city, currency, tier), est)
	}
	return out, nil
}
