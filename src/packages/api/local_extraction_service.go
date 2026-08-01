package main

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	anthropic "github.com/anthropics/anthropic-sdk-go"
)

// local_extraction_service.go turns raw research material (an interview
// transcript, notes, a voice-memo dump) into structured, attributable draft
// recommendations + an optional narrative guide. It reuses the forced-tool
// pattern from profile_distiller.go: one non-streamed Claude call with a single
// tool and ToolChoice pinned to it, then json.Unmarshal on the tool input.

const (
	extractTimeout      = 90 * time.Second
	extractMaxChars     = 40000
	extractToolName     = "draft_local_content"
	extractSystemPrompt = "You convert a local's raw notes/interview about a city into structured recommendations for travelers. " +
		"Call draft_local_content exactly once. " +
		"STRICT RULES: Use ONLY what is grounded in the provided text — never invent a place, tip, or quote. " +
		"Do NOT include coordinates or addresses; those are resolved later. " +
		"Each recommendation's `quote` must be a verbatim excerpt of the local's own words (or empty if there is no quotable line). " +
		"`tip` is the actionable takeaway in your words. " +
		"`search_hint` is the best short string to find the exact place on a map (place name + street/neighborhood if known). " +
		"`category` is 'restaurant' for places you eat/drink, otherwise 'attraction'. " +
		"Only produce a `guide` if the text genuinely reads as a connected narrative worth publishing as prose; otherwise omit it. " +
		"If the text contains no real recommendations, return an empty recommendations array."
)

// ExtractedRecommendation is one draft pin as the model proposes it — no
// coordinates yet (those come from the Google verify step in the ingest handler).
type ExtractedRecommendation struct {
	Name         string   `json:"name"`
	Category     string   `json:"category"`
	Neighborhood string   `json:"neighborhood"`
	Tip          string   `json:"tip"`
	Quote        string   `json:"quote"`
	Tags         []string `json:"tags"`
	SearchHint   string   `json:"search_hint"`
}

// ExtractedGuide is the optional narrative layer over the pins.
type ExtractedGuide struct {
	Title        string `json:"title"`
	Neighborhood string `json:"neighborhood"`
	Body         string `json:"body"`
}

type ExtractedContent struct {
	Recommendations []ExtractedRecommendation `json:"recommendations"`
	Guide           *ExtractedGuide           `json:"guide"`
}

// extractLocalContent runs the single forced-tool call and returns the parsed
// draft content. City is passed for grounding but the model is told to attribute
// nothing it can't see in the text.
func extractLocalContent(ctx context.Context, client anthropic.Client, city, rawText string) (ExtractedContent, error) {
	ctx, cancel := context.WithTimeout(ctx, extractTimeout)
	defer cancel()

	if len(rawText) > extractMaxChars {
		rawText = rawText[:extractMaxChars]
	}

	tool := anthropic.ToolParam{
		Name:        extractToolName,
		Description: anthropic.String("Record structured local recommendations (and an optional narrative guide) extracted from the raw text."),
		InputSchema: anthropic.ToolInputSchemaParam{
			Properties: map[string]any{
				"recommendations": map[string]any{
					"type": "array",
					"items": map[string]any{
						"type": "object",
						"properties": map[string]any{
							"name":         map[string]any{"type": "string", "description": "The place's name"},
							"category":     map[string]any{"type": "string", "enum": []string{"attraction", "restaurant"}},
							"neighborhood": map[string]any{"type": "string"},
							"tip":          map[string]any{"type": "string", "description": "Actionable takeaway"},
							"quote":        map[string]any{"type": "string", "description": "Verbatim excerpt of the local's words, or empty"},
							"tags":         map[string]any{"type": "array", "items": map[string]any{"type": "string"}},
							"search_hint":  map[string]any{"type": "string", "description": "Best string to locate the place on a map"},
						},
						"required": []string{"name", "category", "tip", "search_hint"},
					},
				},
				"guide": map[string]any{
					"type": "object",
					"properties": map[string]any{
						"title":        map[string]any{"type": "string"},
						"neighborhood": map[string]any{"type": "string"},
						"body":         map[string]any{"type": "string", "description": "Narrative prose in the local's voice"},
					},
				},
			},
			Required: []string{"recommendations"},
		},
	}

	resp, err := client.Messages.New(ctx, anthropic.MessageNewParams{
		Model:      aiModel(),
		MaxTokens:  4096,
		System:     []anthropic.TextBlockParam{{Text: extractSystemPrompt}},
		Tools:      []anthropic.ToolUnionParam{{OfTool: &tool}},
		ToolChoice: anthropic.ToolChoiceParamOfTool(extractToolName),
		Thinking:   forcedToolThinking(),
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock(
				fmt.Sprintf("City: %s\n\nRaw local material:\n\n%s", city, rawText))),
		},
	})
	// Health record at the SDK call only (ai_health.go).
	recordAIResult(err)
	if err != nil {
		return ExtractedContent{}, fmt.Errorf("extraction model call: %w", err)
	}

	for _, block := range resp.Content {
		if variant, ok := block.AsAny().(anthropic.ToolUseBlock); ok && variant.Name == extractToolName {
			var out ExtractedContent
			if err := json.Unmarshal(variant.Input, &out); err != nil {
				return ExtractedContent{}, fmt.Errorf("parse extraction: %w", err)
			}
			return out, nil
		}
	}
	return ExtractedContent{}, fmt.Errorf("model did not return %s", extractToolName)
}
