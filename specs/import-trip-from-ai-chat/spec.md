# Import a trip from an external AI chat

## Context

Travelers increasingly plan trips in ChatGPT or Claude — long, rich conversations
on their own subscriptions. Today none of that work can enter Golden Tempo except
by re-planning from scratch in the in-app agent, which costs us $1–5 of Anthropic
spend per session (docs/business-model.md). This feature lets a user paste the
conversation (or its final summary) into Golden Tempo, where **one** cheap
forced-tool extraction call turns it into a real, editable trip. The user's own
AI subscription paid for the thinking; we pay cents for the structuring.

This is Track 1 of the external-AI plan. Its core pipeline
(extract → resolve coordinates → persist) is deliberately reusable by Track 2
(the ChatGPT/claude.ai MCP connector, specs/mcp-connector, future).

## User Stories

- As a traveler who planned a trip in ChatGPT, I paste the conversation into
  Golden Tempo and get a full trip — days, cities, places on the map — that I
  can edit like any other trip.
- As a traveler about to start planning in ChatGPT, I copy a "planning prompt"
  from Golden Tempo first, so my ChatGPT conversation ends with a summary the
  importer parses reliably.
- As the same traveler, when some pasted place can't be found on the map, I see
  which ones need attention instead of silently losing them.

## Acceptance Criteria

- [ ] A signed-in user can paste text at an "Import from AI chat" screen and get
      a trip that appears in My Trips, opens in the trip detail UI, and renders
      on the map with day/city grouping.
- [ ] Works with both a structured "TRIP SUMMARY" (from the copy-prompt flow)
      and a messy full transcript.
- [ ] Every place is resolved against Google Places; unresolved places with a
      plausible model-supplied coordinate are kept and flagged as approximate;
      places with no usable coordinate are dropped and named in a warning.
- [ ] The imported trip carries a fresh chat lineage (`trips.chat_id`), so
      "refine in chat" works on it immediately and nothing appears in the
      resumable-chats list.
- [ ] Anonymous users cannot import (401); the entry point is only shown signed in.
- [ ] Extraction failures return a friendly error and never a 500; the pasted
      text is preserved client-side for retry.
- [ ] Analytics: `trip_created` (source=import) and `trip_imported`
      (item_count/resolved/approximate/dropped) events are recorded.

## API Surface

### POST /api/v1/trips/import  (auth required, strict rate tier)

Purpose: turn pasted AI-chat text into a persisted trip in one call.

Request: `{"text": "<pasted conversation or summary>", "source": "chatgpt|claude|gemini|other"}`
(`source` optional, analytics only).

Response `201`: `{"trip_id": "<uuid>", "title": "...", "item_count": N, "warnings": ["..."]}`
Warnings are localized, user-displayable strings (approximate/dropped places,
degraded place verification).

Errors:
- `400` empty/invalid body
- `401` unauthenticated
- `422` no trip found in the text; or per-user trip cap reached (checked
  before any model/Places spend)
- `429` per-IP rate limit (own bucket, 5/min) or per-user daily import cap
  (`FREE_IMPORTS_PER_DAY`, default 10) — the daily-cap message is localized
- `502` extraction failed (provider detail logged server-side only)
- `503` place lookups failing (Google outage/quota) with nothing importable —
  retryable, localized message; also missing `ANTHROPIC_API_KEY`
- `413` body over 2 MiB

## Data Model

No schema changes. Writes `trips` + `itinerary_items` through the existing
`persistTrip` primitive with a freshly minted `chat-<token>` chat id. No
`plan_chat_sessions` row is written (refine-in-chat creates one on first use).

## UI Behavior

- Surface: "Import from AI chat" icon action on the Trips list app bar, plus a
  button on the trips-list empty state; also a labeled button on the Agent
  chat's empty state and a white text-button line under the Home new-user
  hero's suggestion chips (buttons, not chips — neighboring chips put words
  into the chat, import navigates). Every entry funnels through
  `openImportOnTripsTab`: it switches to the Trips tab and pushes `/import`,
  so the post-import trip detail lands on the stack-keeping Trips tab.
- Screen: explainer, "Copy planning prompt" button, large paste field, Import
  button. During import: indeterminate progress with staged copy (extraction
  takes 5–20 s). Success: navigate (replace) to the new trip's detail screen;
  if warnings exist, show them in a dismissible notice. Failure: inline error,
  paste text preserved, retry available.
- All copy in en + es.

## Edge Cases & Error States

- Anthropic down / key missing → 502 / 503, friendly message, retry works.
- Google Places key missing (degraded mode) → import still succeeds with
  model-approximate coordinates + one aggregate "verification unavailable"
  warning.
- Pasted text > 60k chars → server keeps head (10k) + tail (50k) around a
  truncation marker; start (destination/dates) and end (final itinerary) of a
  conversation both survive.
- Google Places outage/quota failure with the key configured → affected places
  keep model-approximate coordinates (or drop) under one aggregate
  "verification unavailable" warning — never per-place "couldn't be located"
  blame; if nothing survives, a retryable 503, not a 422.
- More than 80 extracted places → capped with a visible "only the first 80
  were imported — N more were left out" warning (and an `omitted` analytics
  count); never a silent cut.
- Text with no recognizable trip (recipes, homework…) → 422, no trip created.
- Trip cap reached → 422 with the cap message from persistTrip.
- Duplicate import of the same text → a second, independent trip (new lineage);
  no dedup in v1.

## Out of Scope

- The MCP connector / OAuth account linking (Track 2, specs/mcp-connector).
- Extracting accommodations, transport segments, or booking info.
- Images in pasted content; file upload; URL import.
- Editing/preview of extracted items before the trip is created.

## Open Questions

None — decisions (model choice, coordinate policy, chat_id semantics) are
recorded in plan.md.
