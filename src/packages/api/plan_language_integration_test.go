package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The response-language instruction (specs/i18n-spanish) is the one change in
// this feature that touches the model's input, so it gets the strictest test in
// the suite: English requests must produce a byte-for-byte unchanged system
// prompt, and Spanish must add the instruction and nothing else.

// systemPromptFrom pulls the single system block out of a captured
// /v1/messages request body.
func systemPromptFrom(t *testing.T, body []byte) string {
	t.Helper()
	var req struct {
		System []struct {
			Text string `json:"text"`
		} `json:"system"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		t.Fatalf("decode request body: %v", err)
	}
	if len(req.System) != 1 {
		t.Fatalf("system blocks = %d, want 1", len(req.System))
	}
	return req.System[0].Text
}

// planWithLocale drives /plan with an explicit Accept-Language and returns the
// system prompt the model received.
func planWithLocale(t *testing.T, acceptLanguage string) string {
	t.Helper()
	fa := newFakeAnthropic(t, textTurn("ok"))

	body, err := json.Marshal(PlanRequest{
		ChatID:   "chat-lang",
		Messages: []PlanChatMessage{{Role: "user", Content: "hola"}},
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	req := httptest.NewRequest("POST", "/api/v1/plan", strings.NewReader(string(body)))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Forwarded-For", nextTestIP())
	if acceptLanguage != "" {
		req.Header.Set("Accept-Language", acceptLanguage)
	}
	rec := httptest.NewRecorder()
	testRouter.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("/plan = %d: %s", rec.Code, rec.Body.String())
	}
	bodies := fa.requestBodies()
	if len(bodies) == 0 {
		t.Fatal("fake anthropic received no requests")
	}
	return systemPromptFrom(t, bodies[0])
}

// The load-bearing regression test: English behavior must be untouched by the
// whole i18n feature. If this fails, English users' prompt-cache prefix and
// model behavior have changed. (basePrompt itself may still evolve — e.g. the
// suggest_replies instruction, specs/chat-quick-replies, was a deliberate
// one-time cache re-warm — but never via the locale path.)
func TestSystemPromptEnglishUnchanged(t *testing.T) {
	resetDB(t)
	for _, header := range []string{"", "en", "en-US,en;q=0.9", "fr"} {
		prompt := planWithLocale(t, header)
		if strings.Contains(prompt, "Respond in") {
			t.Errorf("Accept-Language %q: English prompt gained a language instruction:\n%s",
				header, prompt)
		}
		// Positive pin: the quick-replies behavioral instruction is part of
		// the English basePrompt for every locale header.
		if !strings.Contains(prompt, "call suggest_replies") {
			t.Errorf("Accept-Language %q: prompt lost the suggest_replies instruction", header)
		}
		// Positive pins: flight searches default to one-way and quoted prices
		// must be labeled (trip type + party size) — the price-semantics fix.
		// Both sentences matter: the second guards non-tool turns where the
		// model quotes prices without a fresh summarizeOffers header.
		if !strings.Contains(prompt, "Search one-way by default") {
			t.Errorf("Accept-Language %q: prompt lost the one-way-default flight instruction", header)
		}
		if !strings.Contains(prompt, "never present a party or round-trip total as a per-person one-way fare") {
			t.Errorf("Accept-Language %q: prompt lost the price-labeling flight instruction", header)
		}
		// A tool the model is never told to reach for is a tool that doesn't
		// exist. set_trip_origin was added because the agent had no way to
		// change where a trip departs from and improvised a duplicate
		// checklist item instead; deleting this instruction while the tool
		// stays registered would restore that behaviour silently.
		if !strings.Contains(prompt, "call set_trip_origin") {
			t.Errorf("Accept-Language %q: prompt lost the trip-origin instruction", header)
		}
		if !strings.Contains(prompt, "never add a second checklist item for a leg the trip already has") {
			t.Errorf("Accept-Language %q: prompt lost the no-duplicate-leg rule", header)
		}
		// Positive pin: the last day belongs to the journey home, and how
		// much of it survives depends on the departure time. Without this the
		// planner books a museum, a house tour and a cocktail bar on the day
		// the traveler flies out — while the app's own review code has
		// counted that day unplannable all along (walkDayCoverage).
		if !strings.Contains(prompt, "The trip's LAST day is the day the traveler journeys home") {
			t.Errorf("Accept-Language %q: prompt lost the travel-day instruction", header)
		}
		// Its companion: the same turn that stops over-filling the travel day
		// must stop UNDER-filling the real ones, or the plan just gets thinner.
		if !strings.Contains(prompt, "Fill the real days first") {
			t.Errorf("Accept-Language %q: prompt lost the empty-middle-day instruction", header)
		}
		// specs/shape-before-schedule. The friction this answers: "it pulls the
		// list of activities without confirming with me... I just want to get
		// the high level structure done first". Each pin below guards one
		// sentence whose removal restores that behaviour silently.
		//
		// The two-pass rule itself, and its hard stop. Without them the planner
		// goes straight back to researching places on turn 1 and saving a full
		// day-by-day itinerary nobody agreed to.
		if !strings.Contains(prompt, "plan in TWO passes and never skip the first") {
			t.Errorf("Accept-Language %q: prompt lost the two-pass planning rule", header)
		}
		if !strings.Contains(prompt, "do NOT call create_itinerary: nothing is saved until the traveler says yes") {
			t.Errorf("Accept-Language %q: prompt lost the shape turn's hard stop", header)
		}
		// The shape turn is the one turn quick replies are both allowed and
		// wanted — runSuggestRepliesTool refuses them once an itinerary has been
		// emitted, so if this goes, adjusting the shape stops being one tap.
		if !strings.Contains(prompt, "call suggest_replies with the changes they are most likely to want") {
			t.Errorf("Accept-Language %q: prompt lost the shape-turn quick replies", header)
		}
		// The load-bearing half of the spine. A city with nothing on the day the
		// traveler leaves renders as though they left the day they arrived, and
		// the next city absorbs its nights (TestComputeTripLegsArrivalOnly...
		// pins that output). Nothing downstream can repair it.
		if !strings.Contains(prompt, "The move-on place is NOT optional") {
			t.Errorf("Accept-Language %q: prompt lost the move-on-place rule", header)
		}
		// The gate itself: agreement authorizes the write, not the model's own
		// sense of having found enough places.
		if !strings.Contains(prompt, "only once the traveler has AGREED to the shape") {
			t.Errorf("Accept-Language %q: prompt lost the create_itinerary agreement gate", header)
		}
		// A spine's highest day number is the final city's ARRIVAL, so an
		// omitted end_date saves the trip days short (create_itinerary refuses
		// it outright — this keeps the model from getting there).
		if !strings.Contains(prompt, "Pass start_date AND end_date EVERY time") {
			t.Errorf("Accept-Language %q: prompt lost the always-send-both-dates rule", header)
		}
		// City-name placeholders get MORE dangerous under a spine: isCityFiller
		// hides them on the page while computeTripLegs still counts them, so a
		// filler anchor pegs a leg's dates to a row the traveler cannot see.
		if !strings.Contains(prompt, "never emit a location whose name is just the city itself") {
			t.Errorf("Accept-Language %q: prompt lost the no-placeholder-place rule", header)
		}
		// The OTHER end of the trip: an overnight outbound leaves the calendar
		// day before it lands, so the departure day is not the trip's first
		// day. The absolute (say nothing you don't know) comes first on
		// purpose — buried behind the detail, the model averages the two.
		if !strings.Contains(prompt, "never state a date the traveler leaves home unless you actually know it") {
			t.Errorf("Accept-Language %q: prompt lost the unknown-departure rule", header)
		}
		if !strings.Contains(prompt, "the CALENDAR DAY BEFORE it lands") {
			t.Errorf("Accept-Language %q: prompt lost the overnight-outbound instruction", header)
		}
		// A trip's description used to be write-once, so a blurb describing
		// three cities outlived the trip growing to five. Both halves are
		// pinned: the instruction to fix a stale one, and the boundary that
		// stops the planner replacing prose the traveler wrote. Deleting the
		// second while the tool stays registered is how "I rewrote your words"
		// would come back.
		if !strings.Contains(prompt, "call set_trip_description with reason 'traveler_asked'") {
			t.Errorf("Accept-Language %q: prompt lost the trip-description instruction", header)
		}
		if !strings.Contains(prompt, "one the TRAVELER wrote is theirs") {
			t.Errorf("Accept-Language %q: prompt lost the traveler-authored-description boundary", header)
		}
		// These requests are anonymous and not trip-bound, so the prompt is
		// exactly basePrompt — it must still end on basePrompt's final
		// sentence, proving nothing was appended.
		if !strings.HasSuffix(prompt, "no headings or tables.") {
			t.Errorf("Accept-Language %q: prompt does not end with basePrompt's "+
				"final sentence — something was appended:\n...%s", header,
				prompt[max(0, len(prompt)-160):])
		}
	}
}

// Spanish adds the instruction, and adds it to the END so the cached prefix
// (tools + basePrompt) is otherwise identical.
func TestSystemPromptSpanishAddsLanguageInstruction(t *testing.T) {
	resetDB(t)
	english := planWithLocale(t, "en")
	spanish := planWithLocale(t, "es-MX,es;q=0.9")

	if !strings.HasPrefix(spanish, english) {
		t.Fatal("Spanish prompt is not the English prompt plus a suffix; the shared prefix changed")
	}
	added := strings.TrimPrefix(spanish, english)
	for _, want := range []string{
		"Respond in Spanish (español)",
		"YYYY-MM-DD",
		"If the traveler writes in another language",
	} {
		if !strings.Contains(added, want) {
			t.Errorf("Spanish instruction missing %q; got:\n%s", want, added)
		}
	}
}

// The instruction is a pure function of the locale, so its English no-op and
// its per-locale wording are worth pinning without a DB or a fake server.
func TestResponseLanguageInstruction(t *testing.T) {
	if got := responseLanguageInstruction("en"); got != "" {
		t.Errorf("English instruction = %q, want empty", got)
	}
	es := responseLanguageInstruction("es")
	if !strings.Contains(es, "Spanish (español)") {
		t.Errorf("Spanish instruction = %q", es)
	}
	// Unsupported locales must not silently instruct the model in a language
	// the app cannot render.
	if got := responseLanguageInstruction("zz"); !strings.Contains(got, "English") {
		t.Errorf("unknown locale instruction = %q, want the English name", got)
	}
}
