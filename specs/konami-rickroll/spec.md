# Spec: Konami-code rickroll

> Deliberately `spec.md` only. There is no data model, no endpoint, and one
> surface — a `plan.md` and `tasks.md` here would be ceremony, not clarity.

## Context

Anemos has no easter eggs. It should have exactly one. Entering the Konami
code (↑ ↑ ↓ ↓ ← → ← → B A) anywhere in the app rolls the site: a dancing
figure takes over the background, the hook plays, and the app carries on
underneath until it's dismissed.

The point is delight, so the bar is that it costs nothing and breaks nothing.
Two constraints from the deployment shape the whole feature and are worth
recording here because they will outlive the joke:

- The `/app/` locations send `Cross-Origin-Embedder-Policy: require-corp`, so a
  cross-origin YouTube embed — the usual way anyone builds this — is blocked.
- The CSP declares no `media-src`, so audio falls back to `default-src 'self'`.
  It ships `Report-Only` today with an intent to enforce, meaning a
  `data:`/`blob:` clip would work now and break later.

Both are why the picture is drawn and the sound is synthesized rather than
bundled or streamed. That also means nothing third-party ships, so no bundled
asset needs a provenance row it could not honestly be given.

## User Stories

- As **someone poking at the site**, I want the Konami code to do something
  ridiculous, so that finding it feels like a reward.
- As **anyone who triggers it by accident**, I want one obvious way out, so
  that a joke never becomes a trap.
- As **a traveler mid-sentence in the chat composer**, I want my typing, my
  scroll position and my unsaved edits to survive it, so that the easter egg
  can never cost me work.

## Acceptance Criteria

- [ ] Entering ↑ ↑ ↓ ↓ ← → ← → B A rolls the site from any screen, signed in or
      out — including the landing page and the screens outside the tab shell.
- [ ] The rolled state shows an animated figure over a drifting rainbow, with
      the app still visible underneath, plus a caption and a close control.
- [ ] The hook plays on the web. Where the browser refuses to start audio, the
      visual runs anyway and nothing errors.
- [ ] It ends on Escape, on a tap or click anywhere, on the close control, and
      on its own when the tune finishes.
- [ ] Escape while rolled dismisses **only** the roll — it does not also close
      the fullscreen map or the refine chat panel underneath it.
- [ ] No keystroke is swallowed: arrow keys still move a text caret, B and A
      still type, and every existing keyboard shortcut behaves as before.
- [ ] Triggering it does not reset or remount anything — an in-progress chat
      draft, an open expense editor, and the current scroll position all
      survive.
- [ ] Overshooting the opening arrows (↑ ↑ ↑ ↓ ↓ …) still completes the code.
- [ ] Nothing is downloaded to run it, and the page weight is unchanged.

## API Surface

None. This feature does not talk to the API.

## Data Model

None. Nothing is persisted; the rolled state lasts as long as it is on screen.

## UI Behavior

- **Surface:** a layer above every route and dialog, so no screen has to know
  it exists.
- **Happy path:** enter the code → the roll appears over the current screen and
  the tune starts → it ends itself when the tune does, or immediately on
  Escape / tap / close.
- **States:** there are only two — rolled and not. There is no loading state
  (nothing is fetched) and no error state (a browser that will not play audio
  is an ordinary outcome, not a failure).

## Edge Cases & Error States

- **The browser refuses audio.** Safari can withhold playback even after a
  keystroke. The visual is never gated on sound.
- **The code is entered while already rolling.** Ignored — restarting would
  re-attack the tune from the top.
- **The code is entered with a text field focused.** It fires, and the field
  keeps every one of those keystrokes.
- **No keyboard.** Phones cannot enter the code at all. That is accepted, not
  worked around: see Out of Scope.

## Out of Scope

- Any mobile or touch trigger. Adding one means threading a tap counter through
  the shared wordmark widget, and the code is a keyboard joke.
- Persisting that a user has found it, or any analytics on it.
- A setting to disable it.
- Sound on iOS/Android builds — those cannot reach the trigger.

## Open Questions

None outstanding.
