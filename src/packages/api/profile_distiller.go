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
		"Keep only durable facts about how this person travels (dietary needs, accommodation style, likes/dislikes, accessibility) — no one-off trip details, no sensitive information (health, religion, politics). " +
		"Only set budget, pace, interests, home_airport, work_style, fitness_routine, outdoor_intensity, companions, or baggage if the conversation clearly establishes them; omit any field you are unsure about. If nothing durable was learned, omit profile_notes too."
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
				"work_style":    map[string]any{"type": "string", "enum": []string{"digital_nomad", "workation", "leisure_only"}},
				"fitness_routine": map[string]any{
					"type": "string", "enum": []string{"gym", "running", "both", "none"},
					"description": "The training they keep while away. A routine, not a taste — a one-off class belongs in interests.",
				},
				"outdoor_intensity": map[string]any{
					"type": "string", "enum": []string{"easy", "moderate", "challenging"},
					"description": "How demanding they want active outings to be. Separate from pace.",
				},
				"companions": map[string]any{
					"type": "string", "enum": []string{"solo", "partner", "friends", "family_with_kids", "varies"},
					"description": "Who they usually travel with — not who was on this one trip.",
				},
				"baggage": map[string]any{
					"type": "string", "enum": []string{"personal_item", "carry_on", "checked"},
					"description": "The biggest bag they normally fly with. How this person packs in general, not what they took on this one trip.",
				},
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
		Budget           *string  `json:"budget"`
		Pace             *string  `json:"pace"`
		Interests        []string `json:"interests"`
		HomeAirport      *string  `json:"home_airport"`
		ProfileNotes     *string  `json:"profile_notes"`
		WorkStyle        *string  `json:"work_style"`
		FitnessRoutine   *string  `json:"fitness_routine"`
		OutdoorIntensity *string  `json:"outdoor_intensity"`
		Companions       *string  `json:"companions"`
		Baggage          *string  `json:"baggage"`
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

	// Distillation runs in the background with no caller to answer, so a value
	// the model got wrong is dropped — but it is logged rather than discarded
	// silently, because a model that keeps emitting e.g. "Boston" for an IATA
	// field is a prompt bug and nothing else would ever surface it.
	keep := func(v *string, err error) *string {
		if err != nil {
			log.Printf("profile distill: %v (field left unchanged)", err)
			return nil
		}
		return v
	}

	budget := keep(normalizeChoice(in.Budget, allowedBudgets, "budget"))
	pace := keep(normalizeChoice(in.Pace, allowedPaces, "pace"))
	workStyle := keep(normalizeChoice(in.WorkStyle, allowedWorkStyles, "work_style"))
	fitnessRoutine := keep(normalizeChoice(in.FitnessRoutine, allowedFitnessRoutines, "fitness_routine"))
	outdoorIntensity := keep(normalizeChoice(in.OutdoorIntensity, allowedOutdoorIntensities, "outdoor_intensity"))
	companions := keep(normalizeChoice(in.Companions, allowedCompanions, "companions"))
	baggage := keep(normalizeChoice(in.Baggage, allowedBaggageTiers, "baggage"))

	// Clear flag dropped on purpose: distillation can no more empty a home
	// airport than it can wipe notes below.
	homeAirport, _, airportErr := normalizeAirportCode(in.HomeAirport)
	if airportErr != nil {
		log.Printf("profile distill: %v (field left unchanged)", airportErr)
		homeAirport = nil
	}
	var interestsArg interface{}
	if in.Interests != nil {
		interestsArg = normalizeInterests(in.Interests)
	}
	notes := normalizeNotes(in.ProfileNotes)
	if notes != nil && *notes == "" {
		// Like the live tool, distillation can never wipe existing notes.
		notes = nil
	}
	if budget == nil && pace == nil && homeAirport == nil && interestsArg == nil && notes == nil && workStyle == nil &&
		fitnessRoutine == nil && outdoorIntensity == nil && companions == nil && baggage == nil {
		return
	}
	if _, err := queries.UpsertPreferences(ctx, store.UpsertPreferencesParams{
		UserID: uid, Budget: budget, Pace: pace, Interests: interestsArg, HomeAirport: homeAirport, ProfileNotes: notes, WorkStyle: workStyle,
		FitnessRoutine: fitnessRoutine, OutdoorIntensity: outdoorIntensity, Companions: companions, Baggage: baggage,
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
