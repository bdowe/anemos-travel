# Spec: Instrumentation Events

## Context

The business model (`docs/business-model.md`) is growth-first, and its Phase 1
mandate is "instrument everything": the paid-tier decision, the free-tier caps,
and the break-even math all hang on numbers we currently cannot measure —
activation, retention, **booking attach rate**, and per-user AI cost. Today the
app records nothing: no way to answer "what fraction of planned trips lead to a
booking click?" even directionally. This feature adds a lightweight,
first-party event log and a small admin metrics summary. No third-party
analytics — events stay in our own database, tied to the user id and nothing
else.

## User Stories

- As the **product owner**, I want every key funnel moment (signup → first
  trip → booking click) recorded so that I can measure activation and attach
  rate before deciding on caps and a paid tier.
- As the **product owner**, I want AI usage per planning session recorded so
  that I can estimate COGS per active user.
- As an **admin**, I want a single metrics summary I can query so that I can
  watch the Phase 1 numbers without exporting data.
- As a **user**, I never want instrumentation to slow down or break my
  experience — tracking must be invisible and best-effort.

## Event Taxonomy

Recorded server-side (no client involvement):

| Event | When | Notable detail carried |
|---|---|---|
| `user_registered` | account created | — |
| `onboarding_completed` | quiz finished or skipped | — |
| `plan_session_started` | a signed-in user starts a planning stream | trip id when refining |
| `plan_session_completed` | the planning stream finishes | token usage, tool-call count, trip id if one was produced |
| `trip_created` | the agent persists a new trip | trip id, item count |
| `trip_refined` | the agent updates an existing trip | trip id |
| `booking_marked_booked` | user checks off a booking todo as booked | trip id, todo kind, provider |

Recorded from the client (the moments only the client can see):

| Event | When | Notable detail carried |
|---|---|---|
| `booking_link_clicked` | user opens a booking handoff link | trip id, todo id, provider, kind |
| `landing_viewed` | a signed-out visitor renders the landing page (once per app session) | — |
| `landing_prompt_submitted` | a landing prompt handed to sign-up (specs/landing-prompt-handoff) | surface (`hero`\|`card`), kind (destination slug, cards only); never the prompt text |
| `pending_prompt_consumed` | the stored landing prompt reached the signed-in composer | surface (`hero`\|`card`) |

`booking_link_clicked` is the **attach-rate numerator** — the reason this
feature exists. Completed bookings cannot be observed directly (affiliate
conversions live in partner dashboards); clicks are the in-product proxy, with
`booking_marked_booked` as the self-reported completion signal.

### Anonymous client events (Wave 8)

Everything above `user_registered` used to be invisible: the events endpoint
required authentication and the client dropped events for signed-out sessions,
so the funnel had no top. `POST /events` now also accepts **unauthenticated**
requests, restricted to a deliberately tiny whitelist — this is a
spam-writable surface with no identity to hold accountable, so every accepted
type must be a moment a signed-out visitor can actually produce:

| Anonymous event | Why it's on the whitelist |
|---|---|
| `landing_viewed` | the top of the funnel: landing-page views over signups is the first conversion number |
| `booking_link_clicked` | signed-out booking handoffs (e.g. from future public surfaces) still count toward total clicks |
| `landing_prompt_submitted` | the landing hero's prompt submit is by definition produced signed out; its consume-side sibling `pending_prompt_consumed` stays authed-only |

There is intentionally **no** `plan_started_anonymous`: the Flutter app has no
signed-out planning entry point (AuthGate routes signed-out visitors to the
landing page), and anonymous direct `/plan` API calls are already recorded
server-side as `plan_session_started` with a NULL user id (surfaced as
`plan_sessions_anonymous`).

Spam-bounding measures on the anonymous path:

- **Strict rate limiter** — the anonymous route sits behind the strict per-IP
  tier (same as `/plan` and credential routes), bounding write volume.
- **Whitelist rejection** — an anonymous `event_type` off the whitelist is a
  400; server-side types cannot be spoofed.
- **`trip_id` always dropped** — ownership cannot be verified without a user,
  and the attach-rate numerator counts DISTINCT trip ids, so anonymous events
  are stored with `trip_id` NULL unconditionally.
- **Metadata whitelist** — the same closed key set (`provider`, `surface`,
  `kind`, `todo_key`), 64-char string values, provider lowercased, 2 KB cap.
- **No silent auth downgrade** — a request presenting *any* Authorization
  header is routed through the authenticated path and validated; an invalid
  token is a 401, never treated as anonymous.
- **Client-side once-per-session guard** — the app records `landing_viewed`
  at most once per app session (a static guard, so rebuilds and sign-out
  round trips don't re-record).

## Acceptance Criteria

- [x] Registering, completing/skipping onboarding, starting and finishing a
      planning session, saving a trip, and refining a trip each produce exactly
      one event, visible in the admin metrics counts.
- [x] Tapping "Open search" on a booking todo records a `booking_link_clicked`
      event with the trip, todo, and provider — and the link still opens
      immediately, even if recording fails or the network is down.
- [x] Marking a booking todo as booked records a `booking_marked_booked` event.
- [x] A `plan_session_completed` event carries token usage so AI cost per user
      can be summed.
- [x] An admin can fetch a metrics summary for a chosen window: signups,
      activation rate (signups that saved a first trip), trips created,
      attach rate (trips with ≥1 booking click), clicks by provider, todos
      marked booked, second-trip retention, session-frequency returning
      users, active users (MAU), plan sessions, total tokens, and estimated
      Claude cost (total and per active user) — see Derived Metric
      Definitions.
- [x] Non-admins cannot record arbitrary event types or read metrics.
- [x] With the database down, every instrumented flow (signup, planning,
      booking links) behaves exactly as it does today — events are silently
      dropped, never surfaced as user-facing errors.
- [x] No PII is stored in events beyond the user id: no email, no IP address,
      no user agent, no free text.

## API Surface

### `POST /api/v1/events`
- **Purpose:** record a client-observed event. Fire-and-forget semantics.
- **Request:** `event_type` (must be a client-permitted type), optional
  `trip_id`, optional `metadata` (small, flat key/value detail: todo id,
  provider, kind).
- **Authentication:** optional, with two distinct paths matched by the
  presence of an `Authorization` header:
  - **Authenticated** (header present): the token is validated and the event
    attributed to the user; the full client whitelist applies and `trip_id`
    survives only if the caller can access the trip. An invalid token is a
    401 — never a silent downgrade to anonymous.
  - **Anonymous** (no header): only the anonymous whitelist
    (`landing_viewed`, `booking_link_clicked`) is accepted; the row is stored
    with `user_id` NULL and `trip_id` NULL unconditionally; the route sits
    behind the strict per-IP rate limiter.
- **Response:** `202 Accepted`, empty body — returned even when persistence is
  degraded (the event is dropped, not errored).
- **Errors:** 401 when a presented token is invalid or expired; 400 when
  `event_type` is missing or not permitted for the request's auth level
  (server-side types cannot be spoofed through this endpoint); 429 when the
  anonymous strict tier is exceeded.

### `GET /api/v1/admin/metrics?days=`
- **Purpose:** the Phase 1 dashboard-in-an-endpoint. **Admin only.**
- **Request:** optional `days` window (default 30).
- **Response:** counts and rates for the window — landing views (anonymous;
  see below), signups, activated users and activation rate, trips created,
  trips with ≥1 booking click and attach rate, booking clicks by provider
  (totals plus the anonymous split; see below), todos marked booked, the
  derived metrics below, plan sessions, total input/output/cache tokens, and
  cost estimates.

#### Anonymous rows and the derived metrics

Anonymous events (`user_id` NULL) must never distort the signed-in numbers:

- **`landing_views`** counts anonymous `landing_viewed` events — the top of
  the funnel, above signups. Client-guarded to once per app session and
  strict-rate-limited at ingest, but still an unauthenticated count: read it
  as directional, not audited.
- **MAU / engagement** (`active_users`, `session_frequency_returning`,
  `second_trip_retention`) filter `user_id IS NOT NULL` explicitly — NULL
  rows can never group into a phantom user.
- **Attach rate**: anonymous `booking_link_clicked` events count toward
  `booking_clicks` and `clicks_by_provider`, but they **cannot** count toward
  `trips_with_booking_click` (and therefore `attach_rate`) — their `trip_id`
  is NULL by construction (dropped at ingest, ownership unverifiable), and
  the numerator counts DISTINCT non-NULL trip ids. This is deliberate: attach
  rate stays a signed-in, per-trip metric.
- **Booking-click anonymous split** (`booking_clicks_anonymous`,
  `clicks_by_provider_anonymous`): `booking_clicks` and `clicks_by_provider`
  remain **totals** (authenticated + anonymous — backward compatible), and
  the `user_id IS NULL` slice is exposed alongside them. Rationale (Wave-8
  security review): anonymous clicks are unauthenticated writes — rate-limit
  bounded but spoofable at per-IP-limiter cost — so any partner-facing claim
  ("N clicks sent to provider X") must be quotable as *total minus anonymous*,
  not just the conflated total. Both splits are FILTER columns on the
  existing grouped queries, not extra round trips (the dashboard's 7-query
  load budget holds); `booking_clicks_anonymous` comes from the per-type
  grouped count (exact — not a sum of the LIMITed per-provider rows), and
  `clicks_by_provider_anonymous` is a parallel map carrying only providers
  with ≥ 1 anonymous click.
- **`activation_rate`** joins `user_registered` to `trip_created` on
  `user_id`; NULL never joins, so anonymous rows are inert there.
- **Errors:** 401 unauthenticated; 403 non-admin; 503 when persistence is
  unavailable.

## Derived Metric Definitions

These numbers drive pricing and phase-gate decisions (`docs/business-model.md`
§8), so their definitions are normative here — the SQL implements this spec,
not the other way around.

- **`second_trip_retention`** — the business model's retention metric ("users
  returning for a second trip", the Phase 3 trigger): count of signed-in users
  whose `trip_created` events span **≥ 2 distinct trip lineages with first
  creations at least 7 days apart** inside the window. A *lineage* is the My
  Trips grouping (`COALESCE(trips.chat_id, trips.id)`): `trip_created` fires
  on every finalize, including a new **version** of an existing chat lineage,
  so events are deduplicated to one first-creation timestamp per lineage
  before the spread check (`max(first_at) − min(first_at) ≥ 7 days` per user,
  which implies ≥ 2 lineages). The 7-day gap is what separates "came back for
  another trip" from "kept editing the same planning burst"; two trips created
  the same week count once, and re-finalizing one trip weeks later counts
  zero. Known trade-off: the lineage lookup joins `trips`, so events whose
  trip row was later deleted drop out (slight undercount, preferred over the
  version-save overcount).
- **`session_frequency_returning`** — the metric formerly (and misleadingly)
  named `returning_users`: users with planning sessions on ≥ 2 distinct days
  in the window. It is a **session-frequency proxy**, not trip retention — a
  user polishing one trip across two evenings counts. Kept because it is still
  a useful engagement signal; renamed so nobody reads it as the §8 retention
  number.
- **`active_users` (MAU)** — distinct signed-in users with ≥ 1
  `plan_session_started` event in the window. Anonymous sessions are
  excluded (no stable identity). This is the denominator for COGS per active
  user.
- **`est_claude_cost_usd` / `est_cogs_per_active_user`** — **estimates
  covering Claude spend only** (Google Places and other provider calls are
  not metered — deferred, see Out of Scope). Computed from the
  `plan_session_completed` token sums at the published claude-sonnet-4-6
  prices, pinned in one const block in `analytics.go` (update it if the /plan
  model changes):

  | Token class | USD per MTok |
  |---|---|
  | input (uncached) | 3.00 |
  | output | 15.00 |
  | cache write (5-minute TTL, 1.25× input) | 3.75 |
  | cache read (0.1× input) | 0.30 |

  `est_claude_cost_usd = (input·3.00 + output·15.00 + cache_write·3.75 +
  cache_read·0.30) / 1,000,000`, and `est_cogs_per_active_user =
  est_claude_cost_usd / active_users` (0 when there are no active users).
  `input_tokens` is the uncached remainder as reported by the API — cache
  reads/writes are billed separately, so the four classes are summed, never
  double-counted.
- **`agent_loop_cap_hits`** — the metric formerly named `plan_cap_hits`:
  completed plan sessions whose metadata carries `max_iterations_hit = true`.
  The underlying event is unchanged; only the label moved. Rationale: the cap
  it counts is the **agent-loop max-iterations safety cap** in
  `plan_handler.go` — a runaway-agent-loop signal — not a free-tier usage cap,
  so calling it "cap hits" next to the business model's "cap-hit rate" (% of
  users hitting free limits) invited a wrong pricing read. When free-tier
  limits exist, their metric will be a separate, user-denominated number.

Server-side events have no API surface — they are recorded inside the existing
flows they describe.

## Data Model

- **Analytics event** — one row per occurrence: which user, which event type,
  optional trip reference, optional small metadata bag, and when it happened.
  Events are append-only and never user-visible; trip references are loose
  (an event outlives the trip it points at). Retention/aggregation policies
  are deliberately not part of this feature.

## UI Behavior

- **No new screens.** The only UI change is invisible: opening a booking link
  also records the click.
- **Happy path:** user taps "Open search" on a booking todo → the external
  link opens immediately → the event is recorded in the background.
- **States:** there are none — tracking has no spinner, no error toast, no
  retry UI. A failed event is silently dropped.
- Admin metrics are consumed via the API directly (curl or similar); an admin
  screen is out of scope.

## Edge Cases & Error States

- Database unreachable (degraded mode): server-side recording no-ops; the
  events endpoint still returns 202; nothing user-facing changes.
- Event recording must never fail its parent flow: a failed insert during
  signup or trip save is logged server-side and swallowed.
- Client event with an unknown or server-only `event_type` → 400 (on both the
  authenticated and anonymous paths; the anonymous whitelist is stricter).
- Oversized metadata is rejected or truncated safely (bounded payload).
- A request presenting an invalid/expired token → 401, never recorded as
  anonymous.
- Anonymous planning sessions (unauthenticated `/plan` use) are recorded
  server-side with a NULL user id (`plan_sessions_anonymous`); they are
  excluded from every user-denominated metric.

## Out of Scope

- Third-party analytics (PostHog, GA, etc.) and any data export.
- Broad anonymous / pre-signup tracking (marketing funnels, referrer/UTM
  capture, anonymous identity stitching). The Wave 8 anonymous whitelist
  covers exactly two in-product moments — nothing about the visitor is stored
  beyond the event itself (no IP, no user agent, no fingerprint).
- Dashboards or Flutter admin UI for metrics (endpoint only).
- A/B testing, feature flags, experiment assignment.
- Client-side event batching/queueing — one best-effort request per event.
- Tracking Google Places/Duffel call costs (Claude tokens are the dominant
  COGS driver; provider-call metering can come later).
- Enforcing usage caps — this feature measures; it never limits.

## Open Questions

None — resolved with the product owner before implementation:
- "Returning user" = planning sessions on ≥2 distinct days within the window.
  (Later renamed `session_frequency_returning`; true trip retention is the
  separate `second_trip_retention` — see Derived Metric Definitions.)
- `onboarding_completed` does not distinguish finish vs. skip; the existing
  onboarding-complete contract stays untouched.
