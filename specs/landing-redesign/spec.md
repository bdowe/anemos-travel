# Spec: Landing Page Redesign

> **WHAT & WHY only.** No tech choices, file names, libraries, or code.

## Context

The signed-out landing page undersells the product: one hero card with a
tagline, a single "AI Travel Agent" tile, and a footer. The product itself is
invisible — no way to try the planner, no sign of the real breadth (live
flights, hotel rates, events, budget, maps, local picks), and desktop is a
narrow centered column in empty space. Every relevant competitor (Tripadvisor,
Mindtrip, Layla, the AI-product heroes) leads with the product: a real prompt
box, example prompts, and destination inspiration. The redesign turns the
landing page into a full marketing page whose hero IS the product's first
interaction: the visitor types the trip they want, and that sentence follows
them through sign-up into their first planning chat (the handoff itself is the
sibling spec, `specs/landing-prompt-handoff/`).

## User Stories

- As a **first-time visitor**, I want to **describe my trip right on the
  landing page** so that my first tap is the product, not a sign-up form.
- As a **first-time visitor**, I want to **see what the app actually does**
  (flights, hotels, events, budget, maps) so that I can judge it without
  creating an account.
- As a **visitor without a trip in mind**, I want **destination ideas I can
  tap** so that inspiration starts the conversation for me.
- As a **returning traveler**, I want **Sign in reachable from anywhere on the
  page** so that I'm never funneled through sign-up.

## Acceptance Criteria

- [ ] The page renders, top to bottom: hero, feature grid, destination rail,
      how-it-works, closing CTA band, footer — at phone and desktop widths.
- [ ] The page is always the dark brand look, regardless of the visitor's
      system/app theme setting; the rest of the app is unaffected.
- [ ] At 320×568, the hero headline, the prompt field, and its submit control
      are fully visible without scrolling; "Sign in" is always visible in the
      app bar.
- [ ] Typing a prompt and submitting hands the exact trimmed text to the
      sign-up handoff; submit is inert while the field is empty.
- [ ] Example chips fill the prompt field without navigating; destination
      photo cards start the handoff with their prompt text.
- [ ] The feature grid names only shipped capabilities: AI itinerary chat,
      live flight search, hotels with real rates, local events, budget,
      maps & routes.
- [ ] Destination photos keep their on-card photographer attribution (CC BY
      requirement).
- [ ] Every string is localized in English and Spanish; the language menu
      stays on the landing app bar.
- [ ] The `landing_viewed` analytics event still records once per app session
      and never breaks the page (instrumentation-events contract unchanged).
- [ ] Privacy Policy, Terms of Service, and the copyright line remain
      reachable before sign-up.
- [ ] The Konami brand-tap in the app bar still works; nothing inside the hero
      triggers it.

## API Surface

None. This spec is client-only; the analytics events for prompt submission
belong to `specs/landing-prompt-handoff/`.

## Data Model

None.

## UI Behavior

- **Surface:** the signed-out entry screen (everything except token deep
  links lands here while signed out).
- **Happy path:** visitor reads "Where to next?", types a trip into the
  prompt field (or taps a chip to prefill, or taps a destination card),
  submits, and continues into sign-up with the prompt preserved (sibling
  spec). Scrolling reveals features, destinations, how-it-works, and a
  closing CTA.
- **States:** hero photo loading → brand gradient fallback; photo failure →
  gradient remains, page fully usable. No loading states elsewhere (all
  content is static/bundled).

## Edge Cases & Error States

- Empty or whitespace-only submit: nothing happens (control disabled).
- Prompt longer than the handoff's limit: input caps at the same limit.
- Hero or destination images failing to decode: branded fallbacks, no layout
  shift, attribution still shown on destination cards.
- Analytics failure: silently ignored, page unaffected.

## Out of Scope

- The prompt persistence, auth traversal, chat seeding, and their analytics —
  `specs/landing-prompt-handoff/`.
- Anonymous (signed-out) chat.
- Social proof / testimonials (no honest numbers yet).
- A static SEO site outside the Flutter app (explicitly out of scope in
  specs/i18n-spanish too).
- Backfilling the hero photo's Unsplash provenance (separate chore).

## Open Questions

None — decisions (full-page scope, prompt-input hero, committed dark look,
prefill-not-autosend) were made with Brian 2026-08-17.
