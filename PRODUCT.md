# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Primary user: Brian — a frequent traveler planning his own real trips. The bar
for every decision is "does Brian reach for it for his own trips," not "would
people pay for this." Second ring: the friends-and-family pre-beta cohort
(non-technical, arriving via a personal DM, asked to find what's rough and say
so). Third ring: public frequent travelers — people currently planning trips
across a dozen tabs and a ChatGPT window that forgets everything.

Collaborators are a real role: trips are shared with editors and viewers
(co-planners), and the product distinguishes owner planning state from what a
co-planner sees.

## Product Purpose

Anemos (anemos.travel) turns a conversation into a real, saved, refinable trip.
You describe the trip; an AI planning agent builds the actual day-by-day
itinerary — real flights, real places, real events, on a map — and the trip
persists as structured data you can book against, budget, share, pack for, and
keep refining in the same chat. Success means the trip you actually take was
planned here, end to end, with less friction than the twelve-tab alternative.

## Positioning

**Chat → real persisted trip.** A ChatGPT window produces a wall of text that
forgets; a booking site starts from an airport code. Anemos is the only place
where describing a trip yields a persistent, structured itinerary — coordinates
verified against Google Places, flights from live inventory, legs with modes and
dates — that both the chat agent and the trip page continue to edit as the same
underlying object. This is the claim future work must protect.

Supporting differentiators (real, but secondary): the product learns how you
travel (home airport, baggage tier, budget tier, preferences quietly shape every
plan); locally-sourced, attributed recommendations ("legit info you can't
google") that the agent cites first; and the whole trip — flights, stays,
ferries, events, budget, packing — in one product.

## Operating Context

- Planning happens conversationally (the plan chat, desktop and mobile web) and
  on the trip page (tabs: itinerary, bookings, budget, map); both surfaces write
  the same server-side truth, by design and by pinned test.
- Trips are also **imported** from external AI chats (paste a ChatGPT/Claude
  conversation) and created from other assistants via the MCP connector.
- Real bookings happen off-platform today via handoff links (Booking.com
  affiliate, Google Flights, Ferryhopper); the product tracks what's booked,
  chosen, and still open per leg.
- Provider data is live-lookup (Duffel/SerpApi flights, SerpApi hotels,
  Ticketmaster events, Google Places) under free-tier quotas with caps, caches,
  and daily budgets; the local-recommendations layer is persisted and
  admin-curated.
- Production is live on DigitalOcean behind an nginx gateway; deploys run from
  CI; an admin ops/metrics surface monitors health and uptime.

## Capabilities and Constraints

- Core loop: SSE-streamed agent chat over an ordered tool registry (search
  places / local recs / flights / hotels / events / ferries, itinerary create
  and update, preferences, booking todos, trip endpoints, transport modes,
  descriptions). Registry order is part of the prompt-cache prefix — a hard
  technical constraint on how tools evolve (append-only).
- Trips: legs with derived transport modes, booking shortlists per leg, budget
  with planned-vs-paid expenses, daily food-spend estimates (labelled model
  estimates, never presented as provider data), events rails, wear/pack guide,
  shared maps, collaborators and public share pages.
- Accounts: email+password, Google and Apple SSO; anonymous use works for
  planning (free caps apply); i18n is live (English, Spanish; client owns
  locale).
- **No FX anywhere in the app**: prices are never converted between currencies —
  a mismatch is reported, not converted. Model estimates are always labelled as
  such on the wire and on render.
- **Degrade, never invent**: every provider failure path returns an honest
  absence with a stable reason code, not a plausible substitute.
- Business model (working strategy, not shipped UI): booking-linked revenue as
  the base; a future annual/per-trip "power traveler" tier — never monthly; the
  entire core loop stays free. Keeping the product free is a revenue decision.
- Undecided product facts: the pre-beta `[FEEDBACK CHANNEL]` destination;
  paid-tier scope and timing (deliberately deferred until evidence).

## Brand Commitments

- Name **Anemos**, domain anemos.travel, operated by Golden Tempo LLC. (Phase 0
  trademark/DBA work is owed; the racehorse origin story — Golden Tempo — is
  part of the founder voice, not the product name.)
- Visual identity is governed by an existing four-layer stack that is binding on
  all UI work: `.claude/skills/design-inspiration` (taste),
  `src/packages/flutter-app/lib/theme/` (token values),
  `.claude/skills/brand-guidelines` + `docs/branding/brand-guidelines.html`
  v1.5 (conformance, with `scripts/check.sh` on touched Dart files).
- Standing identity facts: Cormorant Garamond throughout — 600 for the
  wordmark, 500 for headings, one family and two weights — the teal palette
  stays, no plate behind the logo anywhere; the landing page's dark canvas is a
  recorded exception to the light app surface. A rule that must break gets
  written into the guideline doc in the same PR.
- Voice (from the pre-beta pitch): first-person, warm, honest about roughness;
  "complaints are useful" — never corporate, never overclaiming.

## Evidence on Hand

- Live production app at anemos.travel with real accounts, real flight/hotel/
  event/place data, and real trips.
- `docs/prebeta-pitch.md` (channel-ready launch copy), `docs/sales-pitch.md`
  (investor framing), `docs/business-model.md` (revenue reasoning),
  `docs/friction-log.md` (the queue-driving dogfood log).
- No user testimonials, case studies, press, usage benchmarks, or revenue
  numbers exist yet — future surfaces must not fabricate any. Legal review of
  the live terms (arbitration/class-waiver) has not happened; do not cite legal
  sign-off.

## Product Principles

1. **The bar is Brian's own trips.** The friction log drives the queue; a
   feature that doesn't make his next real trip easier is deferred.
2. **Explicit is better than implicit** (docs/zen.md, binding): data semantics
   live in schema and enforced boundaries, derived state is computed in exactly
   one place, and a mutating action's result states the post-state its consumer
   observes.
3. **Chat and page write the same truth.** Every trip fact has exactly one
   server-side writer that both surfaces call; parity is pinned by tests, not
   convention.
4. **Degrade, never invent.** An unavailable provider, price, or estimate
   yields a labelled absence with a reason — never a plausible-looking number.
5. **The funnel stays open.** The core planning loop is free; monetization
   rides bookings and heavy use, never a gate in front of the first trip.
