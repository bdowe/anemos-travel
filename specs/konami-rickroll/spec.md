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
- As **someone on a phone**, I want a way in that does not need arrow keys, so
  that the egg is not reserved for people at desks.
- As **anyone who triggers it by accident**, I want one obvious way out, so
  that a joke never becomes a trap.
- As **a traveler mid-sentence in the chat composer**, I want my typing, my
  scroll position and my unsaved edits to survive it, so that the easter egg
  can never cost me work.

## Acceptance Criteria

- [ ] Entering ↑ ↑ ↓ ↓ ← → ← → B A rolls the site from any screen, signed in or
      out — including the landing page and the screens outside the tab shell.
- [ ] Seven taps in quick succession on the brand in the app bar do the same,
      with no keyboard — on every screen the app bar appears, including the
      ones where the brand is not a button at all.
- [ ] "Quick succession" means a pace a person can actually produce by hand:
      tapping about once a second, or pausing between taps, still gets there.
      A tap every three seconds does not.
- [ ] The hook is audible on a phone, not only on a desktop browser.
- [ ] Those taps change nothing else: a single tap still goes home where it did
      before, the brand gains no ripple, tooltip or button role where it had
      none, and taps spread out over ordinary navigation never accumulate.
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
  it exists. The two triggers are the keyboard anywhere in the app, and the
  brand in the app bar.
- **Happy path:** enter the code (or tap the brand seven times) → the roll
  appears over the current screen and the tune starts → it ends itself when the
  tune does, or immediately on Escape / tap / close.
- **States:** there are only two — rolled and not. There is no loading state
  (nothing is fetched) and no error state (a browser that will not play audio
  is an ordinary outcome, not a failure).

## Edge Cases & Error States

- **The browser refuses audio.** The visual is never gated on sound. Note the
  rule is stricter than "the user has interacted at some point": Safari wants
  audio opened *inside* a gesture handler, and the egg starts its tune a frame
  later than the gesture that triggered it. Audio is therefore made ready at
  the user's first interaction with the page, not when the egg fires — the
  first version did the latter and was silent on phones.
- **The phone is on silent.** Web audio obeys the hardware switch on iOS and
  nothing in a web page can override it. Not a bug we can fix.
- **The code is entered while already rolling.** Ignored — restarting would
  re-attack the tune from the top.
- **The code is entered with a text field focused.** It fires, and the field
  keeps every one of those keystrokes.
- **No keyboard.** Phones cannot enter the Konami code at all, which is what
  the seven-tap trigger exists for.
- **Taps that are not a burst.** A stray tap long before a deliberate run must
  not cost the user a tap — it starts the new run rather than being discarded.
- **The brand is tapped mid-navigation.** Each of the seven taps still does
  whatever it did before, so on the shell the first one goes home. Accepted: a
  single tap already does that.

## Out of Scope

- A trigger anywhere but the app-bar brand. The landing page's large hero
  wordmark is a tempting second target but is not on every screen, and one
  trigger is enough to find.
- A shake gesture. It would mean a sensor dependency and, on iOS Safari, a
  motion-permission prompt — a lot of machinery for a second way in.
- Persisting that a user has found it, or any analytics on it.
- A setting to disable it.
- Sound on iOS/Android builds — those cannot reach the trigger.

## Open Questions

None outstanding.
