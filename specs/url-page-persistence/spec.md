# Spec: URL Page Persistence

> **WHAT & WHY only.** Tech details live in `plan.md`.

## Context

On the web app, the browser URL never changes after the first page load: open a
trip, switch to the Plan tab, or drill into Alerts, and the address bar still
shows the app root. Refreshing the page therefore always dumps you back on
Home, losing your place — mid-trip-review, mid-chat, mid-anything. The URL
should reflect the page you are on, so a refresh (or a bookmarked/shared-tab
reopen) puts you back exactly where you were. As a side effect, links into
specific app pages (e.g. the trip links in re-engagement emails, which today
land on Home) start working.

## User Stories

- As a **traveler**, I want **the page I'm on reflected in the URL** so that
  **refreshing the browser doesn't lose my place**.
- As a **traveler planning in the chat**, I want **a refresh to bring back my
  conversation** so that **an accidental reload doesn't cost me my session**.
- As a **recipient of a trip-reminder email**, I want **the trip link to open
  that trip** so that **I don't have to hunt for it from Home**.

## Acceptance Criteria

- [ ] Switching top-level tabs (Home / Plan / Trips) updates the URL to `/`,
      `/plan`, `/trips` respectively.
- [ ] Opening a trip updates the URL to `/trips/<tripId>`; refreshing there
      reopens that trip with the navigation shell (rail/bar) present and the
      Trips tab selected.
- [ ] Opening Alerts, Preferences, Account settings, Admin metrics, Local
      admin, Import, Guides, or Notifications updates the URL to a stable path;
      refreshing there reopens that screen inside the shell.
- [ ] Once a plan conversation exists, the Plan tab's URL becomes
      `/plan/<chatId>`; refreshing there restores the conversation transcript.
      If the conversation can't be restored (expired, trip-bound, someone
      else's), the Plan tab opens fresh — no error dialog.
- [ ] Going back (browser back button) and popping in-app screens keeps the URL
      in sync with what's on screen.
- [ ] Signing out resets the URL to `/`.
- [ ] `/trips/<tripId>` (the shape used in re-engagement emails) and
      `/trip/<tripId>` (the shape the AI connector emits) both open the trip.
- [ ] Refreshing on a page while signed out shows the landing page; signing in
      with email+password then lands on the page the URL pointed at.
- [ ] Existing deep-link flows — share links, invites, password reset, email
      verification, SSO callback, connector consent — behave exactly as before.
- [ ] An unrecognized path behaves like today (lands on the normal app flow).

## API Surface

None. This is entirely client-side; the only server interaction is the existing
conversation-transcript fetch already used by "Continue where you left off".

## Data Model

None. No new persistence; the URL itself is the state.

## UI Behavior

- **Where:** the browser address bar, on every page of the web app.
- **Happy path:** navigate anywhere → URL updates in place (no new history
  entries) → refresh → the same page reappears, shell intact, correct tab
  highlighted.
- **States:** while a restored trip or conversation loads, the target screen's
  own loading state shows (no new spinners); restore failures degrade silently
  to the nearest sensible page (tab root).

## Edge Cases & Error States

- Deep link while signed out → landing page; the target is honored after
  email/password sign-in (and after the onboarding quiz for new accounts).
- A Google/Apple sign-in redirect leaves the page, so a deep-link target does
  not survive SSO — the user lands on Home. Known limitation.
- Restoring `/plan/<chatId>` for a conversation with no stored transcript
  (trip-bound, anonymous, graduated, or foreign) opens a fresh Plan tab.
- Screens that can't be reconstructed from a URL (full-screen trip map, guide
  detail, flight search with prefill) keep the URL of the page beneath them;
  refresh lands on that page.
- Query strings and fragments are not preserved.
- For a moment during a deep-link boot the URL may show the tab root (e.g.
  `/trips`) before settling on the full path — cosmetic only.

## Out of Scope

- Browser back/forward **history entries** (back keeps its current behavior:
  it pops the in-app screen). The URL is always *replaced*, never pushed.
- Editing the URL bar mid-session as a navigation method (pre-existing
  unsupported behavior; refresh is the supported path).
- Restoring scroll positions, map viewports, or in-screen tab state (e.g. the
  admin dashboard's inner tabs).
- Preserving deep-link targets across the SSO redirect round-trip.

## Open Questions

None.
