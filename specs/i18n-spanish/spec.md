# Spec: Spanish Localization (i18n)

## Context

The product is English-only, in every surface: the app UI, the AI planning
chat, the emails we send, and the printable/calendar exports. That excludes
Spanish-speaking travelers entirely — the largest single non-English audience
for the destinations we already cover well (Spain, Mexico, Latin America), and
one we can reach without any new provider integrations. This feature makes the
product speak Spanish end to end, and does it through infrastructure (a locale
that is resolved once and carried everywhere) so that the *second* additional
language is a translation job rather than an engineering project.

## User Stories

- As a **Spanish-speaking traveler**, I want the app to open in Spanish when my
  phone or browser is set to Spanish, so that I don't have to hunt for a
  setting before I can use it.
- As a **bilingual traveler**, I want to pick my language explicitly, so that I
  can use the app in Spanish even though my device is in English (or vice
  versa).
- As a **Spanish-speaking traveler**, I want the AI planner to answer me in
  Spanish and write my itinerary in Spanish, so that the trip it produces is
  actually readable to me.
- As a **Spanish-speaking traveler**, I want the emails I receive (verification,
  trip reminders, price alerts, collaboration invites) in Spanish, so that the
  product doesn't switch languages the moment it leaves the app.
- As a **Spanish-speaking traveler**, I want my printed trip packet and calendar
  entries in Spanish, so that what I carry on the trip matches what I planned.
- As a **traveler on two devices**, I want my language choice to follow my
  account, so I set it once.

## Acceptance Criteria

- [ ] With the device/browser set to Spanish and no explicit choice made, the
      app opens fully in Spanish — navigation, buttons, form labels, empty
      states, error messages, dates and currency amounts.
- [ ] A language control in account settings offers *System default*, *English*
      and *Español*; choosing one switches the whole app immediately, without a
      restart, and survives closing and reopening the app.
- [ ] A globe button in the app bar — on Home, the landing page and the
      sign-in screen — opens a menu with the same three options, with the
      current choice checked; selecting one behaves exactly like the settings
      picker (immediate, persisted, synced to the account when signed in).
- [ ] The explicit choice is remembered on the account: signing in on a second
      device (with no choice made there) adopts it.
- [ ] Signed-out surfaces (landing, sign-in, sign-up) honor the device
      language, and the app-bar globe menu lets a visitor choose explicitly
      before signing in.
- [ ] With the app in Spanish, the AI planner replies in Spanish and the
      itineraries, day summaries and titles it produces are in Spanish; dates,
      airport codes and other structured values remain in their canonical
      formats.
- [ ] With the app in English, AI planning behaves exactly as it does today.
- [ ] Trip health / review findings appear in Spanish.
- [ ] Verification, password-reset, invite, trip-reminder and price-alert emails
      arrive in Spanish for a user whose language is Spanish, and in English for
      everyone else.
- [ ] The printable trip packet and downloaded calendar entries use Spanish
      labels when the trip is exported from a Spanish session.
- [ ] Place search results and weather locations come back in Spanish where the
      upstream provider offers Spanish.
- [ ] Nothing in the English experience changes: text, layout and AI behavior
      are identical to before this feature.

## API Surface

### Language negotiation (all endpoints)
- **Purpose:** let every request state which language its response should be in.
- **Request:** a standard language header. Values may be regional (`es-MX`);
  they resolve to the closest supported base language. Absent or unsupported
  values resolve to English.
- **Response:** unchanged in shape; any human-readable text it contains is in
  the negotiated language.

### `PATCH /api/v1/auth/account`
- **Purpose:** additionally persist the signed-in user's language.
- **Request:** gains an optional language field alongside the existing display
  name; both are optional, and a request touching neither is rejected as
  before. An unsupported language value is rejected.
- **Response:** the current user, now including their language.
- **Errors:** unsupported language → unprocessable entity.

### `GET /api/v1/auth/me`
- **Response:** gains the user's stored language (absent when never set).

### Public export routes (print packet, calendar files, share preview)
- **Purpose:** these are opened by token from a browser or calendar app, with no
  signed-in session, so they cannot read the app's language.
- **Request:** an optional language query parameter, which the app appends when
  it builds the link. When absent, the trip owner's stored language is used,
  falling back to English.

## Data Model

- **User** — gains a **preferred language**: the language this account's
  server-generated content (emails above all) should be written in. Optional:
  accounts that predate this feature, and clients that have not synced, have
  none, and are treated as English. It is deliberately part of the account, not
  of the traveler's *travel preferences*, because it is app configuration
  rather than travel taste — and because the AI must not be able to change it.

- **Message catalog** — the set of server-rendered strings, each identified by a
  stable key and available in every supported language. Not user data; it ships
  with the server.

## UI Behavior

- **Screen / surface:** a *Language / Idioma* group in account settings,
  alongside the existing email-preferences group; plus a globe icon button in
  the Home, landing and sign-in app bars opening a popup menu with the same
  options.
- **Happy path:** the user opens account settings, picks *Español*, and the app
  redraws in Spanish immediately. The choice is stored on the device and, if
  signed in, on the account.
- **States:**
  - *System default* (the initial state): the app follows the device language,
    and changes with it.
  - *Explicit choice*: wins over the device language on that device, and is
    adopted on other devices that have not made their own choice.
  - *Unsupported device language* (e.g. French): the app falls back to English,
    and the picker shows *System default*.
  - *Offline / signed out*: the choice still applies locally; the account sync
    happens on the next successful signed-in request and is never blocking.

## Edge Cases & Error States

- **Regional variants** (`es-MX`, `es-419`, `es-ES`) all resolve to Spanish;
  there is one Spanish translation, not per-region variants.
- **Mixed-language conversations:** if the traveler writes to the AI in a
  language other than their app language, the AI follows the traveler's
  language rather than fighting it.
- **Content created in another language:** itinerary titles, day summaries,
  checklist items and profile notes are stored in whatever language they were
  created in. Switching languages later does not retranslate existing trips —
  the app chrome changes, saved content does not. This is intentional
  (retranslating would rewrite the user's own edits) and should be visible in
  the settings copy.
- **Upstream providers:** place search and event search may return fewer or
  lower-quality results in Spanish than in English. Results are still shown; the
  language request is per-provider and independently reversible.
- **Missing translation:** any string without a Spanish translation falls back
  to English rather than showing a blank or a key. Translation coverage is
  enforced at build/test time so this should never reach users.
- **Text expansion:** Spanish runs roughly 25% longer than English; layouts must
  tolerate it without clipping or overflow.

## Out of Scope

- **Screen-reader and other accessibility work.** This feature is localization
  only.
- **Localizing API error strings.** The several hundred internal JSON error
  messages stay English: they are developer- and edge-case-facing, the app shows
  its own localized copy for the failures users actually hit, and the correct
  fix is machine-readable error codes mapped client-side — a separate feature.
- **Retranslating existing user or AI-authored trip content.**
- **Right-to-left languages**, and per-region Spanish variants.
- **Localizing flight data** (Duffel): the payload is IATA codes and structured
  values, not prose.
- **Translated marketing/legal pages** and the public landing site outside the
  app.
- **Currency conversion.** Amounts stay in their trip currency; only number
  formatting is localized.

## Open Questions

None outstanding — scope, surfaces and the language-selection model were
settled before implementation.
