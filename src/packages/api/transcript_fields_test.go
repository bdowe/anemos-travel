package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// planTranscriptFields is the ONE derivation behind both transcript tables —
// plan_chat_sessions (savePlanChatSession) and trip_refine_sessions
// (saveTripRefineSession). docs/zen.md: a second implementation owes a parity
// contract, so the two savers consume this instead of each rolling their own,
// and this fixture pins what they both store.
//
// The DB-backed half of the contract — that a refine row and a plan-chat row
// hold byte-identical payloads for the same transcript — lives in
// TestTranscriptFieldsParityAcrossTables.

func TestPlanTranscriptFieldsStripsImageBytes(t *testing.T) {
	msgs := []PlanChatMessage{
		{Role: "user", Content: "what is this?", Images: []PlanImage{
			{MediaType: "image/png", Data: "AAAABBBBCCCC"},
			{MediaType: "image/jpeg", Data: "DDDDEEEE"},
		}},
		{Role: "assistant", Content: "A funicular."},
	}
	payload, _, _, err := planTranscriptFields(msgs)
	if err != nil {
		t.Fatalf("planTranscriptFields: %v", err)
	}
	if strings.Contains(string(payload), "AAAABBBBCCCC") || strings.Contains(string(payload), "DDDDEEEE") {
		t.Fatalf("base64 image bytes reached the JSONB payload: %s", payload)
	}
	var stored []PlanChatMessage
	if err := json.Unmarshal(payload, &stored); err != nil {
		t.Fatalf("payload unparseable: %v", err)
	}
	if len(stored[0].Images) != 2 {
		t.Fatalf("stored %d image markers, want 2 — the placeholder must survive", len(stored[0].Images))
	}
	for i, img := range stored[0].Images {
		if img.MediaType == "" || img.Data != "" {
			t.Fatalf("marker %d = %+v, want a media type and no data", i, img)
		}
	}
	// The caller's slice must not be mutated: plan_handler.go persists the same
	// messages it is about to send to the model.
	if msgs[0].Images[0].Data == "" {
		t.Fatal("planTranscriptFields mutated the caller's messages")
	}
}

func TestPlanTranscriptFieldsTitleAndPreview(t *testing.T) {
	cases := []struct {
		name        string
		msgs        []PlanChatMessage
		wantTitle   string
		wantPreview string
	}{
		{
			name: "title is the first user message, preview the last assistant one",
			msgs: []PlanChatMessage{
				{Role: "user", Content: "where should I go in May?"},
				{Role: "assistant", Content: "Portugal."},
				{Role: "user", Content: "and after?"},
				{Role: "assistant", Content: "Galicia."},
			},
			wantTitle:   "where should I go in May?",
			wantPreview: "Galicia.",
		},
		{
			name: "a machine-built seed titles from its display label, never its raw text",
			msgs: []PlanChatMessage{
				{Role: "user", Content: "I want to refine my saved trip … 37.9,23.7 …",
					DisplayLabel: "Refining Day 2 — Athens"},
				{Role: "assistant", Content: "What would you like to change?"},
			},
			wantTitle:   "Refining Day 2 — Athens",
			wantPreview: "What would you like to change?",
		},
		{
			name:        "an unanswered opening turn has no preview",
			msgs:        []PlanChatMessage{{Role: "user", Content: "hello"}},
			wantTitle:   "hello",
			wantPreview: "",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, title, preview, err := planTranscriptFields(tc.msgs)
			if err != nil {
				t.Fatalf("planTranscriptFields: %v", err)
			}
			if title != tc.wantTitle {
				t.Errorf("title = %q, want %q", title, tc.wantTitle)
			}
			if preview != tc.wantPreview {
				t.Errorf("preview = %q, want %q", preview, tc.wantPreview)
			}
		})
	}
}
