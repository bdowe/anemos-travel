package main

import (
	"context"
	"fmt"
	"strings"
	"testing"
)

func compactorTestMessages(n int) []PlanChatMessage {
	msgs := make([]PlanChatMessage, n)
	for i := range msgs {
		role := "user"
		if i%2 == 1 {
			role = "assistant"
		}
		msgs[i] = PlanChatMessage{Role: role, Content: fmt.Sprintf("message %d", i)}
	}
	return msgs
}

func TestSummaryAsMessage(t *testing.T) {
	m := summaryAsMessage("- 3 travelers")
	if m.Role != "user" {
		t.Fatalf("role = %q, want user", m.Role)
	}
	if !strings.HasPrefix(m.Content, "Summary of the conversation so far") {
		t.Fatalf("content missing summary preamble: %q", m.Content)
	}
	if !strings.HasSuffix(m.Content, "- 3 travelers") {
		t.Fatalf("content missing summary body: %q", m.Content)
	}
}

func TestCompactPlanMessagesFoldsAllButKeepWindow(t *testing.T) {
	fa := newFakeAnthropic(t)
	fa.scriptNonStreamingTool(compactToolName, `{"summary":"- travelers: 3, one vegetarian"}`)
	client := newAnthropicClient("test-key")

	msgs := compactorTestMessages(planCompactThreshold)
	newMsgs, summary, through, err := compactPlanMessages(context.Background(), client, "", msgs)
	if err != nil {
		t.Fatalf("compactPlanMessages: %v", err)
	}
	if summary != "- travelers: 3, one vegetarian" {
		t.Fatalf("summary = %q", summary)
	}
	if want := planCompactThreshold - planCompactKeep; through != want {
		t.Fatalf("through = %d, want %d", through, want)
	}
	if len(newMsgs) != planCompactKeep+1 {
		t.Fatalf("len(newMsgs) = %d, want %d", len(newMsgs), planCompactKeep+1)
	}
	if !strings.HasPrefix(newMsgs[0].Content, "Summary of the conversation so far") {
		t.Fatalf("newMsgs[0] is not the summary message: %q", newMsgs[0].Content)
	}
	if got, want := newMsgs[1].Content, msgs[through].Content; got != want {
		t.Fatalf("first kept message = %q, want %q", got, want)
	}
	if got, want := newMsgs[len(newMsgs)-1].Content, msgs[len(msgs)-1].Content; got != want {
		t.Fatalf("last kept message = %q, want %q", got, want)
	}
}

func TestCompactPlanMessagesSendsOlderMessagesAndPrevSummary(t *testing.T) {
	fa := newFakeAnthropic(t)
	fa.scriptNonStreamingTool(compactToolName, `{"summary":"- merged"}`)
	client := newAnthropicClient("test-key")

	msgs := compactorTestMessages(planCompactThreshold)
	if _, _, _, err := compactPlanMessages(context.Background(), client, "- prior state: Lisbon chosen", msgs); err != nil {
		t.Fatalf("compactPlanMessages: %v", err)
	}

	bodies := fa.requestBodies()
	if len(bodies) != 1 {
		t.Fatalf("expected 1 summarizer call, got %d", len(bodies))
	}
	body := string(bodies[0])
	if !strings.Contains(body, "Previous summary:") || !strings.Contains(body, "prior state: Lisbon chosen") {
		t.Fatalf("summarizer system prompt missing previous summary: %s", body)
	}
	// Only the folded messages go to the summarizer; the keep window stays out.
	if !strings.Contains(body, "message 0") || !strings.Contains(body, fmt.Sprintf("message %d", planCompactThreshold-planCompactKeep-1)) {
		t.Fatalf("summarizer transcript missing folded messages: %s", body)
	}
	if strings.Contains(body, fmt.Sprintf("message %d", planCompactThreshold-planCompactKeep)) {
		t.Fatalf("summarizer transcript should not include kept messages: %s", body)
	}
}

func TestCompactPlanMessagesFailsWhenModelReturnsNoToolCall(t *testing.T) {
	// The fake's default non-streaming answer is text-only — the forced-tool
	// caller finds no record_summary block, which is the failure path.
	newFakeAnthropic(t)
	client := newAnthropicClient("test-key")

	msgs := compactorTestMessages(planCompactThreshold)
	newMsgs, _, _, err := compactPlanMessages(context.Background(), client, "", msgs)
	if err == nil {
		t.Fatal("expected error when no tool call is returned")
	}
	if len(newMsgs) != len(msgs) {
		t.Fatalf("messages must be returned unchanged on failure: got %d, want %d", len(newMsgs), len(msgs))
	}
}

func TestCompactPlanMessagesRefusesTinyHistories(t *testing.T) {
	newFakeAnthropic(t)
	client := newAnthropicClient("test-key")
	msgs := compactorTestMessages(planCompactKeep)
	if _, _, _, err := compactPlanMessages(context.Background(), client, "", msgs); err == nil {
		t.Fatal("expected error when history fits in the keep window")
	}
}

func TestSummarizePlanConversationTruncatesOversizedSummary(t *testing.T) {
	fa := newFakeAnthropic(t)
	huge := strings.Repeat("s", planMaxMessageChars+50)
	fa.scriptNonStreamingTool(compactToolName, fmt.Sprintf(`{"summary":%q}`, huge))
	client := newAnthropicClient("test-key")

	summary, err := summarizePlanConversation(context.Background(), client, "", compactorTestMessages(4))
	if err != nil {
		t.Fatalf("summarizePlanConversation: %v", err)
	}
	if got := len([]rune(summary)); got != planMaxMessageChars {
		t.Fatalf("summary rune length = %d, want %d", got, planMaxMessageChars)
	}
}

func TestSummarizePlanConversationRejectsEmptySummary(t *testing.T) {
	fa := newFakeAnthropic(t)
	fa.scriptNonStreamingTool(compactToolName, `{"summary":"   "}`)
	client := newAnthropicClient("test-key")

	if _, err := summarizePlanConversation(context.Background(), client, "", compactorTestMessages(4)); err == nil {
		t.Fatal("expected error for blank summary")
	}
}

// A fatal provider failure on the non-streaming Messages.New path must reach
// the AI-health tracker (proves the recordAIResult wiring for the compactor —
// the distiller/extractor/importer sites share the identical pattern).
func TestSummarizePlanConversationRecordsFatalHealth(t *testing.T) {
	resetAIHealth(t)
	fa := newFakeAnthropic(t)
	fa.scriptNonStreamingHTTPError(401, "authentication_error", "invalid x-api-key")
	client := newAnthropicClient("test-key")

	if _, err := summarizePlanConversation(context.Background(), client, "", compactorTestMessages(4)); err == nil {
		t.Fatal("expected the provider error to surface")
	}
	s := aiHealth.state()
	if !s.Failing || s.Reason != "authentication" || s.FatalTotal != 1 {
		t.Fatalf("tracker after fatal Messages.New = %+v", s)
	}
}
