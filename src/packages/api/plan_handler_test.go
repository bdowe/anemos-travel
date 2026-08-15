package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"travel-route-planner/store"
)

func TestPersonalizedSystemPromptNilPrefs(t *testing.T) {
	if got := personalizedSystemPrompt("base", nil); got != "base" {
		t.Fatalf("prompt = %q, want base unchanged", got)
	}
}

func TestPersonalizedSystemPromptEmptyPrefs(t *testing.T) {
	if got := personalizedSystemPrompt("base", &store.TravelerPreference{}); got != "base" {
		t.Fatalf("prompt = %q, want base unchanged", got)
	}
}

func TestPersonalizedSystemPromptIncludesNotesAlone(t *testing.T) {
	p := &store.TravelerPreference{ProfileNotes: strPtr("- vegetarian\n- travels with kids")}
	got := personalizedSystemPrompt("base", p)
	if !strings.Contains(got, "Traveler profile notes (maintained by you):\n- vegetarian\n- travels with kids") {
		t.Fatalf("prompt missing notes block: %q", got)
	}
	if strings.Contains(got, "Traveler preferences —") {
		t.Fatalf("prompt should have no preferences line when fields are unset: %q", got)
	}
}

func TestPersonalizedSystemPromptCombinesFieldsAndNotes(t *testing.T) {
	p := &store.TravelerPreference{
		Budget:       strPtr("mid"),
		ProfileNotes: strPtr("- prefers boutique stays"),
	}
	got := personalizedSystemPrompt("base", p)
	if !strings.Contains(got, "budget: mid") {
		t.Fatalf("prompt missing budget: %q", got)
	}
	if !strings.Contains(got, "- prefers boutique stays") {
		t.Fatalf("prompt missing notes: %q", got)
	}
}

func TestPersonalizedSystemPromptIgnoresWhitespaceNotes(t *testing.T) {
	p := &store.TravelerPreference{ProfileNotes: strPtr("  \n ")}
	if got := personalizedSystemPrompt("base", p); got != "base" {
		t.Fatalf("prompt = %q, want base unchanged for blank notes", got)
	}
}

func TestPersonalizedSystemPromptWorkStyleNomad(t *testing.T) {
	p := &store.TravelerPreference{WorkStyle: strPtr("digital_nomad")}
	got := personalizedSystemPrompt("base", p)
	if !strings.Contains(got, "work style: digital nomad (works remotely while traveling)") {
		t.Fatalf("prompt missing nomad parts line: %q", got)
	}
	if !strings.Contains(got, "reliable wifi") || !strings.Contains(got, "digital-nomad visas") {
		t.Fatalf("prompt missing nomad guidance note: %q", got)
	}
}

func TestPersonalizedSystemPromptWorkStyleWorkation(t *testing.T) {
	p := &store.TravelerPreference{WorkStyle: strPtr("workation")}
	got := personalizedSystemPrompt("base", p)
	if !strings.Contains(got, "work style: sometimes works on trips") {
		t.Fatalf("prompt missing workation parts line: %q", got)
	}
	if !strings.Contains(got, "unscheduled blocks for work") {
		t.Fatalf("prompt missing workation note: %q", got)
	}
	if strings.Contains(got, "digital-nomad visas") {
		t.Fatalf("workation must not get the full nomad note: %q", got)
	}
}

func TestPersonalizedSystemPromptWorkStyleLeisure(t *testing.T) {
	p := &store.TravelerPreference{WorkStyle: strPtr("leisure_only")}
	got := personalizedSystemPrompt("base", p)
	if !strings.Contains(got, "work style: leisure only — trips are time off") {
		t.Fatalf("prompt missing leisure parts line: %q", got)
	}
	if strings.Contains(got, "reliable wifi") {
		t.Fatalf("leisure_only must not get a work note: %q", got)
	}
}

// --- specs/active-profile -------------------------------------------------
// Each field's value must produce a concrete instruction, not just a tag: the
// whole point is that the profile changes what the agent DOES.

func TestPersonalizedSystemPromptFitnessGym(t *testing.T) {
	p := &store.TravelerPreference{FitnessRoutine: strPtr("gym")}
	got := personalizedSystemPrompt("base", p)
	if !strings.Contains(got, "fitness: needs gym access") {
		t.Fatalf("prompt missing gym parts line: %q", got)
	}
	for _, want := range []string{"on-site gym", "search_nearby", "day passes", "add_packing_item"} {
		if !strings.Contains(got, want) {
			t.Fatalf("gym note missing %q: %q", want, got)
		}
	}
	if strings.Contains(got, "poor place to run") {
		t.Fatalf("gym must not get the running note: %q", got)
	}
}

func TestPersonalizedSystemPromptFitnessRunning(t *testing.T) {
	p := &store.TravelerPreference{FitnessRoutine: strPtr("running")}
	got := personalizedSystemPrompt("base", p)
	if !strings.Contains(got, "fitness: runs while traveling") {
		t.Fatalf("prompt missing running parts line: %q", got)
	}
	for _, want := range []string{"rough distance", "poor place to run", "add_packing_item"} {
		if !strings.Contains(got, want) {
			t.Fatalf("running note missing %q: %q", want, got)
		}
	}
	if strings.Contains(got, "day passes") {
		t.Fatalf("running must not get the gym note: %q", got)
	}
}

func TestPersonalizedSystemPromptFitnessBoth(t *testing.T) {
	p := &store.TravelerPreference{FitnessRoutine: strPtr("both")}
	got := personalizedSystemPrompt("base", p)
	if !strings.Contains(got, "fitness: gym and running") {
		t.Fatalf("prompt missing both parts line: %q", got)
	}
	for _, want := range []string{"on-site gym", "running route", "add_packing_item"} {
		if !strings.Contains(got, want) {
			t.Fatalf("both note missing %q: %q", want, got)
		}
	}
}

// "none" is an answer, not an absence: it says so on the parts line and then
// stays silent, the same shape leisure_only takes.
func TestPersonalizedSystemPromptFitnessNone(t *testing.T) {
	p := &store.TravelerPreference{FitnessRoutine: strPtr("none")}
	got := personalizedSystemPrompt("base", p)
	if !strings.Contains(got, "fitness: not a factor") {
		t.Fatalf("prompt missing none parts line: %q", got)
	}
	if strings.Contains(got, "add_packing_item") || strings.Contains(got, "on-site gym") {
		t.Fatalf("none must not get a fitness note: %q", got)
	}
}

// The state-the-numbers rule is what makes a mismatched suggestion falsifiable
// (docs/zen.md), so it must ride EVERY band, not just the hard one.
func TestPersonalizedSystemPromptOutdoorIntensityBands(t *testing.T) {
	cases := map[string]string{
		"easy":        "outdoor days: easy",
		"moderate":    "outdoor days: moderate",
		"challenging": "outdoor days: challenging",
	}
	for value, partsLine := range cases {
		t.Run(value, func(t *testing.T) {
			p := &store.TravelerPreference{OutdoorIntensity: strPtr(value)}
			got := personalizedSystemPrompt("base", p)
			if !strings.Contains(got, partsLine) {
				t.Fatalf("prompt missing parts line %q: %q", partsLine, got)
			}
			if !strings.Contains(got, "state the distance, the elevation gain and roughly how long it takes") {
				t.Fatalf("%s band missing the state-the-numbers rule: %q", value, got)
			}
		})
	}
}

func TestPersonalizedSystemPromptCompanions(t *testing.T) {
	solo := personalizedSystemPrompt("base", &store.TravelerPreference{Companions: strPtr("solo")})
	if !strings.Contains(solo, "traveling: solo") || !strings.Contains(solo, "for one person") {
		t.Fatalf("solo prompt missing line or note: %q", solo)
	}
	kids := personalizedSystemPrompt("base", &store.TravelerPreference{Companions: strPtr("family_with_kids")})
	if !strings.Contains(kids, "traveling: with kids") || !strings.Contains(kids, "shorter transfers") {
		t.Fatalf("family prompt missing line or note: %q", kids)
	}
	// partner/varies are facts worth stating with nothing extra to instruct.
	partner := personalizedSystemPrompt("base", &store.TravelerPreference{Companions: strPtr("partner")})
	if !strings.Contains(partner, "traveling: as a couple") {
		t.Fatalf("partner prompt missing parts line: %q", partner)
	}
	if strings.Contains(partner, "shorter transfers") || strings.Contains(partner, "for one person") {
		t.Fatalf("partner must not borrow another value's note: %q", partner)
	}
}

// The bag tier is the one preference the model never has to act on —
// search_flights resolves it server-side — so its note exists to explain the
// prices the tool hands back, and each value has to explain a different thing.
func TestPersonalizedSystemPromptBaggage(t *testing.T) {
	cases := map[string]struct{ partsLine, note string }{
		baggagePersonalItem: {"packs: one personal item", "quoted as bare fares"},
		baggageCarryOn:      {"packs: a carry-on", "already cover their cabin bag"},
		baggageChecked:      {"packs: a checked bag", "is not the price they pay"},
	}
	for value, want := range cases {
		t.Run(value, func(t *testing.T) {
			got := personalizedSystemPrompt("base", &store.TravelerPreference{Baggage: strPtr(value)})
			if !strings.Contains(got, want.partsLine) {
				t.Fatalf("prompt missing parts line %q: %q", want.partsLine, got)
			}
			if !strings.Contains(got, want.note) {
				t.Fatalf("prompt missing note %q: %q", want.note, got)
			}
		})
	}
	// An unset tier says nothing — the default lives in one place, and it is
	// not the prompt.
	if got := personalizedSystemPrompt("base", &store.TravelerPreference{}); strings.Contains(got, "packs:") {
		t.Fatalf("unset baggage must add nothing: %q", got)
	}
}

// Companions has a column now, so the standing notes rule must stop naming it —
// otherwise the agent writes the same fact into profile_notes as well.
func TestProfileNotesInstructionOmitsCompanions(t *testing.T) {
	if strings.Contains(profileNotesInstruction, "companions") {
		t.Fatalf("profileNotesInstruction still names companions: %q", profileNotesInstruction)
	}
	if !strings.Contains(profileNotesInstruction, "dietary needs") {
		t.Fatalf("profileNotesInstruction lost its remaining free-text fields: %q", profileNotesInstruction)
	}
}

// runPlanHandler posts a PlanRequest to planHandler directly (the recorder
// implements http.Flusher, which the SSE handler requires) and returns the
// raw event-stream body.
func runPlanHandler(t *testing.T, req PlanRequest) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	rec := httptest.NewRecorder()
	planHandler(rec, httptest.NewRequest("POST", "/api/v1/plan", bytes.NewReader(body)))
	return rec
}

// Oversized histories must be rejected with a friendly SSE error event (the
// stream's normal error shape), before any model call or session bookkeeping.
func TestPlanHandlerRejectsTooManyMessages(t *testing.T) {
	msgs := make([]PlanChatMessage, planMaxMessages+1)
	for i := range msgs {
		msgs[i] = PlanChatMessage{Role: "user", Content: "hi"}
	}
	rec := runPlanHandler(t, PlanRequest{Messages: msgs})

	out := rec.Body.String()
	if !strings.Contains(out, `"type":"error"`) {
		t.Fatalf("stream = %q, want an SSE error event", out)
	}
	if !strings.Contains(out, "too long") || !strings.Contains(out, "start a new chat") {
		t.Fatalf("stream = %q, want the conversation-too-long message", out)
	}
	if strings.Count(out, "data: ") != 1 {
		t.Fatalf("stream = %q, want exactly one event (handler must stop after rejecting)", out)
	}
}

func TestPlanHandlerRejectsOversizedMessage(t *testing.T) {
	rec := runPlanHandler(t, PlanRequest{Messages: []PlanChatMessage{
		{Role: "user", Content: strings.Repeat("a", planMaxMessageChars+1)},
	}})

	out := rec.Body.String()
	if !strings.Contains(out, `"type":"error"`) || !strings.Contains(out, "too long") {
		t.Fatalf("stream = %q, want an SSE error event about an oversized message", out)
	}
	if strings.Count(out, "data: ") != 1 {
		t.Fatalf("stream = %q, want exactly one event", out)
	}
}

func TestPlanHandlerRejectsOversizedSummary(t *testing.T) {
	rec := runPlanHandler(t, PlanRequest{
		Summary:  strings.Repeat("a", planMaxMessageChars+1),
		Messages: []PlanChatMessage{{Role: "user", Content: "hi"}},
	})

	out := rec.Body.String()
	if !strings.Contains(out, `"type":"error"`) || !strings.Contains(out, "too long") {
		t.Fatalf("stream = %q, want an SSE error event about an oversized summary", out)
	}
	if strings.Count(out, "data: ") != 1 {
		t.Fatalf("stream = %q, want exactly one event", out)
	}
}

func TestNotesPreview(t *testing.T) {
	if got := notesPreview(nil); got != "" {
		t.Fatalf("preview = %q, want empty for nil", got)
	}
	if got := notesPreview(strPtr("short")); got != "short" {
		t.Fatalf("preview = %q", got)
	}
	long := strings.Repeat("é", 100)
	got := notesPreview(&long)
	if r := []rune(got); len(r) != 81 || !strings.HasSuffix(got, "…") {
		t.Fatalf("preview should be 80 runes + ellipsis, got %d runes: %q", len([]rune(got)), got)
	}
}

// relayCutBody simulates a reverse proxy forwarding the request body
// unbuffered (proxy_request_buffering off): the moment the handler commits
// any response bytes, the proxy stops relaying the body and the handler's
// reads hit EOF. This is exactly what nginx does — "upstream sent response
// while sending request body" — and what broke prod chat on 2026-08-12.
type relayCutBody struct {
	data      *bytes.Reader
	committed *atomic.Bool
}

func (b *relayCutBody) Read(p []byte) (int, error) {
	if b.committed.Load() {
		return 0, io.EOF
	}
	return b.data.Read(p)
}

func (b *relayCutBody) Close() error { return nil }

// commitTrackingRecorder arms the relay cut on the first Write, WriteHeader,
// or Flush. Embedding *httptest.ResponseRecorder keeps it an http.Flusher,
// so planHandler's streaming assert passes.
type commitTrackingRecorder struct {
	*httptest.ResponseRecorder
	committed *atomic.Bool
}

func (w *commitTrackingRecorder) Write(p []byte) (int, error) {
	w.committed.Store(true)
	return w.ResponseRecorder.Write(p)
}

func (w *commitTrackingRecorder) WriteHeader(code int) {
	w.committed.Store(true)
	w.ResponseRecorder.WriteHeader(code)
}

func (w *commitTrackingRecorder) Flush() {
	w.committed.Store(true)
	w.ResponseRecorder.Flush()
}

// planHandler must fully consume the request body BEFORE its first response
// write or flush: a reverse proxy relaying the body unbuffered stops the
// moment the upstream responds, so a decode after the priming flush reads
// EOF and every real-network request dies with "invalid request body" while
// buffered test bodies pass. This test wires the proxy behavior into the
// recorder so that ordering violation fails here instead of on prod.
func TestPlanHandlerReadsBodyBeforeFirstWrite(t *testing.T) {
	anonPlanCounter.resetAll()
	t.Setenv("FREE_ANON_PLAN_PER_DAY", "100")
	// Deterministic post-decode short-circuit (same trick as
	// TestPlanHandlerAnonCapEmitsFriendlySSE): with no key, the handler emits
	// the not-configured error right after the decode + cap checks.
	t.Setenv("ANTHROPIC_API_KEY", "")

	payload, err := json.Marshal(PlanRequest{Messages: []PlanChatMessage{{Role: "user", Content: "hi"}}})
	if err != nil {
		t.Fatal(err)
	}
	var committed atomic.Bool
	req := httptest.NewRequest(http.MethodPost, "/api/v1/plan",
		&relayCutBody{data: bytes.NewReader(payload), committed: &committed})
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Forwarded-For", "203.0.113.77")
	rec := &commitTrackingRecorder{ResponseRecorder: httptest.NewRecorder(), committed: &committed}

	planHandler(rec, req)

	out := rec.Body.String()
	if strings.Contains(out, "invalid request body") {
		t.Fatalf("response committed before the body was fully read:\n%s", out)
	}
	// Positive proof the decode completed and the stream reached post-decode
	// logic — guards against the tripwire silently never engaging.
	if !strings.Contains(out, "ANTHROPIC_API_KEY not configured") {
		t.Fatalf("stream never reached post-decode logic:\n%s", out)
	}
	if !committed.Load() {
		t.Fatal("handler wrote no response at all")
	}
}
