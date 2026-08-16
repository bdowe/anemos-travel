package main

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// daily_spend_service_test.go — the two things that make a model-authored
// number safe to show a traveler: the tier is resolved explicitly, and an
// answer we cannot vouch for is DROPPED rather than rendered.

// freshDailySpendCache swaps in an empty cache for the duration of a test.
// The real one lives 30 days, so without this a city primed by one test would
// silently answer another's model call and the assertion would pass vacuously.
func freshDailySpendCache(t *testing.T) {
	t.Helper()
	prev := dailySpendCache
	dailySpendCache = newTTLCache[dailyFoodEstimate](time.Hour, 100)
	t.Cleanup(func() { dailySpendCache = prev })
}

func TestResolveSpendTier(t *testing.T) {
	cases := []struct {
		name       string
		requested  *string
		saved      *string
		wantTier   string
		wantSource string
		wantErr    bool
	}{
		{"stated wins over profile", strPtr("luxury"), strPtr("budget"), "luxury", tierSourceRequest, false},
		{"profile answers when nothing stated", nil, strPtr("budget"), "budget", tierSourceProfile, false},
		{"default when neither", nil, nil, defaultSpendTier, tierSourceDefault, false},
		{"case and space tolerated", strPtr("  Mid "), nil, "mid", tierSourceRequest, false},
		// An empty ?tier= is "not stated", not "stated as nothing" — the query
		// string cannot distinguish them, so it must fall through.
		{"empty request falls through", strPtr(""), strPtr("luxury"), "luxury", tierSourceProfile, false},
		// A caller naming a tier we don't understand is refused. Answering a
		// different question than the one asked is how a wrong tier survives.
		{"unknown request refused", strPtr("baller"), strPtr("mid"), "", "", true},
		// A stored value outside the set is data, not a claim — no read the
		// traveler didn't make should fail on it.
		{"unknown profile falls through", nil, strPtr("frugal"), defaultSpendTier, tierSourceDefault, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			tier, source, err := resolveSpendTier(c.requested, c.saved)
			if (err != nil) != c.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, c.wantErr)
			}
			if c.wantErr {
				return
			}
			if tier != c.wantTier || source != c.wantSource {
				t.Fatalf("got (%q, %q), want (%q, %q)", tier, source, c.wantTier, c.wantSource)
			}
		})
	}
}

func TestEstimateDailyFoodSpendAsksOnceThenCaches(t *testing.T) {
	freshDailySpendCache(t)
	fake := newFakeAnthropic(t)
	fake.scriptNonStreamingTool(dailySpendToolName, `{"estimates":[
		{"city":"Tbilisi","daily_amount":32,"includes":"Bakery breakfast, khinkali lunch, dinner with wine."},
		{"city":"Batumi","daily_amount":28,"includes":"Bakery breakfast, casual lunch, dinner with wine."}
	]}`)
	client := newAnthropicClient("test-key")

	got, err := estimateDailyFoodSpend(context.Background(), client,
		[]string{"Tbilisi", "Batumi"}, "USD", "mid")
	if err != nil {
		t.Fatalf("estimate: %v", err)
	}
	if len(got) != 2 || got["Tbilisi"].DailyAmount != 32 || got["Batumi"].DailyAmount != 28 {
		t.Fatalf("both cities should come back: %+v", got)
	}
	if n := len(fake.requestBodies()); n != 1 {
		t.Fatalf("two cities must ride ONE call, got %d", n)
	}

	// Same question again: entirely served from cache. This is the only spend
	// guard on the endpoint, so it is worth pinning.
	again, err := estimateDailyFoodSpend(context.Background(), client,
		[]string{"Tbilisi", "Batumi"}, "USD", "mid")
	if err != nil {
		t.Fatalf("cached estimate: %v", err)
	}
	if len(again) != 2 {
		t.Fatalf("cached answer incomplete: %+v", again)
	}
	if n := len(fake.requestBodies()); n != 1 {
		t.Fatalf("cache hit reached upstream: %d calls", n)
	}

	// A different tier is a DIFFERENT question — prices vary by it, so it must
	// not read the mid-tier answer back.
	if _, err := estimateDailyFoodSpend(context.Background(), client,
		[]string{"Tbilisi"}, "USD", "luxury"); err != nil {
		t.Fatalf("luxury estimate: %v", err)
	}
	if n := len(fake.requestBodies()); n != 2 {
		t.Fatalf("tier must be part of the cache key: %d calls", n)
	}
}

func TestEstimateDailyFoodSpendDropsWhatItCannotVouchFor(t *testing.T) {
	freshDailySpendCache(t)
	fake := newFakeAnthropic(t)
	fake.scriptNonStreamingTool(dailySpendToolName, `{"estimates":[
		{"city":"Porto","daily_amount":45,"includes":"Pastel de nata, a francesinha, dinner with wine."},
		{"city":"Braga","daily_amount":0,"includes":"Free lunch, apparently."},
		{"city":"Faro","daily_amount":99999,"includes":"Minor units, probably."},
		{"city":"Atlantis","daily_amount":40,"includes":"A city nobody asked about."}
	]}`)

	got, err := estimateDailyFoodSpend(context.Background(), newAnthropicClient("test-key"),
		[]string{"Porto", "Braga", "Faro"}, "EUR", "mid")
	if err != nil {
		t.Fatalf("estimate: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("only Porto is answerable, got %+v", got)
	}
	if got["Porto"].DailyAmount != 45 {
		t.Fatalf("Porto = %+v", got["Porto"])
	}
	// The point of dropping rather than clamping: a city with no defensible
	// number must be ABSENT, never carrying a neighbour's figure or an average.
	for _, city := range []string{"Braga", "Faro", "Atlantis"} {
		if _, ok := got[city]; ok {
			t.Errorf("%s should have been dropped: %+v", city, got[city])
		}
	}
	// And a dropped city must not be cached, so a later call can still get a
	// real answer for it.
	if _, ok := dailySpendCache.get(dailySpendCacheKey("Braga", "EUR", "mid")); ok {
		t.Error("a dropped estimate must not be cached")
	}
}

func TestEstimateDailyFoodSpendMatchesCitiesLoosely(t *testing.T) {
	freshDailySpendCache(t)
	fake := newFakeAnthropic(t)
	// The model is told to echo names verbatim; a case or spacing difference
	// must not lose the city, because the alternative is an empty section for
	// a trip that is perfectly answerable.
	fake.scriptNonStreamingTool(dailySpendToolName,
		`{"estimates":[{"city":"  são paulo ","daily_amount":30,"includes":"Coffee, a lunch special, dinner."}]}`)

	got, err := estimateDailyFoodSpend(context.Background(), newAnthropicClient("test-key"),
		[]string{"São Paulo"}, "USD", "budget")
	if err != nil {
		t.Fatalf("estimate: %v", err)
	}
	if got["São Paulo"].DailyAmount != 30 {
		t.Fatalf("case/space difference lost the city: %+v", got)
	}
}

func TestEstimateDailyFoodSpendSendsCurrencyAndTier(t *testing.T) {
	freshDailySpendCache(t)
	fake := newFakeAnthropic(t)
	fake.scriptNonStreamingTool(dailySpendToolName,
		`{"estimates":[{"city":"Oslo","daily_amount":900,"includes":"Bakery, canteen lunch, dinner."}]}`)

	if _, err := estimateDailyFoodSpend(context.Background(), newAnthropicClient("test-key"),
		[]string{"Oslo"}, "NOK", "budget"); err != nil {
		t.Fatalf("estimate: %v", err)
	}
	bodies := fake.requestBodies()
	if len(bodies) != 1 {
		t.Fatalf("want one call, got %d", len(bodies))
	}
	sent := string(bodies[0])
	// The currency is OURS and travels one way only — nothing reads a currency
	// back out of the answer, because there is no FX anywhere in this app.
	for _, want := range []string{"NOK", "budget", "Oslo"} {
		if !strings.Contains(sent, want) {
			t.Errorf("request should state %q: %s", want, sent)
		}
	}
	var req struct {
		ToolChoice struct {
			Name string `json:"name"`
		} `json:"tool_choice"`
	}
	if err := json.Unmarshal(bodies[0], &req); err != nil {
		t.Fatalf("parse request: %v", err)
	}
	if req.ToolChoice.Name != dailySpendToolName {
		t.Errorf("tool must be forced, got tool_choice %q", req.ToolChoice.Name)
	}
}

func TestEstimateDailyFoodSpendProviderFailure(t *testing.T) {
	freshDailySpendCache(t)
	fake := newFakeAnthropic(t)
	fake.scriptNonStreamingHTTPError(400, "invalid_request_error", "credit balance too low")

	got, err := estimateDailyFoodSpend(context.Background(), newAnthropicClient("test-key"),
		[]string{"Lima"}, "USD", "mid")
	if err == nil {
		t.Fatal("a failed provider call must be reported, not swallowed")
	}
	if len(got) != 0 {
		t.Fatalf("nothing to show: %+v", got)
	}
}

// A model that answers without calling the forced tool is a failure, not an
// empty result: silently returning zero cities would read to the handler as
// "this trip has no answerable cities".
func TestEstimateDailyFoodSpendNoToolCall(t *testing.T) {
	freshDailySpendCache(t)
	newFakeAnthropic(t) // default non-streaming answer is text-only

	if _, err := estimateDailyFoodSpend(context.Background(), newAnthropicClient("test-key"),
		[]string{"Quito"}, "USD", "mid"); err == nil {
		t.Fatal("want an error when the model returns no tool_use block")
	}
}
