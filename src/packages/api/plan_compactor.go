package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	anthropic "github.com/anthropics/anthropic-sdk-go"
)

// plan_compactor.go — automatic conversation compaction for /api/v1/plan.
//
// When a chat's resent history reaches planCompactThreshold messages, the
// handler folds everything but the newest planCompactKeep messages into a
// short state summary via one cheap non-streamed Haiku call (same forced-tool
// pattern as profile_distiller.go), then runs the turn on
// [summary-as-first-user-message] + kept messages. The summary is streamed
// back to the client (SSE `compacted`), which sends it as PlanRequest.Summary
// on later turns instead of the folded messages — so each stretch of history
// is summarized once, not per turn.

const (
	// planCompactThreshold triggers compaction; planCompactKeep messages stay
	// verbatim. Each turn adds 2 wire messages, so post-compaction turns send
	// 1 (summary) + 10 + 2 and compaction re-fires roughly every 6 turns. The
	// keep window always contains the turn's own user message, which keeps the
	// client's retry flow (drop last user message, resend) from ever cutting
	// into summarized history.
	planCompactThreshold = 24
	planCompactKeep      = 10

	// compactTimeout bounds the synchronous summarizer call — the traveler is
	// watching the stream while it runs.
	compactTimeout       = 30 * time.Second
	compactMaxInputChars = 60000
	compactToolName      = "record_summary"

	compactSystemPrompt = "You compress the older part of a trip-planning conversation into a factual state summary so the planning agent can continue seamlessly. " +
		"Call record_summary once. Preserve, when present: travel dates (exact YYYY-MM-DD) and how flexible they are; origin and destination cities and their order; the agreed trip SHAPE if one was proposed — each city in order with its number of nights and its arrival and departure dates — and whether the traveler APPROVED it, asked for a change, or has not answered yet; the stated travel mode (driving, train, bus, flying, ferry); the travelers (count, names, relationships, who they usually travel with); flights discussed and which one was CHOSEN (airline, price, times); ferries, trains, or accommodation chosen; budget level and pace; dietary, accessibility, and interest constraints; whether they work while traveling and any stated work-day constraints (e.g. hours to keep free, wifi needs); any fitness routine they keep on the road (gym access, running) and how demanding they want outdoor days to be; what luggage they fly with (personal item only, carry-on, checked bag); places already agreed into the itinerary and places explicitly rejected (with the reason); whether an itinerary was already created or saved, and which cities have been filled in day by day versus which are still just the spine's two anchor places; and open questions or decisions still pending. " +
		"Never invent details, add suggestions, or editorialize. When the conversation contradicts itself, keep the most recent state. " +
		"If a previous summary is provided, merge it in as prior established state, superseded only by newer messages. " +
		"Format as short labeled bullet lines, under 1500 characters total."
)

// summaryAsMessage renders a compacted summary as the conversation's first
// user message — the shape the model sees whether the summary was just
// produced or arrived from the client on a later turn.
func summaryAsMessage(summary string) PlanChatMessage {
	return PlanChatMessage{
		Role:    "user",
		Content: "Summary of the conversation so far (earlier messages were removed to save space — treat this as established context):\n\n" + summary,
	}
}

// summarizePlanConversation folds the given older messages (plus any previous
// summary) into a new state summary with one non-streamed forced-tool Haiku
// call.
func summarizePlanConversation(ctx context.Context, client anthropic.Client, prevSummary string, older []PlanChatMessage) (string, error) {
	// The distillation transcript is text-only (.Content): attached images on
	// folded messages intentionally leave the model's context here — only the
	// planCompactKeep newest messages keep their images verbatim.
	text := buildDistillationTranscript(older, len(older), compactMaxInputChars)
	if text == "" {
		return "", fmt.Errorf("empty transcript")
	}

	system := compactSystemPrompt
	if strings.TrimSpace(prevSummary) != "" {
		system += "\n\nPrevious summary:\n" + strings.TrimSpace(prevSummary)
	}

	tool := anthropic.ToolParam{
		Name:        compactToolName,
		Description: anthropic.String("Record the compacted conversation summary."),
		InputSchema: anthropic.ToolInputSchemaParam{
			Properties: map[string]any{
				"summary": map[string]any{"type": "string", "description": "The factual state summary as short labeled bullet lines"},
			},
			Required: []string{"summary"},
		},
	}

	resp, err := client.Messages.New(ctx, anthropic.MessageNewParams{
		Model:      aiModelLight(),
		MaxTokens:  1024,
		System:     []anthropic.TextBlockParam{{Text: system}},
		Tools:      []anthropic.ToolUnionParam{{OfTool: &tool}},
		ToolChoice: anthropic.ToolChoiceParamOfTool(compactToolName),
		Thinking:   forcedToolThinking(),
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock("Older conversation to summarize:\n\n" + text)),
		},
	})
	// Health record at the SDK call only — later shape/parse problems are our
	// bugs, not provider health (ai_health.go). Skip when the caller canceled
	// (stop button mid-compaction): a deliberate teardown is not an AI result.
	if !errors.Is(ctx.Err(), context.Canceled) {
		recordAIResult(err)
	}
	if err != nil {
		return "", err
	}

	for _, block := range resp.Content {
		if variant, ok := block.AsAny().(anthropic.ToolUseBlock); ok && variant.Name == compactToolName {
			var in struct {
				Summary string `json:"summary"`
			}
			if err := json.Unmarshal(variant.Input, &in); err != nil {
				return "", fmt.Errorf("parse tool input: %w", err)
			}
			summary := strings.TrimSpace(in.Summary)
			if summary == "" {
				return "", fmt.Errorf("model returned empty summary")
			}
			// Our own output must never trip the per-message guard next turn.
			// Unreachable at MaxTokens 1024, but cheap to hold as an invariant.
			if utf8.RuneCountInString(summary) > planMaxMessageChars {
				summary = string([]rune(summary)[:planMaxMessageChars])
			}
			return summary, nil
		}
	}
	return "", fmt.Errorf("no %s tool call in response", compactToolName)
}

// compactPlanMessages summarizes all but the newest planCompactKeep messages
// (merging prevSummary) and returns the replacement wire history — the summary
// rendered as the first user message, then the kept tail — along with the new
// summary and how many incoming messages it folded away.
func compactPlanMessages(ctx context.Context, client anthropic.Client, prevSummary string, msgs []PlanChatMessage) ([]PlanChatMessage, string, int, error) {
	if len(msgs) <= planCompactKeep {
		return msgs, "", 0, fmt.Errorf("nothing to compact: %d messages", len(msgs))
	}
	through := len(msgs) - planCompactKeep
	summary, err := summarizePlanConversation(ctx, client, prevSummary, msgs[:through])
	if err != nil {
		return msgs, "", 0, err
	}
	newMsgs := append([]PlanChatMessage{summaryAsMessage(summary)}, msgs[through:]...)
	return newMsgs, summary, through, nil
}
