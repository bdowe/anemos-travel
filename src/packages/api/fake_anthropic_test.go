package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"unicode/utf8"
)

// fake_anthropic_test.go — a reusable, scriptable stand-in for the Anthropic
// API behind the ANTHROPIC_BASE_URL seam (anthropic_client.go).
//
// Construct it with a sequence of scripted assistant turns; each streaming
// /v1/messages call is answered with the turn matching how far the tool loop
// has progressed. Turn selection is keyed off the REQUEST BODY, not a call
// counter: the number of user messages carrying tool_result blocks equals the
// number of completed tool round-trips, which is exactly the turn index. That
// keeps the fake deterministic when background callers also hit the seam, and
// it means repeated /plan sessions each replay the script from turn 0.
//
// The wire format is accumulator-faithful to anthropic-sdk-go v1.45.0
// (messageutil.go): message_start carries the message envelope,
// content_block_start opens each block (tool_use input starts as the literal
// `{}` the accumulator replaces), deltas arrive as text_delta /
// input_json_delta partials split across frames, message_delta carries the
// stop_reason, message_stop closes. Text and tool input are deliberately
// split into multiple delta frames so tests exercise real accumulation, not
// single-frame shortcuts.
//
// NON-streaming calls (no "stream":true in the body) are served too, because
// the /plan flow's background profile distiller (profile_distiller.go) and
// the admin ingest's extraction (local_extraction_service.go) share the seam
// and use client.Messages.New. The default non-streaming answer is a harmless
// text-only end_turn message (the forced-tool callers find no tool_use block
// and no-op); scriptNonStreamingTool swaps in a forced-tool response for
// tests that exercise those callers directly.
//
// Anything else — wrong path, wrong method, an unscripted turn — fails the
// test loudly and returns 500.

// fakeTurn is one scripted assistant turn for a streaming call.
type fakeTurn struct {
	kind       string // "text" | "tool" | "textThenTool" | "error" | "httpError"
	httpStatus int    // httpError only
	errType    string // httpError only, e.g. "invalid_request_error"
	text       string
	toolName   string
	toolInput  string // raw JSON object
	errMsg     string
}

// textTurn streams the given text (split across multiple text_delta frames)
// and ends the conversation with stop_reason end_turn.
func textTurn(text string) fakeTurn { return fakeTurn{kind: "text", text: text} }

// toolTurn requests the named tool with the given JSON input, streamed as
// split input_json_delta partials, and stops with stop_reason tool_use.
func toolTurn(name, inputJSON string) fakeTurn {
	return fakeTurn{kind: "tool", toolName: name, toolInput: inputJSON}
}

// textThenToolTurn streams a text block then a tool_use block in one
// assistant turn (the "Let me check…" + tool-call shape real turns take),
// stopping with stop_reason tool_use.
func textThenToolTurn(text, name, inputJSON string) fakeTurn {
	return fakeTurn{kind: "textThenTool", text: text, toolName: name, toolInput: inputJSON}
}

// errorTurn starts a normal text answer, then kills the stream mid-turn with
// an SSE `error` event (the shape a real overloaded_error takes on the wire),
// so stream.Err() fires client-side.
func errorTurn(message string) fakeTurn { return fakeTurn{kind: "error", errMsg: message} }

// httpErrorTurn answers the streaming call with a non-2xx status and an
// Anthropic error JSON body before any SSE frames — the shape the real
// credit-balance 400 took. Surfaces as a typed *anthropic.Error from
// stream.Err() on the first Next(). Use non-retryable statuses (400/401/403):
// the SDK auto-retries 408/409/429/5xx (max 2), replaying the same turn.
func httpErrorTurn(status int, errType, message string) fakeTurn {
	return fakeTurn{kind: "httpError", httpStatus: status, errType: errType, errMsg: message}
}

type fakeAnthropic struct {
	t   *testing.T
	srv *httptest.Server

	mu               sync.Mutex
	turns            []fakeTurn
	requests         [][]byte
	nonStreamContent json.RawMessage
	nonStreamStop    string
	nonStreamStatus  int    // non-zero => non-streaming calls fail with this status
	nonStreamErrBody string // Anthropic error envelope for nonStreamStatus
}

// newFakeAnthropic starts the fake and points the whole process at it for the
// duration of the test (ANTHROPIC_API_KEY + ANTHROPIC_BASE_URL via t.Setenv).
func newFakeAnthropic(t *testing.T, script ...fakeTurn) *fakeAnthropic {
	t.Helper()
	f := &fakeAnthropic{
		t:                t,
		turns:            script,
		nonStreamContent: json.RawMessage(`[{"type":"text","text":"OK."}]`),
		nonStreamStop:    "end_turn",
	}
	f.srv = httptest.NewServer(http.HandlerFunc(f.handle))
	t.Cleanup(f.srv.Close)
	t.Setenv("ANTHROPIC_API_KEY", "test-key")
	t.Setenv("ANTHROPIC_BASE_URL", f.srv.URL)
	return f
}

// scriptNonStreamingTool makes every non-streaming call answer with a single
// tool_use block — the forced-tool shape profile_distiller.go and
// local_extraction_service.go expect. Streaming turns are unaffected.
func (f *fakeAnthropic) scriptNonStreamingTool(name, inputJSON string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.nonStreamContent = json.RawMessage(fmt.Sprintf(
		`[{"type":"tool_use","id":"toolu_fake_ns","name":%q,"input":%s}]`, name, inputJSON))
	f.nonStreamStop = "tool_use"
}

// scriptNonStreamingHTTPError makes every non-streaming call fail with the
// given status + Anthropic error envelope — the Messages.New analogue of
// httpErrorTurn. Same non-retryable-status caveat applies.
func (f *fakeAnthropic) scriptNonStreamingHTTPError(status int, errType, message string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.nonStreamStatus = status
	f.nonStreamErrBody = fmt.Sprintf(
		`{"type":"error","error":{"type":%q,"message":%q},"request_id":"req_fake_err"}`, errType, message)
}

// requestBodies returns a copy of every /v1/messages request body received,
// in arrival order — for asserting what round-tripped back to the "model".
func (f *fakeAnthropic) requestBodies() [][]byte {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([][]byte, len(f.requests))
	copy(out, f.requests)
	return out
}

func (f *fakeAnthropic) handle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || r.URL.Path != "/v1/messages" {
		f.t.Errorf("fake anthropic: unexpected request %s %s", r.Method, r.URL.Path)
		http.Error(w, "unexpected path", http.StatusInternalServerError)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		f.t.Errorf("fake anthropic: read body: %v", err)
		http.Error(w, "bad body", http.StatusInternalServerError)
		return
	}

	f.mu.Lock()
	f.requests = append(f.requests, body)
	turns := f.turns
	nonStreamContent := f.nonStreamContent
	nonStreamStop := f.nonStreamStop
	nonStreamStatus := f.nonStreamStatus
	nonStreamErrBody := f.nonStreamErrBody
	f.mu.Unlock()

	var req struct {
		Stream   bool `json:"stream"`
		Messages []struct {
			Role    string          `json:"role"`
			Content json.RawMessage `json:"content"`
		} `json:"messages"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		f.t.Errorf("fake anthropic: unparseable request body: %v", err)
		http.Error(w, "bad json", http.StatusInternalServerError)
		return
	}

	if !req.Stream {
		w.Header().Set("Content-Type", "application/json")
		if nonStreamStatus != 0 {
			w.Header().Set("request-id", "req_fake_err")
			w.WriteHeader(nonStreamStatus)
			io.WriteString(w, nonStreamErrBody)
			return
		}
		fmt.Fprintf(w, `{"id":"msg_fake_ns","type":"message","role":"assistant","model":"claude-sonnet-4-6","content":%s,"stop_reason":%q,"stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":5}}`,
			nonStreamContent, nonStreamStop)
		return
	}

	// Turn index = completed tool round-trips = user messages with tool_result.
	idx := 0
	for _, m := range req.Messages {
		if m.Role == "user" && contentHasToolResult(m.Content) {
			idx++
		}
	}
	if idx >= len(turns) {
		f.t.Errorf("fake anthropic: unscripted streaming turn %d (script has %d turns)", idx, len(turns))
		http.Error(w, "unscripted turn", http.StatusInternalServerError)
		return
	}
	f.streamTurn(w, idx, turns[idx])
}

// contentHasToolResult reports whether a message's content array carries a
// tool_result block. Plain-string content (no blocks) never does.
func contentHasToolResult(content json.RawMessage) bool {
	var blocks []struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(content, &blocks); err != nil {
		return false
	}
	for _, b := range blocks {
		if b.Type == "tool_result" {
			return true
		}
	}
	return false
}

// sseFrame writes one frame in the anthropic SSE wire format.
func (f *fakeAnthropic) sseFrame(w http.ResponseWriter, event string, data any) {
	b, err := json.Marshal(data)
	if err != nil {
		f.t.Errorf("fake anthropic: marshal %s frame: %v", event, err)
		return
	}
	io.WriteString(w, "event: "+event+"\ndata: "+string(b)+"\n\n")
}

func (f *fakeAnthropic) streamTurn(w http.ResponseWriter, idx int, turn fakeTurn) {
	// A pre-stream HTTP failure never opens the SSE stream: status + error
	// body only, exactly like the real credit-balance 400.
	if turn.kind == "httpError" {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("request-id", "req_fake_err")
		w.WriteHeader(turn.httpStatus)
		fmt.Fprintf(w, `{"type":"error","error":{"type":%q,"message":%q},"request_id":"req_fake_err"}`,
			turn.errType, turn.errMsg)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.WriteHeader(http.StatusOK)

	f.sseFrame(w, "message_start", map[string]any{
		"type": "message_start",
		"message": map[string]any{
			"id": fmt.Sprintf("msg_fake_%d", idx), "type": "message", "role": "assistant",
			"model": "claude-sonnet-4-6", "content": []any{},
			"stop_reason": nil, "stop_sequence": nil,
			"usage": map[string]any{"input_tokens": 10, "output_tokens": 0},
		},
	})

	blockDelta := func(blockIdx int, delta map[string]any) {
		f.sseFrame(w, "content_block_delta", map[string]any{
			"type": "content_block_delta", "index": blockIdx, "delta": delta,
		})
	}

	stopReason := "end_turn"
	lastBlock := 0
	switch turn.kind {
	case "text":
		f.sseFrame(w, "content_block_start", map[string]any{
			"type": "content_block_start", "index": 0,
			"content_block": map[string]any{"type": "text", "text": ""},
		})
		for _, chunk := range splitForStreaming(turn.text) {
			blockDelta(0, map[string]any{"type": "text_delta", "text": chunk})
		}

	case "tool":
		stopReason = "tool_use"
		f.sseFrame(w, "content_block_start", map[string]any{
			"type": "content_block_start", "index": 0,
			"content_block": map[string]any{
				"type": "tool_use", "id": fmt.Sprintf("toolu_fake_%d", idx),
				"name": turn.toolName, "input": map[string]any{},
			},
		})
		for _, chunk := range splitForStreaming(turn.toolInput) {
			blockDelta(0, map[string]any{"type": "input_json_delta", "partial_json": chunk})
		}

	case "textThenTool":
		stopReason = "tool_use"
		f.sseFrame(w, "content_block_start", map[string]any{
			"type": "content_block_start", "index": 0,
			"content_block": map[string]any{"type": "text", "text": ""},
		})
		for _, chunk := range splitForStreaming(turn.text) {
			blockDelta(0, map[string]any{"type": "text_delta", "text": chunk})
		}
		f.sseFrame(w, "content_block_stop", map[string]any{"type": "content_block_stop", "index": 0})
		f.sseFrame(w, "content_block_start", map[string]any{
			"type": "content_block_start", "index": 1,
			"content_block": map[string]any{
				"type": "tool_use", "id": fmt.Sprintf("toolu_fake_%d", idx),
				"name": turn.toolName, "input": map[string]any{},
			},
		})
		for _, chunk := range splitForStreaming(turn.toolInput) {
			blockDelta(1, map[string]any{"type": "input_json_delta", "partial_json": chunk})
		}
		lastBlock = 1

	case "error":
		// Start a real answer, then die mid-turn: the client sees the leading
		// delta and then stream.Err().
		f.sseFrame(w, "content_block_start", map[string]any{
			"type": "content_block_start", "index": 0,
			"content_block": map[string]any{"type": "text", "text": ""},
		})
		blockDelta(0, map[string]any{"type": "text_delta", "text": "One moment"})
		f.sseFrame(w, "error", map[string]any{
			"type":  "error",
			"error": map[string]any{"type": "overloaded_error", "message": turn.errMsg},
		})
		return

	default:
		f.t.Errorf("fake anthropic: unknown turn kind %q", turn.kind)
		return
	}

	f.sseFrame(w, "content_block_stop", map[string]any{"type": "content_block_stop", "index": lastBlock})
	f.sseFrame(w, "message_delta", map[string]any{
		"type":  "message_delta",
		"delta": map[string]any{"stop_reason": stopReason, "stop_sequence": nil},
		"usage": map[string]any{"output_tokens": 7},
	})
	f.sseFrame(w, "message_stop", map[string]any{"type": "message_stop"})
}

// splitForStreaming cuts s into two rune-safe halves so every scripted turn
// arrives as MULTIPLE delta frames — tests that pass against this fake prove
// the client accumulates partial frames, not just whole payloads.
func splitForStreaming(s string) []string {
	if utf8.RuneCountInString(s) < 2 {
		return []string{s}
	}
	runes := []rune(s)
	mid := len(runes) / 2
	return []string{string(runes[:mid]), string(runes[mid:])}
}
