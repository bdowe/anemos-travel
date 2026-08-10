package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
	"unicode/utf8"

	anthropic "github.com/anthropics/anthropic-sdk-go"
	"github.com/google/uuid"

	"travel-route-planner/store"
)

// planMaxIterations bounds the agent tool loop. A rich session (local recs +
// several place searches + flights/events/stays + one create_itinerary) runs
// 8–11 iterations; parallel tool calls share an iteration. Hitting the cap
// ends the stream gracefully instead of letting a pathological loop burn cost.
const planMaxIterations = 15

// planModelCallTimeout bounds a single streaming model call. The handler's own
// context is r.Context() (no server WriteTimeout, since SSE needs unlimited),
// so without this a hung/slow upstream Anthropic socket would stall the agent
// loop — and the client's SSE stream — indefinitely. Each call gets its own
// deadline; exceeding it surfaces as a friendly SSE error, not a hang.
const planModelCallTimeout = 120 * time.Second

// planMaxDuration is the overall wall-clock ceiling for a single /plan request.
// The server runs with WriteTimeout:0 so SSE can stream unbounded, and
// planModelCallTimeout only bounds one model call — so without this a stuck
// stream (client gone, agent loop wedged) could pin its goroutine and its
// concurrency slot indefinitely. Deriving the handler context from this closes
// the request after the ceiling and frees the slot. Generous: a rich multi-tool
// session with compaction stays well under it.
const planMaxDuration = 10 * time.Minute

// planMaxMessages / planMaxMessageChars bound the resent conversation history.
// Every agent-loop iteration (up to planMaxIterations) re-pays input tokens on
// the full history, so these bounds are a hard cost lever. The working limit
// is compaction (plan_compactor.go): histories reaching planCompactThreshold
// are summarized down before the turn runs, and an updated client keeps its
// wire history small by resending the summary instead of the folded messages.
// planMaxMessages is only the backstop above that — old clients that ignore
// the compaction events get re-compacted server-side every turn until this
// cap, so hitting it means a runaway or abusive client. Violations return a
// friendly SSE `error` event, not a 500.
const (
	planMaxMessages     = 60
	planMaxMessageChars = 20000
	// planMaxDisplayLabelRunes bounds the display-label metadata persisted in
	// transcripts. Labels are chip-sized UI strings; anything longer is
	// truncated (not rejected — best-effort metadata) to keep a hostile client
	// from bloating the JSONB column.
	planMaxDisplayLabelRunes = 200
)

// Image attachment caps. Per-image tracks Anthropic's 5 MB decoded limit
// (base64 is ~4/3 of that); the per-message/per-request counts bound token
// cost — like message text, every attached image is resent with the history
// on each agent-loop iteration. The 20 MiB /plan body lane (middleware.go) is
// the effective aggregate byte bound; these caps exist to fail single-message
// abuse and Anthropic-side rejections early with a friendly SSE error.
const (
	planMaxImagesPerMessage = 4
	planMaxImagesPerRequest = 12
	planMaxImageBase64Len   = 6_800_000
)

// planImageMediaTypes is the allowlist Anthropic accepts for image blocks.
var planImageMediaTypes = map[string]bool{
	"image/jpeg": true,
	"image/png":  true,
	"image/gif":  true,
	"image/webp": true,
}

type PlanRequest struct {
	Messages []PlanChatMessage `json:"messages"`
	// Summary is the compacted context from earlier turns, previously handed to
	// the client via the `compacted` SSE event; it stands in for the messages it
	// folded away and precedes Messages as established context.
	Summary string `json:"summary"`
	ChatID  string `json:"chat_id"`
	// TripID binds the session to an existing saved trip: the agent then refines
	// that trip in place (update_itinerary_section) and can never create a new
	// trip version. Requires an authenticated owner.
	TripID string `json:"trip_id"`
}

type PlanChatMessage struct {
	Role    string      `json:"role"`
	Content string      `json:"content"`
	Images  []PlanImage `json:"images,omitempty"`
	// DisplayLabel is the client's compact stand-in for machine-built seed
	// messages (e.g. the near-me chip's coordinate text). Metadata only: it
	// titles the persisted chat session and round-trips through transcripts so
	// resumed chats re-render the chip, but it is never sent to the model.
	DisplayLabel string `json:"display_label,omitempty"`
}

// PlanImage is one image attached to a user message. Persisted transcripts
// keep MediaType but blank Data (savePlanChatSession), so a resumed client can
// render an "image attached" placeholder without megabytes of base64 living in
// the JSONB transcript; empty-Data images are skipped when building the model
// request.
type PlanImage struct {
	MediaType string `json:"media_type"`
	Data      string `json:"data"` // base64, no data: URI prefix
}

func sendSSE(w http.ResponseWriter, eventType string, data any) {
	payload, _ := json.Marshal(map[string]any{"type": eventType, "data": data})
	fmt.Fprintf(w, "data: %s\n\n", payload)
	w.(http.Flusher).Flush()
}

func planHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	// Tell nginx to never buffer this response, independent of location
	// config — belt and braces with the gateway's dedicated /plan lane.
	w.Header().Set("X-Accel-Buffering", "no")

	if _, ok := w.(http.Flusher); !ok {
		http.Error(w, "streaming not supported", http.StatusInternalServerError)
		return
	}
	// Priming SSE comment, flushed before any body parsing or DB work:
	// commits nginx/Cloudflare to streaming mode and gives the browser
	// instant TTFB. The Dart client only parses `data: ` lines, so a
	// comment frame is invisible to it.
	fmt.Fprint(w, ": stream-open\n\n")
	w.(http.Flusher).Flush()

	// Overall wall-clock ceiling on the whole request (see planMaxDuration): a
	// stuck stream eventually closes and frees its goroutine + concurrency slot.
	ctx, cancel := context.WithTimeout(r.Context(), planMaxDuration)
	defer cancel()
	r = r.WithContext(ctx)

	var req PlanRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		sendSSE(w, "error", map[string]string{"message": "invalid request body"})
		return
	}

	// Cap the conversation before any model call: the whole history is resent
	// on every agent-loop iteration, so these bounds are a hard cost lever.
	if len(req.Messages) > planMaxMessages {
		sendSSE(w, "error", map[string]string{"message": "This conversation is too long to continue. Please start a new chat to keep planning."})
		return
	}
	totalImages := 0
	for i, m := range req.Messages {
		if utf8.RuneCountInString(m.Content) > planMaxMessageChars {
			sendSSE(w, "error", map[string]string{"message": "One of the messages is too long for the planner. Please shorten it and try again."})
			return
		}
		if utf8.RuneCountInString(m.DisplayLabel) > planMaxDisplayLabelRunes {
			req.Messages[i].DisplayLabel = truncateRunes(m.DisplayLabel, planMaxDisplayLabelRunes)
		}
		if len(m.Images) > 0 && m.Role != "user" {
			sendSSE(w, "error", map[string]string{"message": "Images can only be attached to your own messages."})
			return
		}
		if len(m.Images) > planMaxImagesPerMessage {
			sendSSE(w, "error", map[string]string{"message": "A message can include at most 4 images. Please remove some and try again."})
			return
		}
		totalImages += len(m.Images)
		if totalImages > planMaxImagesPerRequest {
			sendSSE(w, "error", map[string]string{"message": "This conversation has too many images to continue. Please start a new chat to keep planning."})
			return
		}
		for _, img := range m.Images {
			// Empty Data is the stripped placeholder shape from a resumed
			// transcript — valid on the wire, skipped at conversion time.
			if img.Data != "" && !planImageMediaTypes[img.MediaType] {
				sendSSE(w, "error", map[string]string{"message": "That image format isn't supported. Please use a JPEG, PNG, GIF, or WebP image."})
				return
			}
			if len(img.Data) > planMaxImageBase64Len {
				sendSSE(w, "error", map[string]string{"message": "One of the images is too large. Please attach images under 5 MB."})
				return
			}
		}
	}
	if utf8.RuneCountInString(req.Summary) > planMaxMessageChars {
		sendSSE(w, "error", map[string]string{"message": "This conversation is too long to continue. Please start a new chat to keep planning."})
		return
	}

	// Resolve the caller once: anonymous sessions get no personalization and no
	// preference-writing tool; signed-in sessions get both.
	uid, authed, uerr := userIDFromRequest(r)
	if uerr != nil {
		// A token was presented but the DB was unreachable — don't silently
		// downgrade to anonymous (losing personalization + persistence). Ask
		// the client to retry rather than proceeding half-authenticated.
		sendSSE(w, "error", map[string]string{"message": "The service is temporarily unavailable. Please try again in a moment."})
		return
	}

	// Anonymous /plan daily cap (abuse_caps.go): the money fix. Signed-in
	// callers are exempt and uncounted (their measure-only free cap in
	// free_cap.go is unchanged); anonymous callers get anonPlanPerDay() free AI
	// planning runs per IP per UTC day, then a friendly SSE error — never a 500.
	if !anonPlanAllowed(authed, clientIP(r), time.Now()) {
		safeGo("recordAnonPlanCap", func() {
			recordEventOpt(nil, "anon_plan_cap_hit", nil, map[string]any{"per_day": anonPlanPerDay()})
		})
		sendSSE(w, "error", map[string]string{"message": "You've reached today's free planning limit. Sign in to keep planning, or check back tomorrow."})
		return
	}

	apiKey := os.Getenv("ANTHROPIC_API_KEY")
	if apiKey == "" {
		sendSSE(w, "error", map[string]string{"message": "ANTHROPIC_API_KEY not configured"})
		return
	}

	client := newAnthropicClient(apiKey)

	// Snapshot the wire history as the client sent it, BEFORE the compaction
	// block below rewrites req.Messages (or prepends the summary-as-message).
	// Session persistence must store what a live client would resend — never
	// the prepended summary message, which would duplicate context on resume.
	rawMessages, rawSummary := req.Messages, req.Summary

	// Compaction must rewrite req.Messages BEFORE the session below captures
	// req by value (the profile distiller reads session.req.Messages). On
	// threshold, fold the older messages into a summary and hand it back to
	// the client (`compacted`), which resends it as req.Summary instead of the
	// folded messages — so each stretch of history is summarized once. A
	// summarizer failure is never surfaced: the turn proceeds on the full
	// (≤ planMaxMessages) history and compaction retries next turn.
	var planCompacted, planCompactFailed bool
	if len(req.Messages) >= planCompactThreshold {
		sendSSE(w, "compacting", map[string]string{})
		cctx, cancel := context.WithTimeout(ctx, compactTimeout)
		newMsgs, summary, through, err := compactPlanMessages(cctx, client, req.Summary, req.Messages)
		cancel()
		if err != nil {
			log.Printf("plan compact: %v", err)
			planCompactFailed = true
			if strings.TrimSpace(req.Summary) != "" {
				req.Messages = append([]PlanChatMessage{summaryAsMessage(req.Summary)}, req.Messages...)
			}
		} else {
			req.Messages = newMsgs
			req.Summary = summary
			planCompacted = true
			sendSSE(w, "compacted", map[string]any{"summary": summary, "through_index": through})
		}
	} else if strings.TrimSpace(req.Summary) != "" {
		req.Messages = append([]PlanChatMessage{summaryAsMessage(req.Summary)}, req.Messages...)
	}

	// session carries the per-request state the tool dispatchers need
	// (plan_tool_registry.go) and the outcomes read back below: the persisted
	// or refined trip id, and whether the profile distiller already fired.
	session := &planSession{
		ctx:    ctx,
		w:      w,
		req:    req,
		client: client,
		authed: authed,
		uid:    uid,
	}

	// Session-level instrumentation for every caller — anonymous sessions
	// carry a null user id, so total AI spend and the authed/anonymous split
	// are both measurable. Completion carries token usage, tool calls, cache
	// hits and cap state. Deferred so it records however the stream ends.
	var planTokensIn, planTokensOut int64
	var planCacheRead, planCacheWrite int64
	var planToolCalls, planIterations int
	var planCapHit bool
	var planUID *uuid.UUID
	if authed {
		planUID = &uid
	}
	// Also runs the free-cap plan_runs crossing check (free_cap.go) — one
	// count query, entirely off the SSE hot path, skipped when unauthed or
	// degraded.
	safeGo("recordPlanSessionStart", func() { recordPlanSessionStart(planUID, authed) })
	defer func() {
		recordEventOpt(planUID, "plan_session_completed", session.tripID, map[string]any{
			"authenticated":         authed,
			"input_tokens":          planTokensIn,
			"output_tokens":         planTokensOut,
			"tool_calls":            planToolCalls,
			"iterations":            planIterations,
			"max_iterations_hit":    planCapHit,
			"cache_read_tokens":     planCacheRead,
			"cache_creation_tokens": planCacheWrite,
			"compacted":             planCompacted,
			"compaction_failed":     planCompactFailed,
		})
	}()

	// A trip-bound session must verifiably be editable by the caller (owner or
	// editor collaborator) before anything streams; failing closed here
	// guarantees a refine panel can never fall back to the version-creating
	// create_itinerary flow. Collaborator refines patch the owner's trip row
	// in place — the lineage never forks.
	var boundTripID *uuid.UUID
	var boundTripTravelMode *string
	if strings.TrimSpace(req.TripID) != "" {
		tid, err := uuid.Parse(req.TripID)
		if err != nil || !authed {
			sendSSE(w, "error", map[string]string{"message": "sign in to refine this trip"})
			return
		}
		boundTrip, err := store.New(dbPool).GetEditableTripByID(r.Context(), store.GetEditableTripByIDParams{ID: tid, UserID: uid})
		if err != nil {
			sendSSE(w, "error", map[string]string{"message": "trip not found"})
			return
		}
		boundTripID = &tid
		session.boundTripOwnerID = boundTrip.UserID
		boundTripTravelMode = boundTrip.TravelMode
	}
	session.boundTripID = boundTripID

	// Persist the conversation from its very first turn so leaving
	// mid-discussion never loses it (specs/continue-where-you-left-off).
	// Two best-effort writes: an async one started now (off the SSE hot
	// path), so the user's message survives even if the stream dies
	// immediately, and a deferred one — ordered strictly after it — that
	// appends whatever assistant text streamed — the same text the client
	// commits, on both its success and error paths. When compaction ran this
	// turn, the compacted history + new summary are stored instead of the raw
	// snapshot, matching the client's post-`compacted` wire state. Trip-bound
	// sessions patch a saved trip in place — nothing to resume — and anonymous
	// or degraded sessions stay ephemeral, like anonymous trips.
	persistSession := authed && dbPool != nil &&
		strings.TrimSpace(req.ChatID) != "" && boundTripID == nil
	var turnText strings.Builder
	// Set when an iteration ended in tool calls with text already streamed:
	// the next text delta opens a new paragraph, in the streamed bytes and
	// the persisted transcript alike, so live, resumed, and stale-client
	// renderings all agree. The client keeps a mirror of this rule
	// (plan_provider.dart) that sees the emitted newline and doesn't double
	// it, and still covers itself against older servers.
	turnNeedsSeparator := false
	if persistSession {
		persistMsgs, persistSummary := rawMessages, rawSummary
		if planCompacted {
			// compactPlanMessages returns [summary-as-message, ...kept tail];
			// the client's post-`compacted` wire state is the tail alone, with
			// the summary carried separately — store it the same way.
			persistMsgs, persistSummary = req.Messages[1:], req.Summary
		}
		// The start-of-turn save runs off the hot path: a whole-transcript
		// JSONB upsert before the model call would delay time-to-first-token.
		// It gets its own background context — a canceled stream (client
		// abort, timeout) must not cancel this write, because the user's
		// message surviving a dead stream is the entire point of it.
		//
		// Ordering contract (what a consumer observes after the turn): the
		// deferred end-of-turn save below awaits startSaved before writing, so
		// the two upserts always land start → final and the stored row after
		// the handler returns is the final assistant-text-bearing transcript —
		// a slow start upsert can never overwrite it. startSaved closes even
		// if the save panics (the deferred close unwinds before safeGo's
		// recover), so the final save can never deadlock; its wait is bounded
		// by the start save's own 5 s timeout.
		startSaved := make(chan struct{})
		safeGo("savePlanChatSessionStart", func() {
			defer close(startSaved)
			sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			savePlanChatSession(sctx, uid, req.ChatID, persistSummary, persistMsgs)
		})
		defer func() {
			msgs := persistMsgs
			if t := turnText.String(); t != "" {
				msgs = append(append([]PlanChatMessage{}, persistMsgs...),
					PlanChatMessage{Role: "assistant", Content: t})
			}
			<-startSaved // start → final ordering; see contract above
			// The request context is gone once the handler returns.
			dctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			savePlanChatSession(dctx, uid, req.ChatID, persistSummary, msgs)
		}()
	}

	// The tool table (plan_tool_registry.go) is the single source of truth for
	// what the agent can do: the tools slice sent to the API is generated from
	// it in registry order (order-stable — the tools array is part of the
	// prompt-cache prefix that the system-prompt cache breakpoint covers), and
	// tool_use blocks dispatch through it below. Trip-bound sessions get the
	// in-place section tool instead of create_itinerary, so a refinement can
	// never spawn a new trip version; personalization tools are signed-in only.
	tools := planSessionTools(session)

	var messages []anthropic.MessageParam
	for _, m := range req.Messages {
		if m.Role == "user" {
			var blocks []anthropic.ContentBlockParamUnion
			for _, img := range m.Images {
				if img.Data == "" {
					continue // stripped placeholder from a resumed transcript
				}
				blocks = append(blocks, anthropic.NewImageBlockBase64(img.MediaType, img.Data))
			}
			// Image-only messages carry no text block. A resumed image-only
			// message whose pixels were stripped would otherwise be empty —
			// the API rejects both empty content arrays and empty text
			// blocks — so it gets a marker keeping the transcript coherent.
			text := m.Content
			if strings.TrimSpace(text) == "" && len(blocks) == 0 {
				text = "[attached an image that is no longer available]"
			}
			if strings.TrimSpace(text) != "" {
				blocks = append(blocks, anthropic.NewTextBlock(text))
			}
			messages = append(messages, anthropic.NewUserMessage(blocks...))
		} else {
			messages = append(messages, anthropic.NewAssistantMessage(anthropic.NewTextBlock(m.Content)))
		}
	}

	today := time.Now()
	basePrompt := "You are an expert travel agent. Today's date is " + today.Format("Monday, January 2, 2006") + " (" + today.Format("2006-01-02") + "). When a traveler gives a date without a year, assume the soonest upcoming occurrence on or after today — never a past year. Use dates in YYYY-MM-DD form when calling tools. Help users plan trips by searching for specific places and attractions. For each city, ALWAYS call search_local_recommendations FIRST — these are hand-curated picks from real locals, the legit info you can't get by googling. Prefer them over generic results, build the itinerary around them where they fit the traveler, and cite the local by name in your reply (e.g. 'Ana, a Lisbon chef, swears by…'). When a local pick becomes an itinerary place, carry its id into local_recommendation_id and its source_name into local_source_name. Then use search_places to fill gaps and find any other real locations with coordinates. Search for individual places (e.g. 'Louvre Museum Paris') rather than broad queries. Include a mix of activities/attractions and dining (restaurants), guided by the traveler's interests, budget, and pace. When you call create_itinerary, tag each location with category ('attraction' or 'restaurant'), a time_of_day ('morning', 'afternoon', or 'evening'), and a day (the 1-based trip day it falls on, increasing chronologically across the whole trip) so each day reads as a sensible schedule. Only include specific named places — never emit a location whose name is just the city itself as a placeholder; a day with no planned activities should simply have no locations for that day. When you have gathered enough places for the user's trip, call create_itinerary to finalize the plan; pass start_date (and end_date) whenever the traveler has given or agreed to travel dates, with day 1 being the start date. If the traveler changes the travel dates AFTER an itinerary has been saved this conversation, call set_trip_dates with the new start date — do not create a new itinerary just for a date change. set_trip_dates moves the WHOLE trip; when the traveler changes the dates of just ONE city on a multi-city trip — 'make LA Sep 24 to 27' — call set_leg_dates with that city and its new dates instead: it moves that city's days, stay, and connecting transport, extending the previous city's end to meet a later start. After a set_leg_dates call, relay every change the result reports — including a neighboring city's new end date — plus any remaining gap or overlap, and offer to fix those legs too. When its result notes the NEXT city was left with no nights or overlapped, offer to shift the remaining cities too; if the traveler agrees, call set_leg_dates once per affected city in order (earliest first) in the same turn. The first city's arrival is the trip's start date — to change when the trip begins, use set_trip_dates, not set_leg_dates. Pay attention to how the traveler is getting around: the moment they state or imply a travel mode — 'we're driving', 'road trip', 'we'll have a car', 'taking the train' — call set_travel_mode with it. On a car, train, or bus trip do NOT call search_flights or check_flight_connectivity and never suggest flights; plan a route with sensible daily driving or rail legs instead, and when a saved trip is open add legs with add_transport_segment in that mode. When the traveler will have a car — driving travel mode, or they mention renting or driving — and the plan includes a beach, call find_parking with the beach's name (and its coordinates if you already have them from a search) to surface free or cheap parking; present flagged spots as 'listed as free — verify locally', never as guaranteed. If the travel mode is ambiguous and it would change the plan, ask. Otherwise, you can use search_flights to find real flight options — ask for the traveler's departure city/airport and dates if you don't know them, and pick optimize_for from their budget (budget→cost, luxury→time, otherwise balanced); summarize the top 2-3 options in your own words and help them choose — do not tell the traveler to look at cards or lists in the chat. Before recommending a destination or stopover the traveler didn't ask for by name, call check_flight_connectivity with your 2-5 candidates (and the onward destination for stopovers) — prefer well-connected options, and if you still suggest a poorly connected one, say so plainly with the typical price and total travel time. Also run the check when the traveler proposes a stopover themselves, so you can warn them early if the route is long or expensive. Never present a stopover as convenient without having checked it. For travel between Greek islands, use suggest_ferries (ferries are the primary way to island-hop); note that in Greece search_events returns curated source links rather than ticketed listings. Use get_weather when weather changes the advice — packing, outdoor days, beach or ski viability, seasonal closures; for far-off dates it returns last year's weather as a seasonal guide, so present it as 'typically', never as a forecast. For signed-in travelers: when they reference a trip you've already planned together, call get_trip to read what's saved instead of asking them to repeat it; and when you give time-sensitive booking advice about a saved trip (book the ferry, reserve that restaurant), call add_booking_todo so it lands on their checklist instead of getting lost in chat; and when the plan changes so a checklist item is stale or wrong (different destination, moved dates, a booking that no longer applies), call update_booking_todo or remove_booking_todo to fix the checklist yourself — never tell the traveler to clean it up manually; get_trip shows each item's todo_id, and items marked 'auto' track the itinerary automatically and can't be edited. After any reply that ends by asking the traveler a question or offering a choice, call suggest_replies with 2-4 short tappable answers (each under 60 characters, phrased in the traveler's own voice, in the same language as your reply — e.g. 'Mid-range budget', 'More food, fewer museums'). Call it at most once per reply, only AFTER your question text is complete, and end your turn right after its result without repeating the options in text. Do NOT call suggest_replies in a turn where you call create_itinerary, update_itinerary_section, set_trip_dates, or set_leg_dates, and not when your reply asks the traveler nothing. When the traveler shares their current GPS coordinates or asks what's near them right now, call search_nearby with those exact coordinates instead of search_places, lead with the closest good options and rough distances, and once the result addresses reveal the city, also call search_local_recommendations for it. Never tell the traveler a change to their saved trip was made unless a tool call in THIS turn succeeded in making it — if the tool errored or wasn't available, say plainly what you couldn't do. Be conversational and helpful — ask clarifying questions if needed before searching. Format replies with light markdown — short paragraphs, **bold** for place names, hyphen lists — no headings or tables."

	// Fold the signed-in traveler's saved preferences into the system prompt.
	// The profile-keeping instruction applies even before any row exists, so
	// the first durable fact a traveler reveals gets captured.
	systemPrompt := basePrompt
	if authed {
		if prefs, err := store.New(dbPool).GetPreferences(ctx, uid); err == nil {
			systemPrompt = personalizedSystemPrompt(basePrompt, &prefs)
		}
		systemPrompt += profileNotesInstruction
	}
	if boundTripID != nil {
		systemPrompt += "\n\nYou are refining an existing saved trip in place. The conversation's first message describes the current itinerary and which section the traveler wants to change. Apply changes by calling update_itinerary_section with the targeted scope and the COMPLETE updated list of places for that section — include unchanged places with their existing coordinates, city, day, time_of_day and category tags so they aren't lost. Use search_places to find real coordinates for any new place before adding it. Only change the section the traveler asked about unless they broaden the request. The traveler may also ask questions about the trip without wanting changes — answer those directly from the itinerary and your search tools; only call update_itinerary_section when they explicitly ask for a modification. If the traveler changes WHEN the trip happens — 'shift everything a week later', 'we actually start June 12' — call set_trip_dates with the new start date (and end date if the length changes): it moves the trip and every dated stay, transport leg, and booking to-do together. If only ONE city's dates change, call set_leg_dates for that city instead — it moves that leg, extends the previous city's end to meet a later start (and says so), and reports any remaining gap or overlap with the neighboring cities, all of which you should relay and offer to fix. If the result says a later city was squeezed to no nights or overlapped, offer to shift the remaining cities and, when the traveler agrees, call set_leg_dates for each in order (earliest first) in that same turn. A change to when the FIRST city begins is a change to the trip's start — use set_trip_dates. Never rebuild sections with update_itinerary_section just to change dates — its day numbers are positional (a city's LAST item day is its departure day, and the page derives each leg from the previous city's departure through its own last day), so recomputing day numbers will not produce the calendar dates you intend and can undo earlier date moves. To change WHEN anything happens, use set_trip_dates or set_leg_dates with calendar dates, and always verify the 'page now renders' ranges a tool result reports against what the traveler asked for before replying."
		if boundTripTravelMode != nil && *boundTripTravelMode != "" {
			systemPrompt += "\n\nThis trip's travel mode is " + *boundTripTravelMode + "; keep new transport suggestions in that mode."
		}
	}
	// Response language (specs/i18n-spanish). Appended ONLY for non-English
	// locales, so an English request's prompt is byte-for-byte what it was
	// before this feature existed — see TestSystemPromptEnglishUnchanged.
	//
	// This is deliberately NOT a save_preferences field: plan_tool_registry.go
	// is part of the prompt-cache prefix and must stay byte-stable, and the
	// agent must not be able to overwrite the traveler's language. Spanish
	// conversations simply get their own cache line, which caches normally
	// across turns because the locale is constant within a conversation.
	systemPrompt += responseLanguageInstruction(requestLocale(ctx))

	// prevCacheMarker tracks the conversation cache breakpoint set on the
	// newest tool-results message; it must be cleared before setting the next
	// one (the API allows at most 4 breakpoints per request).
	var prevCacheMarker *anthropic.CacheControlEphemeralParam

	for {
		planIterations++
		if planIterations > planMaxIterations {
			planCapHit = true
			sendSSE(w, "error", map[string]string{"message": "This planning session hit its step limit. Send another message to continue from where we left off."})
			return
		}

		params := anthropic.MessageNewParams{
			Model:     aiModel(),
			MaxTokens: 8192,
			System: []anthropic.TextBlockParam{
				{
					Text:         systemPrompt,
					CacheControl: anthropic.NewCacheControlEphemeralParam(),
				},
			},
			Tools:    tools,
			Messages: messages,
		}

		callCtx, cancelCall := context.WithTimeout(ctx, planModelCallTimeout)
		stream := client.Messages.NewStreaming(callCtx, params)
		resp := anthropic.Message{}

		for stream.Next() {
			event := stream.Current()
			resp.Accumulate(event)

			if ev, ok := event.AsAny().(anthropic.ContentBlockDeltaEvent); ok {
				if delta, ok := ev.Delta.AsAny().(anthropic.TextDelta); ok {
					text := delta.Text
					if text != "" && turnNeedsSeparator {
						// Skip only when a newline already sits on either
						// side of the boundary; a plain space still gets
						// the paragraph break.
						if !strings.HasPrefix(text, "\n") && !strings.HasSuffix(turnText.String(), "\n") {
							text = "\n\n" + text
						}
						turnNeedsSeparator = false
					}
					turnText.WriteString(text)
					sendSSE(w, "text_delta", map[string]string{"text": text})
				}
			}
		}
		streamErr := stream.Err()
		cancelCall() // the deadline only needs to cover the streaming call above
		// Client went away (stop button / closed tab): the model call was torn
		// down on purpose — not an AI failure. No health record, no ERROR log
		// (Sentry tee), no SSE to a dead socket. Canceled-only, on the request
		// ctx: planModelCallTimeout and planMaxDuration expiries surface as
		// DeadlineExceeded (here or on callCtx) and keep recording as before.
		if errors.Is(ctx.Err(), context.Canceled) {
			return
		}
		// Exactly one health record per model call (ai_health.go); nil records
		// a success, so the first good call after an outage flips recovery.
		aiClass, aiReason := recordAIResult(streamErr)
		if streamErr != nil {
			// Redact: the raw Anthropic/transport error can carry internal
			// detail and is unhelpful to the user. Log it server-side (tees to
			// Sentry via slog) and send a generic, friendly message — honest
			// about fatal (billing/auth) failures, which "try again in a
			// moment" would misrepresent.
			ctxLog(ctx).Error("plan: anthropic stream error",
				"error", streamErr, "class", string(aiClass), "reason", aiReason)
			msg := "The planner hit a problem reaching the AI service. Please try again in a moment."
			if aiClass == aiClassFatal {
				msg = "The AI planning service is temporarily unavailable. Please try again later."
			}
			sendSSE(w, "error", map[string]string{"message": msg})
			return
		}
		planTokensIn += resp.Usage.InputTokens
		planTokensOut += resp.Usage.OutputTokens
		planCacheRead += resp.Usage.CacheReadInputTokens
		planCacheWrite += resp.Usage.CacheCreationInputTokens

		// A max_tokens stop mid-tool-call means truncated tool input JSON —
		// previously this failed silently and produced an empty itinerary.
		// Surface it instead of continuing with garbage.
		if resp.StopReason == anthropic.StopReasonMaxTokens {
			sendSSE(w, "error", map[string]string{"message": "The response was cut off before it finished. Try asking for a shorter plan or fewer places at once."})
			return
		}
		if resp.StopReason != anthropic.StopReasonToolUse {
			break
		}
		if turnText.Len() > 0 {
			turnNeedsSeparator = true
		}

		messages = append(messages, resp.ToParam())
		var toolResults []anthropic.ContentBlockParamUnion

		for _, block := range resp.Content {
			variant, ok := block.AsAny().(anthropic.ToolUseBlock)
			if !ok {
				continue
			}
			sendSSE(w, "tool_call", map[string]string{"name": variant.Name})
			planToolCalls++

			entry := planToolByName[variant.Name]
			if entry == nil {
				// Matches the old switch's no-case fallthrough: an unknown tool
				// name gets no result block (the API only calls defined tools).
				continue
			}
			result, isErr := entry.run(session, variant.Input)
			if !entry.noResultEvent {
				sendSSE(w, "tool_result", map[string]string{"name": variant.Name})
			}
			toolResults = append(toolResults, anthropic.NewToolResultBlock(variant.ID, result, isErr))
		}

		messages = append(messages, anthropic.NewUserMessage(toolResults...))

		// Move the conversation cache breakpoint onto the newest tool-results
		// message so each iteration re-reads the growing history from cache
		// instead of paying full input cost for it. The system-prompt
		// breakpoint (above) covers tools + system; this one covers the turn
		// transcript.
		if prevCacheMarker != nil {
			*prevCacheMarker = anthropic.CacheControlEphemeralParam{}
			prevCacheMarker = nil
		}
		if blocks := messages[len(messages)-1].Content; len(blocks) > 0 {
			if cc := blocks[len(blocks)-1].GetCacheControl(); cc != nil {
				*cc = anthropic.NewCacheControlEphemeralParam()
				prevCacheMarker = cc
			}
		}

		select {
		case <-ctx.Done():
			return
		default:
		}
	}
}

// resolveIATA turns a city name or IATA code into an IATA code for flight
// search. A 3-letter alphabetic input is treated as a code; anything else is
// looked up via Duffel, preferring a city (metropolitan) code so the search
// spans all of a city's airports. Returns "" when nothing resolves.
func resolveIATA(ctx context.Context, s string) string {
	s = strings.TrimSpace(s)
	if len(s) == 3 && isAlpha(s) {
		return strings.ToUpper(s)
	}
	results, err := duffelService.SearchAirports(ctx, s)
	if err != nil || len(results) == 0 {
		return ""
	}
	for _, a := range results {
		if a.SubType == "city" && a.IataCode != "" {
			return a.IataCode
		}
	}
	return results[0].IataCode
}

func isAlpha(s string) bool {
	for _, r := range s {
		if !((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')) {
			return false
		}
	}
	return s != ""
}

// summarizeOffers builds a compact text summary of ranked offers for the model,
// so it can describe and compare them without re-sending the full payload (the
// UI already received it via the "flights" event, shown as a summary chip).
func summarizeOffers(origin, dest string, offers []FlightOffer) string {
	if len(offers) == 0 {
		return fmt.Sprintf("No flights found from %s to %s for those dates.", origin, dest)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "Found %d ranked flight options %s→%s (best first):\n", len(offers), origin, dest)
	for i, o := range offers {
		airline := "—"
		if len(o.Airlines) > 0 {
			airline = strings.Join(o.Airlines, "/")
		}
		stops := "nonstop"
		if o.Stops == 1 {
			stops = "1 stop"
		} else if o.Stops > 1 {
			stops = fmt.Sprintf("%d stops", o.Stops)
		}
		// On baggage-aware searches the model must talk in effective totals —
		// quoting the bare fare would recreate exactly the misleading price
		// the baggage tier exists to fix.
		bag := ""
		switch o.BaggageStatus {
		case baggageStatusIncluded:
			bag = " (bag included)"
		case baggageStatusPaid:
			bag = fmt.Sprintf(" (incl. %s %.0f bag fee)", o.Currency, o.BagFee)
		case baggageStatusUnknown:
			bag = " (bag NOT included; fee unknown — warn the traveler)"
		}
		fmt.Fprintf(&b, "%d. %s — %s %.0f%s, %s, %dh%02dm (score %.1f)\n",
			i+1, airline, o.Currency, scoringPrice(o), bag, stops, o.DurationMin/60, o.DurationMin%60, o.Score)
	}
	b.WriteString("Summarize the top 2-3 options in your own words and help the traveler choose; the full ranked list is saved with their trip.")
	return b.String()
}

// summarizeEvents renders the events returned for a city into a compact text
// block for the model (the events themselves are streamed to the UI, shown as
// a summary chip).
func summarizeEvents(city string, events []Event) string {
	if len(events) == 0 {
		return fmt.Sprintf("No events found in %s for those dates.", city)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "Found %d events in %s (soonest first):\n", len(events), city)
	for i, e := range events {
		when := e.StartDate
		if e.StartTime != "" {
			when += " " + e.StartTime
		}
		line := fmt.Sprintf("%d. %s — %s", i+1, e.Name, when)
		if e.Venue != "" {
			line += " @ " + e.Venue
		}
		if e.Category != "" {
			line += " (" + e.Category + ")"
		}
		b.WriteString(line + "\n")
	}
	b.WriteString("In your reply, highlight the events that fit the traveler's interests and dates; the full list is saved with their trip.")
	return b.String()
}

// profileNotesInstruction is the standing profile-keeping rule appended to every
// authenticated session's system prompt, whether or not notes exist yet.
const profileNotesInstruction = "\n\nWhen you learn something durable about this traveler — travel companions, dietary needs, accommodation style, accessibility needs, likes or dislikes — call save_preferences with profile_notes set to the COMPLETE updated profile: your current notes merged with the new fact, de-duplicated, as short bullet lines (max ~15). Never send only the new fact. Don't store one-off trip details or sensitive information (health, religion, politics) unless the traveler explicitly asks you to remember it."

// responseLanguageInstruction tells the agent which language to write in.
// Returns "" for English so the English prompt is unchanged; structured tool
// arguments are pinned to their canonical formats because the tool schemas and
// the database expect them regardless of the traveler's language. The trailing
// clause keeps the agent following a traveler who writes in a third language
// rather than fighting them.
func responseLanguageInstruction(locale string) string {
	if locale == defaultLocale {
		return ""
	}
	return "\n\nRespond in " + languageName(locale) + ": all prose, trip titles, day summaries and place descriptions. Keep structured tool arguments in their required formats — dates as YYYY-MM-DD, IATA airport codes, and enum values (time_of_day, category, budget, pace, mode) exactly as the tool schemas specify. If the traveler writes in another language, follow their language instead."
}

// personalizedSystemPrompt appends the traveler's saved preferences and
// AI-maintained profile notes to the base prompt, omitting any fields that are
// unset. Returns base unchanged when there is nothing to add.
func personalizedSystemPrompt(base string, p *store.TravelerPreference) string {
	if p == nil {
		return base
	}
	var parts []string
	if p.Budget != nil && *p.Budget != "" {
		parts = append(parts, "budget: "+*p.Budget)
	}
	if p.Pace != nil && *p.Pace != "" {
		parts = append(parts, "pace: "+*p.Pace)
	}
	if len(p.Interests) > 0 {
		parts = append(parts, "interests: "+strings.Join(p.Interests, ", "))
	}
	var homeNote string
	if p.HomeAirport != nil && *p.HomeAirport != "" {
		parts = append(parts, "home airport: "+*p.HomeAirport)
		homeNote = " When searching flights, default the origin to the traveler's home airport (" +
			*p.HomeAirport + ") and state the assumption (e.g. 'flying from " + *p.HomeAirport +
			"'); only use a different origin if the trip clearly starts elsewhere or they say so." +
			" Skip this flying default when the trip's travel mode is car, train, or bus — then the home airport only tells you roughly where home is."
	}
	out := base
	if len(parts) > 0 {
		out += "\n\nTraveler preferences — " + strings.Join(parts, "; ") +
			". Tailor your suggestions accordingly." + homeNote
	}
	if p.ProfileNotes != nil && strings.TrimSpace(*p.ProfileNotes) != "" {
		out += "\n\nTraveler profile notes (maintained by you):\n" + strings.TrimSpace(*p.ProfileNotes)
	}
	return out
}

// notesPreview returns a short excerpt of saved notes for the profile_updated
// SSE event; empty when no notes were part of the save.
func notesPreview(notes *string) string {
	if notes == nil {
		return ""
	}
	r := []rune(strings.TrimSpace(*notes))
	if len(r) > 80 {
		return string(r[:80]) + "…"
	}
	return string(r)
}
