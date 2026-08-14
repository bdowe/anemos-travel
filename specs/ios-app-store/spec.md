# Spec: iOS App Store v1

> **WHAT & WHY only.** Tech choices, file names, and libraries live in
> `plan.md`.

## Context

Golden Tempo Travel has only ever shipped as a web app. Being on the iOS App
Store is how a consumer travel product reaches most of its users, and the
founder's own dogfooding (the product north star) happens mostly away from a
desk. An audit (2026-08-13) found the app's core — chat, maps, trips, offline
cache, dictation — already works natively; what's missing is the iOS shell
(identity, icons, permissions), a working sign-in round trip, working links
(share/legal/deep links currently assume a browser page origin), and a handful
of App Review compliance requirements. This spec covers the smallest
review-passing v1. Apple Developer enrollment (Organization, Golden Tempo LLC)
runs in parallel; everything here except final signing and store setup is
buildable before it completes.

## User Stories

- As a **traveler**, I want to install Golden Tempo Travel from the App Store
  on my iPhone so that I can plan and check my trips without a browser.
- As an **iPhone user**, I want Google/Apple sign-in to finish inside the app
  so that I end up signed in where I started.
- As a **trip owner**, I want share and invite links I send from the app to be
  real absolute links, and links I receive to open the app directly.
- As a **signed-in user without a password** (Google/Apple-only), I want to
  delete my account from the app, which today wrongly demands a password.
- As a **chat user**, I want to be told once that my messages are processed by
  an AI provider before I start chatting (App Review requires this).

## Acceptance Criteria

- [ ] The app installs and runs on a physical iPhone with the Golden Tempo
      icon, name, and branded launch screen; Spanish devices get the Spanish UI.
- [ ] Google and Apple sign-in complete inside an in-app authentication sheet
      and land the user signed in on the home screen; cancelling the sheet is
      silent. Web sign-in behavior is byte-identical to today.
- [ ] Trip share, invite, print, calendar-export, and Privacy/Terms links
      opened or shared from the iOS app are absolute `https://goldentempotravel.com`
      URLs (no relative paths, no localhost).
- [ ] Tapping a share, invite, verify-email, or password-reset link on iPhone
      opens the app (installed) at the right screen — cold start and warm.
- [ ] Attaching a photo in chat prompts with a purpose-specific photo-library
      permission message and works; dictation uses native speech recognition.
- [ ] An account with no password can delete itself from the app with a plain
      confirmation; an account with a password is still password-gated. On web
      too (this is a live web bug).
- [ ] Deleting an account that signed in with Apple revokes its Apple tokens
      server-side; Apple being unreachable never blocks the deletion.
- [ ] Before a user's first chat message on any platform, a one-time notice
      states messages are processed by our AI provider; it never reappears
      after acknowledgment.
- [ ] A release build can be produced with one make target and uploaded to
      TestFlight; every reviewer-visible URL in the binary resolves.

## API Surface

### `GET /api/v1/auth/google` and `GET /api/v1/auth/apple` (changed)
- **Purpose:** start SSO; now aware of native callers.
- **Request:** optional `platform` query param. Only the empty value and `ios`
  are accepted; anything else is rejected as a bad request (refuse the
  temptation to guess).
- **Response:** unchanged redirect dance, except the final redirect for
  `platform=ios` targets the app's own callback scheme with the same one-time
  handoff code (or the literal `error`). The scheme is fixed server-side; the
  caller cannot choose a redirect target.
- **Errors:** unchanged; error outcomes also ride the platform-appropriate
  redirect.

### `DELETE /api/v1/auth/account` (changed behavior, same contract)
- **Purpose:** unchanged. For accounts with an Apple identity, the server now
  also revokes the stored Apple token before deleting. Revocation failure is
  logged, never surfaced, and never blocks deletion.

### Authenticated user payload (changed)
- **Purpose:** the client must know whether the account has a password —
  today it guesses (and guesses wrong for SSO-only users).
- **Response:** gains an explicit boolean stating whether a password exists.

## Data Model

- **Apple identity** — gains an optional stored refresh token, captured at
  sign-in (latest sign-in wins), existing only to make account-deletion
  revocation possible. Absent for Google/email identities and for Apple
  identities created before this change (revocation is then skipped).

## UI Behavior

- **Sign-in (iOS):** Google/Apple buttons open the system in-app auth sheet;
  on success the app shows the same completion screen as web, then home.
- **Account settings → Danger zone:** delete dialog shows the password field
  only when the account has a password; otherwise a plain confirm with copy
  explaining the deletion is immediate and irreversible.
- **Chat:** first-ever send is preceded by a one-time AI-processing notice
  with an acknowledge action; acknowledging proceeds with the send.
- **Incoming links (iOS):** open the same screens the web routes show; links
  the app can't handle open in the browser as today.

## Edge Cases & Error States

- SSO sheet cancelled → no error UI, stay on the auth screen.
- Handoff code expired (60s) or already used → same error screen web shows.
- Apple revocation endpoint down during deletion → deletion succeeds; failure
  logged server-side.
- Stale cached user snapshot lacking the password flag → treated as
  passwordless in the dialog; the server still enforces password verification,
  so the worst case is one retriable error, never a blocked deletion.
- Link for a screen requiring auth opened while signed out → existing web
  behavior (auth screen first).
- App backgrounded mid-chat-stream → stream may die; the existing manual
  retry affordance is the v1 answer (documented limitation).

## Out of Scope (v1 cut line)

- Native GPS for "near me" (manual entry fallback ships; keeps the privacy
  label at "Location: not collected").
- Client crash reporting, map tile cache, in-app print/calendar polish
  (Safari bounce ships), stream auto-resume after backgrounding.
- iPad targeting (iPhone-only v1; compatibility mode covers iPad), iPad
  drag-drop.
- Native Sign in with Apple sheet (the in-app web-session flow ships;
  fast-follow only if review objects).
- Hover-only control visibility on touch — promoted only if device dogfooding
  shows a core action unreachable.
- CI-driven signing/TestFlight upload (local build + upload ships).
- Push notifications, payments/IAP (none exist; nothing to declare).

## Open Questions

None blocking implementation. Two values arrive mid-flight from enrollment
(Apple Team ID for the site-association file; signing team in the project) —
both are placeholder-then-fill steps listed in `tasks.md`, not design
decisions.
