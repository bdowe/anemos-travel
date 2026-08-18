# Plan: Splash screen redesign

> Decisions and geometry. The twin files carry these numbers in their own
> doc comments; this records why.

## The twin invariant

The splash is implemented twice — `web/index.html` (static CSS, visible
while the engine downloads: the long phase) and
`lib/screens/splash_screen.dart` (session restore: usually a flash) — and
both files' doc comments mandate lockstep so the flutter-first-frame handoff
is invisible. Every decision below lands in both.

## Geometry (offsets from viewport centre)

| Element | Was | Now | Why |
|---|---|---|---|
| Mark (96px light cut) | centre | centre − 24px | The mark+wordmark lockup is ~145px tall; lifting the mark puts the pair's optical centre on the viewport centre instead of hanging it ~20px low. |
| Wordmark (Cinzel 22/3.0) | +74px | +60px | 84px below the lifted mark keeps ≥24px (25% of mark height — the guideline clear space) between mark edge and caps. |
| Spinner (24px ring) | +124px | **removed** | The one generic-default element; at rest it reads as a dim smudge crowding the wordmark. |
| Dots (3 × 6px, 12px gaps) | — | bottom: 48px + safe-area | The premium-splash slot (Qantas, Marriott): loading signal out of the brand moment. |

## Motion

One rhythm: the existing mark pulse (1.0→1.04, 1.8s alternate) is kept, and
the dots breathe opacity 0.25→0.85 on the same 1.8s period with a 300ms
left-to-right stagger. CSS uses negative `animation-delay`s so the wave is
mid-cycle from the first frame; the Flutter twin gets the identical phase
from a modulo on one repeating controller. `prefers-reduced-motion` stills
both sides — CSS media block; `MediaQuery.disableAnimationsOf` in Flutter —
with the dots held at the wave midpoint (0.55).

No entrance animations on either side: the Flutter twin takes over from the
HTML splash mid-stream, so any entrance would replay at the handoff.

## Two defects the redesign surfaced (both fixed here)

- **Yellow double underline on the wordmark (Flutter side).** The splash is
  the one route with no Scaffold, so nothing provided a `Material`, and
  MaterialApp's no-Material fallback text style — red text, yellow double
  underline — leaked its decoration under the wordmark's explicit white. It
  shipped that way and flashed on every boot's cross-fade beat; nobody ever
  saw it at rest. Fixed with a transparent `Material` inside the splash.
- **The twins' wordmark letterforms never matched.** `text-transform:
  uppercase` in the CSS twin painted all full-height caps, while
  `BrandWordmark` paints the mixed-case string — Cinzel maps lowercase to
  small caps, so the in-app wordmark is cap-A + small-caps everywhere.
  Dropped the transform; the cost is the pre-swap Georgia fallback briefly
  showing true lowercase, and end-state parity with the brand wordmark wins.

## l10n

One new key, `splashLoading` ("Loading" / "Cargando"), the dots' semantic
label — the reserved `splash*` prefix's first use. The HTML dots are
`aria-hidden`; the app announces loading once it boots.

## Verification

Headless-Chrome CDP: at-rest captures with `flutter_bootstrap.js` blocked;
ink-run measurement put both twins' mark centres at identical rows and
wordmarks within 1px; a 0.9s two-frame diff under emulated
`prefers-reduced-motion` was zero pixels changed; dark mode diffs only in
animation-phase pixels (the splash is theme-invariant by design — the teal
gradient staying in dark is the recorded doctrine). Widget tests pin the
mark cut, the spinner's absence, the semantic label, and reduced-motion
stillness (`transientCallbackCount == 0`).
