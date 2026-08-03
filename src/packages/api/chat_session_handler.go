package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/mux"

	"travel-route-planner/store"
)

// Resumable plan conversations (specs/continue-where-you-left-off). A plan
// chat is persisted from its first authenticated turn so leaving mid-discussion
// never loses the conversation; it stops being listed ("graduates") once a
// trip with its chat_id exists — a read-time filter in the list query, never a
// flag a writer could race.

const (
	chatTitleMaxRunes   = 80
	chatPreviewMaxRunes = 140
)

type ChatSessionSummaryResponse struct {
	ChatID       string    `json:"chat_id"`
	Title        string    `json:"title"`
	Preview      string    `json:"preview"`
	MessageCount int       `json:"message_count"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}

type ChatSessionDetailResponse struct {
	ChatID    string            `json:"chat_id"`
	Title     string            `json:"title"`
	Summary   string            `json:"summary"`
	Messages  []PlanChatMessage `json:"messages"`
	UpdatedAt time.Time         `json:"updated_at"`
}

// truncateRunes shortens s to at most max runes, appending an ellipsis when it
// was cut (same shape as notesPreview in plan_handler.go).
func truncateRunes(s string, max int) string {
	r := []rune(strings.TrimSpace(s))
	if len(r) > max {
		return string(r[:max]) + "…"
	}
	return string(r)
}

// savePlanChatSession upserts the whole transcript for one plan conversation.
// Best-effort by design: a failure is logged and the turn proceeds — session
// persistence must never break the chat itself.
func savePlanChatSession(ctx context.Context, uid uuid.UUID, chatID, summary string, msgs []PlanChatMessage) {
	if dbPool == nil || len(msgs) == 0 {
		return
	}
	// Persist images as markers only: the transcript is upserted wholesale
	// twice per turn, so inlined base64 would rewrite megabytes to the JSONB
	// column every message. MediaType survives so a resumed client can render
	// an "image attached" placeholder; the empty Data round-trips as the
	// placeholder shape plan_handler.go skips at conversion time.
	persistable := append([]PlanChatMessage(nil), msgs...)
	for i, m := range persistable {
		if len(m.Images) == 0 {
			continue
		}
		stripped := make([]PlanImage, len(m.Images))
		for j, img := range m.Images {
			stripped[j] = PlanImage{MediaType: img.MediaType}
		}
		persistable[i].Images = stripped
	}
	payload, err := json.Marshal(persistable)
	if err != nil {
		log.Printf("failed to marshal chat session %s: %v", chatID, err)
		return
	}
	var title, preview string
	for _, m := range msgs {
		if m.Role == "user" {
			// Machine-built seed messages (near-me coordinates) carry a
			// human-friendly display label — title from that, never the raw text.
			src := m.Content
			if strings.TrimSpace(m.DisplayLabel) != "" {
				src = m.DisplayLabel
			}
			title = truncateRunes(src, chatTitleMaxRunes)
			break
		}
	}
	for i := len(msgs) - 1; i >= 0; i-- {
		if msgs[i].Role == "assistant" {
			preview = truncateRunes(msgs[i].Content, chatPreviewMaxRunes)
			break
		}
	}
	err = store.New(dbPool).UpsertPlanChatSession(ctx, store.UpsertPlanChatSessionParams{
		UserID:       uid,
		ChatID:       chatID,
		Title:        title,
		Preview:      preview,
		Summary:      summary,
		Messages:     payload,
		MessageCount: int32(len(msgs)),
	})
	if err != nil {
		log.Printf("failed to persist chat session %s: %v", chatID, err)
	}
}

// --- handlers (all behind authMiddleware) ---

func listChatSessionsHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	q := store.New(dbPool)
	_ = q.DeleteStalePlanChatSessions(r.Context()) // opportunistic prune
	rows, err := q.ListResumablePlanChatSessions(r.Context(), user.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load conversations")
		return
	}
	out := make([]ChatSessionSummaryResponse, 0, len(rows))
	for _, s := range rows {
		out = append(out, ChatSessionSummaryResponse{
			ChatID:       s.ChatID,
			Title:        s.Title,
			Preview:      s.Preview,
			MessageCount: int(s.MessageCount),
			CreatedAt:    s.CreatedAt,
			UpdatedAt:    s.UpdatedAt,
		})
	}
	writeJSON(w, http.StatusOK, out)
}

func getChatSessionHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	chatID := mux.Vars(r)["chatId"]
	row, err := store.New(dbPool).GetPlanChatSessionByChatID(r.Context(), store.GetPlanChatSessionByChatIDParams{
		UserID: user.ID, ChatID: chatID,
	})
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "conversation not found")
		return
	}
	var msgs []PlanChatMessage
	if err := json.Unmarshal(row.Messages, &msgs); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load conversation")
		return
	}
	writeJSON(w, http.StatusOK, ChatSessionDetailResponse{
		ChatID:    row.ChatID,
		Title:     row.Title,
		Summary:   row.Summary,
		Messages:  msgs,
		UpdatedAt: row.UpdatedAt,
	})
}

func deleteChatSessionHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	chatID := mux.Vars(r)["chatId"]
	n, err := store.New(dbPool).DeletePlanChatSession(r.Context(), store.DeletePlanChatSessionParams{
		UserID: user.ID, ChatID: chatID,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not dismiss conversation")
		return
	}
	if n == 0 {
		writeJSONError(w, http.StatusNotFound, "conversation not found")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
