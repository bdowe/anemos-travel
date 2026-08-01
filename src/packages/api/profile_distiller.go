package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"
	"time"

	anthropic "github.com/anthropics/anthropic-sdk-go"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"travel-route-planner/store"
)

const (
	distillTimeout      = 60 * time.Second
	distillMaxMessages  = 40
	distillMaxChars     = 30000
	distillToolName     = "update_traveler_profile"
	distillSystemPrompt = "You distill what was learned about a traveler from a trip-planning conversation, so future trips are personalized. " +
		"Call update_traveler_profile once. Set profile_notes to the COMPLETE traveler profile: the current notes merged with anything new from the conversation, de-duplicated, as short bullet lines (max ~15, under 1800 characters). " +
		"Keep only durable facts about how this person travels (companions, dietary needs, accommodation style, likes/dislikes, accessibility) — no one-off trip details, no sensitive information (health, religion, politics). " +
		"Only set budget, pace, interests, or home_airport if the conversation clearly establishes them; omit any field you are unsure about. If nothing durable was learned, omit profile_notes too."
)

// distillTravelerProfile runs one non-streamed Claude call over the chat
// transcript and merges what it learned into the traveler's preferences. It is
// fired as a goroutine after a trip persists and never fails the caller: every
// error is logged and swallowed. Pass context.Background() — the request
// context is canceled when the handler returns.
func distillTravelerProfile(ctx context.Context, client anthropic.Client, uid uuid.UUID, transcript []PlanChatMessage) {
	ctx, cancel := context.WithTimeout(ctx, distillTimeout)
	defer cancel()

	if dbPool == nil {
		return
	}
	text := buildDistillationTranscript(transcript, distillMaxMessages, distillMaxChars)
	if text == "" {
		return
	}

	queries := store.New(dbPool)
	system := distillSystemPrompt
	current, err := queries.GetPreferences(ctx, uid)
	switch {
	case err == nil:
		if current.ProfileNotes != nil && strings.TrimSpace(*current.ProfileNotes) != "" {
			system += "\n\nCurrent notes:\n" + strings.TrimSpace(*current.ProfileNotes)
		} else {
			system += "\n\nCurrent notes: (none yet)"
		}
	case errors.Is(err, pgx.ErrNoRows):
		system += "\n\nCurrent notes: (none yet)"
	default:
		log.Printf("profile distill: load preferences: %v", err)
		return
	}

	tool := anthropic.ToolParam{
		Name:        distillToolName,
		Description: anthropic.String("Record the merged traveler profile learned from this conversation."),
		InputSchema: anthropic.ToolInputSchemaParam{
			Properties: map[string]any{
				"budget":        map[string]any{"type": "string", "enum": []string{"budget", "mid", "luxury"}},
				"pace":          map[string]any{"type": "string", "enum": []string{"relaxed", "balanced", "packed"}},
				"interests":     map[string]any{"type": "array", "items": map[string]any{"type": "string"}},
				"home_airport":  map[string]any{"type": "string", "description": "IATA code, e.g. BOS"},
				"profile_notes": map[string]any{"type": "string", "description": "The complete merged profile as short bullet lines"},
			},
		},
	}

	resp, err := client.Messages.New(ctx, anthropic.MessageNewParams{
		Model:      aiModel(),
		MaxTokens:  1024,
		System:     []anthropic.TextBlockParam{{Text: system}},
		Tools:      []anthropic.ToolUnionParam{{OfTool: &tool}},
		ToolChoice: anthropic.ToolChoiceParamOfTool(distillToolName),
		Thinking:   forcedToolThinking(),
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock("Planning conversation transcript:\n\n" + text)),
		},
	})
	// Health record (ai_health.go): this fire-and-forget path swallows errors
	// by design, so without it a billing/auth outage here would be invisible.
	recordAIResult(err)
	if err != nil {
		log.Printf("profile distill: model call: %v", err)
		return
	}

	var in struct {
		Budget       *string  `json:"budget"`
		Pace         *string  `json:"pace"`
		Interests    []string `json:"interests"`
		HomeAirport  *string  `json:"home_airport"`
		ProfileNotes *string  `json:"profile_notes"`
	}
	found := false
	for _, block := range resp.Content {
		if variant, ok := block.AsAny().(anthropic.ToolUseBlock); ok && variant.Name == distillToolName {
			if err := json.Unmarshal(variant.Input, &in); err != nil {
				log.Printf("profile distill: parse tool input: %v", err)
				return
			}
			found = true
			break
		}
	}
	if !found {
		return
	}

	budget, _ := normalizeChoice(in.Budget, allowedBudgets, "budget")
	pace, _ := normalizeChoice(in.Pace, allowedPaces, "pace")
	homeAirport, _ := normalizeAirportCode(in.HomeAirport)
	var interestsArg interface{}
	if in.Interests != nil {
		interestsArg = normalizeInterests(in.Interests)
	}
	notes := normalizeNotes(in.ProfileNotes)
	if notes != nil && *notes == "" {
		// Like the live tool, distillation can never wipe existing notes.
		notes = nil
	}
	if budget == nil && pace == nil && homeAirport == nil && interestsArg == nil && notes == nil {
		return
	}
	if _, err := queries.UpsertPreferences(ctx, store.UpsertPreferencesParams{
		UserID: uid, Budget: budget, Pace: pace, Interests: interestsArg, HomeAirport: homeAirport, ProfileNotes: notes,
	}); err != nil {
		log.Printf("profile distill: save preferences: %v", err)
	}
}

// buildDistillationTranscript flattens the chat's text turns into a single
// labeled transcript, keeping the most recent maxMsgs messages and trimming
// oldest-first to stay under maxChars.
func buildDistillationTranscript(msgs []PlanChatMessage, maxMsgs, maxChars int) string {
	if len(msgs) > maxMsgs {
		msgs = msgs[len(msgs)-maxMsgs:]
	}
	var lines []string
	for _, m := range msgs {
		content := strings.TrimSpace(m.Content)
		if content == "" {
			continue
		}
		role := "Traveler"
		if m.Role != "user" {
			role = "Agent"
		}
		lines = append(lines, fmt.Sprintf("%s: %s", role, content))
	}
	for len(lines) > 0 && transcriptLen(lines) > maxChars {
		lines = lines[1:]
	}
	return strings.Join(lines, "\n\n")
}

func transcriptLen(lines []string) int {
	n := 0
	for _, l := range lines {
		n += len(l) + 2
	}
	return n
}
