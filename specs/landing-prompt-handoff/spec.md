# Spec: Landing Prompt Handoff

> **WHAT & WHY only.** Sibling of `specs/landing-redesign/` (the page that
> produces the prompt).

## Context

The redesigned landing page's hero is a real prompt input, but a visitor is
signed out and the app has no signed-out chat surface. Without a handoff, the
sentence a visitor typed — the strongest intent signal the product ever gets —
dies at the sign-up form. This feature carries that sentence through sign-up
(including the SSO full-page navigation) and into the visitor's first agent
chat, prefilled in the composer in their own words.

## User Stories

- As a **first-time visitor**, I want **the trip I typed on the landing page
  waiting in the chat after I sign up** so that I never retype it.
- As a **returning traveler** who typed a prompt before tapping "I already
  have an account", I want it **waiting after sign-in** too.
- As **Brian**, I want the funnel instrumented (prompt submitted → consumed)
  so the landing redesign's effect is measurable.

## Acceptance Criteria

- [ ] Submitting the hero prompt (typed or chip-prefilled) or tapping a
      destination card stores the prompt and continues into sign-up.
- [ ] After email+password sign-up and the onboarding quiz (finish or skip),
      the app lands on the Plan tab with the composer prefilled with the
      exact submitted text. Nothing is auto-sent.
- [ ] The same holds through Google and Apple SSO, which reload the page.
- [ ] The same holds for sign-IN with an existing account.
- [ ] A prompt older than 30 minutes is never applied.
- [ ] A prompt is applied at most once — abandoning the quiz, signing out,
      or signing in again does not replay it.
- [ ] When the visitor arrived via a deep link (boot target), the prompt
      still lands in the composer but the deep link keeps the tab.
- [ ] `landing_prompt_submitted` (anonymous-capable) and
      `pending_prompt_consumed` (authed) are recorded with a `surface` of
      `hero` or `card`; the prompt text itself never rides analytics.
- [ ] Storage being unavailable degrades silently: sign-up proceeds, the
      prompt is simply absent (email path still works via the in-memory
      mirror; SSO path loses it).

## API Surface

No new endpoints. `POST /api/v1/events` accepts two new event types:
`landing_prompt_submitted` (also anonymously) and `pending_prompt_consumed`
(authed only), both with the existing `surface`/`kind` metadata keys.
`GET /api/v1/admin/metrics/timeseries` gains the `landing_prompt_submitted`
daily series.

## Data Model

- **Pending prompt** (device-local only): the trimmed prompt text (≤2000
  chars), the suggestion slug when a destination card produced it, and when
  it was saved. One slot, last-write-wins, single-use, 30-minute expiry.
  Never persisted server-side until the user sends it in chat themselves.

## UI Behavior

- **Consume moment:** the first time the session is signed-in AND onboarded
  (covers sign-up→quiz, SSO return, plain sign-in, and cold boot with a
  stored session). The Plan tab is preselected (unless a deep link chose a
  destination) and the Agent composer carries the text.
- **Prefill, not auto-send:** minutes pass between intent and arrival; the
  user reviews and sends. Auto-send would erupt unprompted on first arrival
  and waste the first turn on quiz-skippers with empty profiles.

## Edge Cases & Error States

- Two tabs consuming at once: worst case two prefilled composers (drafts are
  device-local; no duplicate sends, no model cost).
- A second landing submit overwrites the first (one slot).
- A different user signing in on the same device within 30 minutes receives
  the device-local prefill — device-scoped by design, text never left the
  machine.
- Composer already mounted when the consume fires: the draft write reaches
  the live composer (no silent-loss window).

## Out of Scope

- Anonymous chat.
- Seeding the onboarding quiz from the prompt (one home per fact: the
  composer).
- Auto-send (a one-line swap at the consume site if product ever wants it).

## Open Questions

None.
