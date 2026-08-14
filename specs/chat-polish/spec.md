# Spec: Chat Polish

> **WHAT & WHY only.** See `plan.md` for the technical approach.

## Context

The plan-chat surface (the "Plan your trip" tab and the trip-refine panel)
works but feels rough in daily use. Five user-visible defects surfaced from
screenshots and feedback: no feedback appears for a beat after sending a
message; assistant text sometimes runs two sentences together with no gap
after the agent looks something up; a finished trip offers two competing
buttons where one belongs; chat bubbles stretch unreadably wide on desktop
windows; and one chat label never got translated. This bundle fixes all five
without changing any server behavior.

## User Stories

- As a **traveler**, I want to see immediately that the assistant is working
  the moment I send a message, so the app never feels stalled.
- As a **traveler**, I want the assistant's reply to read as normal paragraphs
  even when it paused mid-reply to look something up.
- As a **signed-in traveler** whose trip was just created, I want one clear
  "View trip" action rather than choosing between two buttons.
- As a **desktop user**, I want chat text at a readable line length.
- As a **Spanish-language traveler**, I want every chat label in my language.

## Acceptance Criteria

- [ ] The instant a message is sent, an animated typing indicator appears in
  the conversation; it disappears as soon as the reply starts streaming (or a
  tool/summarizing chip takes over) and returns during silent gaps after a
  tool finishes.
- [ ] Assistant text that resumes after a tool call renders as a new
  paragraph, never glued to the previous sentence — including when the same
  conversation is reopened later from "Continue where you left off".
- [ ] When a trip was saved, the itinerary-ready banner shows a single
  "View trip" button. Anonymous sessions (no saved trip) still get their
  "Load into Planner" button.
- [ ] On wide windows, chat bubbles cap at a readable width (~720px); on
  phones they keep spanning ~78% of the screen.
- [ ] The result chips' "View in trip" label is localized (English and
  Spanish).

## API Surface

No new endpoints or events. One behavioral refinement to the existing
`POST /api/v1/plan` stream: when assistant text resumes after a tool call,
the streamed text now carries a paragraph separator at the boundary (unless a
newline is already there), and the persisted resumable transcript stores the
same separated text — so the live rendering, a later resume, and older
deployed clients all agree.

## Data Model

None.

## UI Behavior

- **Typing indicator:** an assistant-styled bubble with three animated dots,
  shown from the moment of send until the first streamed text, active-tool
  chip, or summarizing chip appears — and again between a tool finishing and
  the next text arriving. Works identically in the Agent tab and the trip
  refine panel.
- **Itinerary banner:** saved trip → one full-width "View trip" primary
  button. No saved trip → unchanged "Load into Planner" primary button.

## Edge Cases & Error States

- A turn that opens with a tool call (no text yet) must not gain a leading
  paragraph break.
- A model reply that already supplies its own newline at a tool boundary must
  not get a doubled blank line; a plain leading space does still get the
  paragraph break.
- A turn that errors mid-stream keeps the paragraph break in the committed
  partial reply.
- The typing indicator must never appear at the same time as an
  actively-streaming reply, a tool chip, or the summarizing chip. (Amended by
  `specs/chat-working-indicator`: the indicator MAY appear below a *stalled*
  streamed reply when the server has signaled `thinking` — the model's first
  token clears that state, so overlap with live streaming remains impossible.)

## Out of Scope

- Quick-reply suggestion chips (separate feature: `specs/chat-quick-replies`).
- Server-side changes of any kind.
- Dark mode; the app is light-only.
- The navigation-rail account avatar: investigated, renders as designed (a
  short-window-height vertical cut is a known separate follow-up).

## Open Questions

None.
