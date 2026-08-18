---
name: brand-guidelines
description: >-
  Consult whenever an Anemos interface is CREATED, UPDATED, or REVIEWED — any
  screen, widget, dialog, sheet, card, chip, empty state, app bar, landing or
  web surface, email, print/PDF artifact, marketing image, social/OG card,
  app icon or splash screen, or any change to
  color, typography, spacing, radius, elevation, imagery, or motion. The
  enforceable digest of docs/branding/brand-guidelines.html: brand rules with
  exact token values, an anti-generic-AI-pattern guard, a pre-ship checklist,
  and scripts/check.sh to lint touched Dart files. Fourth layer of the design
  stack — design-inspiration is TASTE, lib/theme is VALUES, impeccable is
  PROCESS, this skill is CONFORMANCE. Not for backend, API, data-model, or
  test-only work.
---

# Anemos brand conformance

The authority is `docs/branding/brand-guidelines.html` (PDF twin beside it;
PR #474). This file is its enforceable digest — short enough to actually
hold while designing. If this digest, the doc, and `lib/theme/` ever
disagree, **the code tokens are law for values and the doc is law for
rules** — a number a token or `brand_logo.dart` constant carries is a
value (code wins); a spec only the doc states, like clear space, is a
rule (doc wins). Flag the divergence and fix the laggard in the same
PR — never silently pick a side.

Paths below are relative to `src/packages/flutter-app/` unless rooted.

## How to apply

1. **Creating or restyling?** Load `design-inspiration` first (taste:
   direction + reference images), then design within the rules below.
   Mechanical fixes inside an existing pattern may skip the reference
   pass — say so, which is design-inspiration's own escape hatch.
2. Build with tokens — `AppColors`, `AppFonts`/textTheme, `AppSpacing`,
   `AppRadius`, `AppShadows`, `BrandLogo`/`BrandWordmark`. A value that
   isn't a token yet becomes one in `lib/theme/` **first**, then gets used.
3. Before shipping UI, run the lint and walk the checklist at the bottom:

   ```bash
   .claude/skills/brand-guidelines/scripts/check.sh          # changed .dart files vs main
   .claude/skills/brand-guidelines/scripts/check.sh lib/screens/foo_screen.dart
   ```

   It is advisory (exit 0; `--strict` exits 1 on findings) — every finding
   is either fixed or explained in the PR body.
4. A rule that must break gets the break written into
   `docs/branding/brand-guidelines.html` (and the PDF regenerated — the
   one-liner is in its header comment), version-bumped, in the same PR.
   An unrecorded exception is drift, and drift is how two-brands-ago
   metronome art survived two renames.

## Color — one teal spine, everything else earned

- The entire M3 scheme is seeded from `AppColors.brand` **#00796B**
  (ramp: tint `#E0F2F1` · teal-100 `#B2DFDB` · light `#00897B` · brand
  `#00796B` · platform `#00695C` · dark `#004D40`; teal-100 and platform
  live in the SVGs/web shell, not `AppColors`). Both themes share the
  seed; the gradient app bar stays teal in dark mode by design.
- **Proportion**: surfaces neutral (warm, plaster-leaning); teal is
  identity + the primary action; tool accents and status colors appear at
  chip-and-pin scale, **never as fields**. ONE recorded exception (doc
  v1.2): the signed-out landing page commits to the dark
  `landingCanvas` family (`app_colors.dart` — canvas ≈#00231D, glass
  ladder 6/8/10/12/14%, ink ladder 35/60/70/85%). The exception ends at
  sign-in; new landing surfaces pick a ladder rung, never a fresh alpha.
- **Heritage gold `#E8C452`/`#B98B1E` lives in the mark and nowhere
  else** — never text, never a button, never a UI accent.
- Semantic colors come in two registers on purpose: translucent
  container pairs (`successContainer`…) for pills on cards, solid
  brightness-aware marks (`upMark(b)`…) for strips. "No data" takes
  `outlineVariant` — it deliberately has no token.
- Known open finding: `onWarningContainer` on its container is 2.52:1 —
  below AA for small text. Icon-weight only; small warning text takes the
  solid pair.
- **No raw hex in widgets.** The only sanctioned raw-hex sites outside
  `lib/theme/` are `app_map.dart` (`#0A0F1A` canvas) and
  `rick_roll_overlay.dart` (easter egg). Photos are never teal-tinted —
  `heroScrim`/`mapScrim` are the brand layers an image carries, plus one
  recorded dissolve: `landingHeroBlend` may end the landing hero photo
  into the canvas, but never sets text on a photo (still heroScrim's job).

## Type — three faces, three jobs

- **Cinzel 600** = the wordmark, and only the wordmark, and only via
  `BrandWordmark` (live text; small-caps ANEMOS; tracking is measured
  per surface — app bar 19/1.0, auth 26/1.5, the boot splash (web
  shell and in-app) 22/3.0 is the tuned outlier). Never retype it,
  never bake it — except the
  sanctioned rasters (og-card, lockup), which `scripts/brand-render.sh`
  renders; nothing else does.
- **Marcellus** = headings and app-bar page titles. It ships in ONE
  weight — every style naming it must say `w400` or web synthesizes
  faux-bold. Sentence case, always.
- **Inter** = body, labels, buttons, and **every number** (stat values
  opt out of the heading face on purpose). Below the headline line,
  hierarchy is **weight, not size**.
- Never `google_fonts` (prod CSP blocks it); never a fourth face; the
  bundled subsets are Latin-only — Greek strings fall back to system
  faces by design.

## Logo — the rose always floats bare (plate policy v3)

- **No plate, tile, chip, or container around the mark anywhere in the
  app.** The only question a surface may ask is *which cut*: dark
  `BrandLogo.mark` on neutral/scrimmed surfaces, `BrandLogo.markLight`
  on teal `brandGradient` fields. The three baked-plate exceptions
  (og-card, maskable icon, print header) are closed — don't add a fourth.
- Never recolor, stretch, rotate, or redraw; never hand-edit the rendered
  PNGs (`scripts/brand-render.sh` owns every raster); never load
  `lockup.svg` as a plain `<img>`.
- Sizes shipped today: 36 standard in chrome, 28 default, 72 auth,
  96 boot splash, legible floor 16 (favicon). The signed-out landing
  carries no in-page mark — its gradient app bar is the one brand
  carrier. Clear space ≥ 25% of mark height on all sides.
- The policy's home is `lib/widgets/brand_logo.dart` — re-litigate it
  there, not at a call site.

## Space, shape, elevation

- Spacing only from `AppSpacing` (4/8/12/16/24/32). Touch targets ≥ 48
  (`kMinTouchTarget`).
- Radii only from `AppRadius`: 8 inputs/badges, 12 cards/menus, 20
  heroes (chips fully round). Shadows only from `AppShadows` — all
  offset **downward** (light from above); a zero-offset colored halo is
  never ours.
- Cards: elevation 3 with `surfaceTintColor: Colors.transparent` in both
  modes — separation is an explicit color choice, never an implicit M3
  tint.

## Imagery & voice

- Real places in real light; no illustration, no stock-abstract. Text
  sits on photos only over `heroScrim` (brand surfaces) or `mapScrim`
  (satellite). New photography joins `CREDITS.md`/`LICENSES.md` or
  doesn't ship.
- Voice: sentence case everywhere — capitals belong to the wordmark and
  to ONE sanctioned display device, the letterspaced small-caps place
  eyebrow on destination surfaces (design-inspiration's Amanzoe move);
  short sentences, concrete nouns ("4 nights in Naxos"); no exclamation
  inflation; locals credited by name. Tagline: *Plan less. Travel more.*

## The generic-AI-pattern guard

These are the tells this skill exists to keep out — skill-owned review
heuristics, deliberately beyond what the doc codifies (the doc-is-law
contract covers brand rules; this list is the conformance layer's own).
Each is an instant finding in review:

- A plate/tile behind the wind rose, or the mark redrawn "close enough".
- Gradient text; colored glow or zero-offset halo shadows; glassmorphism
  as decoration.
- Faux-bold Marcellus (any Marcellus style without explicit `w400`).
- A fourth typeface, `google_fonts`, or numbers set in a serif.
- Emoji or unicode glyphs standing in for icons.
- Kickers/eyebrows above headings — with ONE exception: the sanctioned
  letterspaced place eyebrow on destination surfaces (the Amanzoe move
  in design-inspiration). Section numbers as decoration; Title Case
  Headings.
- Same-size icon-card grids as page structure; the hero-metric template
  (big number, small label, accent).
- Off-scale magic values: spacing not on the 4/8/12/16/24/32 ladder,
  radii other than 8/12/20/full, ad-hoc `BoxShadow`s.
- Teal-tinted photos, purple-blue "AI gradients", or any hue used as a
  large field that isn't the brand gradient (one recorded exception:
  `landingCanvas` on the signed-out landing — doc v1.2).
- M3 defaults where the theme already decided: surface tint, default
  card shadows, `ColorScheme` roles bypassed by raw `Colors.*`.

## Pre-ship checklist

- [ ] Every color, font, spacing, radius, and shadow traces to a token
      (or added one in `lib/theme/` in this PR).
- [ ] `scripts/check.sh` run on touched files; each finding fixed or
      explained in the PR body.
- [ ] Mark/wordmark (if present): right cut for the field, no plate,
      `BrandWordmark`/`BrandLogo` used — not re-created.
- [ ] Marcellus styles all state `w400`; numbers are Inter; labels are
      sentence case.
- [ ] Text over any photo has a scrim under it.
- [ ] Both themes checked — the change reads correctly in light AND dark
      (the gradient bar staying teal is correct, not a bug).
- [ ] Nothing from the generic-AI guard above crept in.
- [ ] If a guideline rule changed: doc + PDF updated and version-bumped
      in this PR.

## Layer map (no turf wars)

| Layer | Home | Owns |
|---|---|---|
| Taste | `.claude/skills/design-inspiration/` | direction, reference images, composition moves |
| Values | `lib/theme/` (+ `lib/widgets/brand_logo.dart`) | the actual tokens — law |
| Process | `impeccable` skill (+ its design hook) | build/verify craft floor |
| Conformance | this skill + `docs/branding/brand-guidelines.html` | the brand rulebook and its checklist |

When `impeccable` runs on the same task, run its process with this
rulebook as input; where its generic defaults and this brand disagree,
**the brand wins**. Example: brandDark-tinted `AppShadows` are
sanctioned — the convention is on record in `.impeccable/config.json`
(one value ignored so far); when impeccable's detector flags another
spelling of a real `AppShadows` token, add that exact value to the
ignore list with the token as the reason rather than changing the
design.
