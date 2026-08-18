# Plan: Auth screen split-pane redesign

> **HOW.** See `spec.md` for what & why. Flutter-only; no API changes.

## Technical Approach

One file carries the redesign: `lib/screens/auth_screen.dart`. A single
`LayoutBuilder` wrapping the whole `Scaffold` decides the layout — never
`MediaQuery.sizeOf`, which is nondeterministic under widget-test
`setSurfaceSize` and would also re-decide per-widget what must be one shared
decision (the AppBar's icon colors depend on where the photo is). The form
body is extracted verbatim into `_formScroller()` so all three layouts reuse
it with zero changes inside the form column — that is what keeps the pinned
geometry tests (`auth_screen_sso_order_test.dart`'s 24px title gap, the
vertical ordering) passing unmodified.

Layouts, decided by the incoming constraints:

- `maxWidth >= 900` (**wide**, the landing family's breakpoint):
  `Row[Expanded(_AuthPhotoPanel), SizedBox(width: formPaneWidth, form)]`
  with `formPaneWidth = (maxWidth * 0.45).clamp(468, 560)` — the 468 floor is
  the 420 auth column + 2×`AppSpacing.xl`, so the column never compresses;
  the cap keeps the photo dominant on ultrawide.
- narrow and `maxHeight >= 620` (**band**): `Column[SizedBox(height:
  bandHeight, _AuthPhotoPanel), Expanded(form)]` with `bandHeight =
  (maxHeight * 0.22).clamp(140, 220)`. The band is pinned outside the scroll
  view. 620 is chosen so the 800×600 default test surface and 360×450
  keyboard viewports render today's exact layout; on phones the keyboard
  shrinking `maxHeight` below 620 collapses the band on purpose (form first
  when typing) — commented in code, because "fixing" it with
  `MediaQuery.sizeOf` is the repo's known widget-test trap.
- otherwise: today's screen, byte-identical (no extend, null icon themes).

`_AuthPhotoPanel` (private, bottom of the same file, `Key('auth-photo-panel')`)
is the landing-hero idiom: `brandGradient` fallback → `hero_santorini.jpg`
(`cover`, `excludeFromSemantics`, `gaplessPlayback`, 250ms fade
`frameBuilder`, `errorBuilder` → shrink, `cacheWidth` quantized to 320px
buckets against the panel's own constraints, not the window) → `heroScrim` →
tagline bottom-left. `heroScrim` is `bottomLeft(brandDark 88%)→topRight(35%)`
— darkest exactly where the tagline sits, so no new tokens are needed. No
logo on the photo (the form column already brands; the landing hero's
no-double-branding precedent). Tagline style is stated locally per the
landing-hero precedent: `AppFonts.display` + explicit `w400` (Marcellus
one-weight rule), white, `fontSize: wide ? 38 : 24`, height 1.15.

AppBar: the one transparent bar stays; `extendBodyBehindAppBar: wide ||
showBand`; `iconTheme` white whenever a photo reaches the top-left (both
photo layouts); `actionsIconTheme` white only in band mode — on wide the
globe sits over the light form pane and keeps the theme color. The wide form
scroller's top padding adds `kToolbarHeight` so scroll-to-top clears the bar.

## Flutter Changes

- `lib/screens/auth_screen.dart` — the only screen file touched. Five
  file-local layout consts with rationale comments (900 / 468 / 560 / 620 /
  140–220); new imports `dart:math`, `app_colors.dart`, `app_typography.dart`.
  No touch to state logic, listeners, `_submit`, dialogs, or `SsoButtons`.
- `lib/l10n/app_en.arb` + `app_es.arb` — new `authTagline` ("Plan less.
  Travel more." / "Planea menos. Viaja más."). Per-surface key rather than
  reusing home's `homeHeroTitle`: a shared string is only shared while the
  sites share a meaning (#464). Regen via `make flutter-gen-l10n`.
- `test/auth_split_pane_test.dart` — new; reuses the sso-order test's fake
  service/storage + `setSurfaceSize` pattern. Covers: wide pane full-height
  with scrim/gradient/tagline beside the 420 column and white-back /
  theme-globe bar slots; band pinned at the top on 420×1200 with both slots
  white; 800×600 and 360×450 render today's chrome with no panel; es sign-up
  at 360×690 with the band throws nothing; dark theme keeps the form on the
  dark scheme surface.

## Known Tradeoffs

- Crossing 900px swaps the Scaffold body's root (Row↔Column), reparenting the
  `Form`: controllers and provider error survive; transient field-validation
  messages and focus reset. Mid-resize only; accepted.
- The photo pane ends on a hard seam against the form pane — deliberately no
  `landingHeroBlend` dissolve; the committed-dark treatment ends at sign-in.

## Family pass (second wave)

The composition moved to one home: `lib/widgets/auth_photo_panel.dart` now
holds `AuthPhotoPanel` (the photo stack, verbatim from the sign-in screen),
the layout numbers (`kAuthWideBreakpoint`, `kAuthBandMinViewportHeight`,
`authFormPaneWidth`, `authBandHeight` — the clamp bounds stay private), and
`AuthPhotoBody`, the pane/band/nothing ladder for the gradient-bar screens.
The sign-in screen imports the pieces but keeps composing them itself: its
transparent bar's icon colors and extend-behind flag depend on the layout
decision, so its LayoutBuilder must wrap the whole Scaffold, while the
siblings' bars are layout-independent and `AuthPhotoBody` measures the body
box below them (band threshold therefore reads ~56px conservative there,
deliberately — the question is whether the form under the chrome breathes).
`reset_password_screen.dart` and `verify_email_screen.dart` wrap their
existing bodies in `AuthPhotoBody`; columns, bars, and logic untouched.
Tests: `test/auth_family_photo_test.dart`.

## Verification

`make flutter-analyze`, full `make flutter-test` (run
`auth_screen_sso_order_test.dart` first — it newly renders the band +
`Image.asset` at 420×1200; if it breaks, fix the implementation, never the
test), brand `check.sh` on the touched Dart files, CDP screenshots at
1440×900 / ~950×800 / 390×844 / 360×640 in both themes and both locales.
