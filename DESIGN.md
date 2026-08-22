---
name: Anemos
description: Travel planning with the calm of a luxury travel journal — Aegean, not tropical; engraved, not shouted.
colors:
  aegean-teal: "#00796B"
  harbor-light: "#00897B"
  harbor-dark: "#004D40"
  shallows-tint: "#E0F2F1"
  heritage-gold: "#E8C452"
  heritage-gold-deep: "#B98B1E"
  midnight-harbor: "#00231D"
  map-scrim: "rgba(0, 0, 0, 0.6)"
  paper-fill: "#FAFAFA"
typography:
  wordmark:
    fontFamily: "Cormorant Garamond, Georgia, serif"
    fontWeight: 600
    letterSpacing: "0.05em"
  headline:
    fontFamily: "Cormorant Garamond, Georgia, serif"
    fontSize: "34px"
    fontWeight: 500
    lineHeight: 1.2
  title:
    fontFamily: "Inter, system-ui, sans-serif"
    fontSize: "16px"
    fontWeight: 600
    lineHeight: 1.5
  body:
    fontFamily: "Inter, system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.43
  label:
    fontFamily: "Inter, system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 600
    lineHeight: 1.43
rounded:
  sm: "8px"
  md: "12px"
  lg: "20px"
  full: "999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "24px"
  xxl: "32px"
components:
  button-primary:
    backgroundColor: "{colors.aegean-teal}"
    textColor: "#FFFFFF"
    rounded: "{rounded.md}"
    padding: "12px 24px"
  button-primary-hover:
    backgroundColor: "#00695C"
  button-secondary:
    backgroundColor: "#FFFFFF"
    textColor: "{colors.aegean-teal}"
    rounded: "{rounded.sm}"
    padding: "12px 24px"
  card:
    backgroundColor: "#FFFFFF"
    rounded: "{rounded.md}"
    padding: "{spacing.lg}"
  input:
    backgroundColor: "{colors.paper-fill}"
    rounded: "{rounded.sm}"
  chip:
    rounded: "{rounded.full}"
---

# Design System: Anemos

> **Authority map (binding).** This file records the system; the repo's
> four-layer stack enforces it. `src/packages/flutter-app/lib/theme/` is law
> for values; `.claude/skills/brand-guidelines/` + `docs/branding/brand-guidelines.html`
> (v1.5) is law for rules and carries the pre-ship checklist and lint;
> `.claude/skills/design-inspiration/` holds the reference images. If this
> file and those ever disagree, fix this file.

## Overview

**Creative North Star: "The Aegean Journal"**

Anemos is a polished travel product that reads like a luxury travel journal:
the product craft of Airbnb, Hopper, and Flighty carrying the editorial
restraint of Aman, Belmond, and Cereal. Aegean, not tropical. Engraved, not
shouted. One deep-teal spine runs through everything; surfaces stay quiet like
sun-bleached plaster; photography of real places in real light does the
emotional work; and a design earns attention by making the space around the
important thing quieter, not by making the thing bigger.

The interface vocabulary is deliberately small — cards, bottom sheets, chips,
and pills at comfortable density — extended rather than added to. Restraint is
enforced, not aspirational: Material 3's surface tint is off everywhere,
separation between surfaces is always an explicit color choice, and every
non-teal color must earn its place by meaning exactly one thing. Confirmed
anti-references: generic AI gradients (purple-blue fields), gradient text,
glassmorphism as decoration, and the hero-metric template.

**Key Characteristics:**
- One teal spine; every other color earned and single-meaning
- Editorial serif headings at one weight; hierarchy below them is weight, not size
- Photography-forward, always behind a scrim when text sits on it
- Flat-calm surfaces, light from above, no tonal tint
- Card-and-sheet vocabulary, comfortable density, 48px touch floor

## Colors

One deep-teal spine seeded into every Material 3 **role**; the wind rose's own
blue carrying every **surface**; accents at chip-and-pin scale only.

Those are two different jobs and they are deliberately given to two different
hues. Teal is what you act on — the primary button, selection, the brand's
signature. Blue is what you act *on top of* — the page, the cards, the sheets.
Nothing is both.

### Primary
- **Aegean Teal** (#00796B): the brand seed (`AppColors.brand`, teal-700). The
  entire M3 `ColorScheme` in both light and dark derives from it. Identity and
  the primary action — nothing else.
- **Harbor Light** (#00897B) and **Harbor Dark** (#004D40): the deep ends of
  the teal ramp. Harbor Dark is the wordmark's ink on light chrome
  (`wordmarkInk` — dark mode takes the scheme primary), the anchor of
  `heroScrim` (0.88 alpha lower-left → 0.35 upper-right — the layer under any
  text on a photo), and the flat fallback field under the continue-trip
  hero's imagery. **`brandGradient` is no longer a sanctioned brand surface**
  (the de-gradient pass, 2026-08): chrome and hero cards are neutral
  surfaces whose brand is the wordmark's ink, the rose, typography, and
  imagery; the gradient survives only on the boot splash and the signed-out
  photo/guide panels until phase 2 flattens or retires each.
- **Shallows Tint** (#E0F2F1): the faint teal wash (`brandTint`) for selected
  and brand-touched surfaces at rest.

### Secondary
- **Heritage Gold** (#E8C452 / deep #B98B1E): lives in the wind-rose mark and
  nowhere else. Never text, never a button, never a UI accent.
- **Midnight Harbor** (≈#00231D, `landingCanvas`): the signed-out landing
  page's dark canvas — the ONE recorded exception (doc v1.2) to neutral
  surfaces. On it, every raised fill is a rung of the glass ladder (white at
  6/8/10/12%, hairline 14%) and every text tone a rung of the ink ladder
  (white at 35/60/70/85%). New landing surfaces pick a rung, never mint a
  fresh alpha. The exception ends at sign-in.

### Tertiary
- **Tool accents** (chip-and-pin scale only, one meaning each), brightness-
  aware like the status marks — light shade / dark shade: route deep-orange
  600/400 · flights blue 700/400 · stays pink 600/300 · events purple 600/300
  · ferries cyan 700/400 · local amber 800/400 · parking blue-grey 700/300.
  Dark takes the lightest rung that keeps the hue and clears 3:1 on the
  Aegean-night card (#153851); as fixed shades, flights, stays, events and
  parking sat at 1.7–2.7:1 there.
- **Semantic pairs, two registers**: translucent containers (green 15% /
  amber 20% alpha with shade-800/900 foregrounds) for pills on cards; solid
  brightness-aware marks (`upMark`/`degradedMark`/`downMark`, shade 400 dark /
  600–700 light) for status strips. "No data" deliberately has no token — it
  takes `outlineVariant` so absence can never read as a severity.

### Surfaces — the two Aegean canvases

Surfaces are **not** the seed-derived M3 neutrals. They are two authored
ladders, one hue at rising lightness, stated as `AppColors.aegeanNight` and
`AppColors.aegeanPaper` and selected by `AppColors.canvasFor(brightness)` —
the one place a theme mode becomes a set of surfaces.

The hue is **205°**, sitting between the mark's own petrol blue
(`markPetrol` #236684, 198°) and the rebrand's recorded Aegean-night canvas
(209°). It is the blue the logo is drawn in, not a blue chosen to go with it.

| role | dark (`aegeanNight`) | light (`aegeanPaper`) |
|---|---|---|
| `surfaceContainerLowest` | `#091620` | `#FFFFFF` |
| `surfaceDim` | `#0A1924` | `#CEDFEB` |
| **`surface`** (page, chrome) | **`#0C1F2C`** | **`#F6F9FB`** |
| `surfaceContainerLow` | `#0F2738` | `#EFF4F8` |
| `surfaceContainer` | `#123044` | `#E7F0F5` |
| **`surfaceContainerHigh`** (cards, menus) | **`#153851`** | **`#E0EBF2`** |
| `surfaceContainerHighest` | `#1A4361` | `#D9E6EF` |
| `surfaceBright` | `#205479` | `#F6F9FB` |
| `onSurface` | `#E3E9ED` | `#101B23` |
| `onSurfaceVariant` | `#C0CBD3` | `#364754` |
| `outline` / `outlineVariant` | `#7A8F9F` / `#405564` | `#697D8C` / `#BCC9D2` |

Light input fields take **Paper Fill** (`#F3F7F9`, `AppColors.paperFill`),
dark takes `surfaceContainerHighest`. **Map Scrim** (black 60%) stays the one
translucent layer for text and controls over satellite imagery.

Every tone is measured against both inks; the tightest pair in either canvas
is **4.88:1**, over the 4.5:1 body floor, and `app_theme_surfaces_test.dart`
re-measures all of them rather than trusting the ladder.

### Named Rules
**The Earned Color Rule.** Every non-teal color means exactly one thing and
appears at chip-and-pin scale, never as a field. Color is never decoration.
The Aegean canvases are the one thing this rule does not reach — a canvas is
what colour appears *on*, and its meaning is "surface", which is exactly one
thing.

**The Gold-in-the-Mark Rule.** Heritage Gold enters a screen only inside the
wind-rose mark. Anywhere else it is a finding. Unchanged by the blue: the
mark's `markBronze` (#D2A24C) is named in `AppColors` so this rule has
something to point at, never so a widget can reach for it.

**The Two Canvases Rule.** Every surface in the signed-in app comes from
`AppColors.canvasFor(brightness)` — dark is Aegean night, light is Aegean
paper, and they are the same design in two keys rather than one inverted
into the other. A widget that needs a surface takes a `ColorScheme` role; it
never mixes its own.

*This replaced the One Dark Exception Rule*, which read: "Midnight Harbor
exists only on the signed-out landing. Everywhere else, surfaces are the
neutral scheme and dark mode is the same build with brightness flipped." Two
of its three clauses are now false — surfaces are authored rather than
seed-derived, and dark is composed rather than flipped. Midnight Harbor is
still the landing's own canvas and still ends at sign-in, but it is now a
*green*-black sitting in front of a blue app, which is a real inconsistency
and an open follow-up, not a rule.

## Typography

**Display Font:** Cormorant Garamond 500 (with Georgia, serif)
**Body Font:** Inter (with system-ui, sans-serif)
**Wordmark Font:** Cormorant Garamond 600 (wordmark only, via `BrandWordmark`)

**Two faces, three jobs.** The display face and the wordmark are the same
family at two weights, so headings and the brand sit in one register rather
than in two that have to be reconciled. Headings read editorial rather than
shouted, over a working sans that does everything else. It was Marcellus
until the wordmark moved to Cormorant Garamond — Marcellus was picked as
inscriptional shapes in the *previous* wordmark's register, so it outlived
its reason and left a sturdy low-contrast heading beside a delicate
high-contrast wordmark, most visibly in the app bar.

### Hierarchy
- **Wordmark** (Cormorant Garamond 600, full-caps ANEMOS): only via
  `BrandWordmark`, with per-surface measured tracking (app bar 19px/1.0, auth
  26px/1.5, boot splash 22px/3.0). The face has a true lowercase, so the caps
  come from the string. Never retyped, never rasterized outside
  `brand-render.sh`.
- **Headline** (Cormorant Garamond w500, 44/39/34px, line-height 1.2): page
  and section headings; app-bar page titles at 28px, the pinned section
  register at 28px (`AppTextStyles.sectionHeading`). Sentence case, always.
  The sizes are an **optical correction, not a scale**: they are the sizes the
  previous display face used × **1.295** (`kDisplayOpticalScale`), which is
  Marcellus's 0.500 em x-height over Cormorant Garamond's 0.386. That lands
  every tier's lowercase where the design already had it, so the face change
  is not a resize of the app. Caps run ~15% ahead of that match — the accepted
  trade in a sentence-case ladder. **A slot that BORROWS an Inter number
  (`sectionHeading` takes `titleLarge`'s) must apply the factor itself**;
  omitting it is what made a trip's name recede at the top of its own page on
  the first render.
- **Title** (Inter w700 large / w600 medium-small, M3 sizes): card titles and
  row headers.
- **Body** (Inter w400, 14–16px): prose and transcripts.
- **Label** (Inter w600, 14px): buttons, chips, field labels — sentence case.
- **Numbers** (Inter, always): stat values opt out of the serif on purpose.

### Named Rules
**The One Weight Rule.** Cormorant Garamond ships exactly two real files —
**500** (display) and **600** (wordmark) — so each `AppFonts` constant has one
legal weight and every style naming the family states it explicitly, or the
web synthesizes faux-bold and smears the serif. It read "Marcellus ships in
exactly one weight" until the display face moved; the hazard is unchanged,
only the specifics. `check.sh` rule 7 enforces it per constant.

**The Weight-Not-Size Rule.** Below the headline line, hierarchy is built
with Inter's weight ladder (400/500/600/700), not with size steps.

**The One Eyebrow Rule.** Capitals belong to the wordmark and to ONE display
device: the letterspaced small-caps place eyebrow on destination surfaces
(the Amanzoe move). No other kickers or eyebrows exist.

## Layout

Spacing comes only from the 4/8/12/16/24/32 ladder (`AppSpacing.xs→xxl`);
values off the ladder are findings. Interactive rows and tiles keep a 48px
minimum height (`kMinTouchTarget`). Density is comfortable — a travel journal,
not a dashboard: generous padding inside cards (16px), 24px between sections,
whitespace doing the layout work the way the Flighty and Aman references do.

The app is one Material 3 build across web and mobile widths. Known
responsive seams are measured, not guessed: the auth screen goes split-pane at
≥900px and photo-band at ≥620px; the trip detail's side chat panel opens at
≥900px. Buttons pad 24px horizontal / 12px vertical. Heroes are full-bleed
photography inset within the page's own margins — the page, not the photo,
owns the edges.

## Elevation & Depth

A hybrid, with an explicit doctrine: **light from above, tint off
everywhere.** Real downward-offset drop shadows do the raising; Material 3's
surface tint is disabled on every themed surface (`surfaceTintColor:
transparent`), so separation is always an explicit color choice, never a side
effect of elevation. In dark mode the shadow is invisible, so an explicit
tonal step (`surfaceContainerHigh`) does the separating and the stronger
shadow only grounds the card.

### Shadow Vocabulary
- **Soft** (`0 3px 10px rgba(0,0,0,0.10)`): custom raised containers outside
  the Material `Card`.
- **Card theme** (elevation 3, shadow black 16% light / 50% dark): the
  standard card and menu treatment — the promoted trip heroes included,
  since the de-gradient pass made them ordinary cards. (The old brand-card
  Harbor Dark shadow is retired; its token is deprecated in place until the
  post-wave cleanup.)
- **Hero** (`0 6px 16px` Harbor Dark 40%): full-bleed photographic heroes
  (landing, the continue-trip card).

### Named Rules
**The Light-From-Above Rule.** Every shadow offsets downward. A zero-offset
colored halo is never ours.

**The No-Tint Rule.** Surface separation is a color someone chose, never an
implicit function of elevation.

## Shapes

Three radii and a circle: **8px** for inputs and small badges, **12px** for
cards, menus, and sections, **20px** for heroes and large containers; chips
are fully rounded. Nothing else. Borders are hairlines when they exist at all
(the landing's white-14% hairline; `outlineVariant` elsewhere). The wind-rose
mark always floats bare — no plate, tile, chip, or container behind it,
anywhere (plate policy v3); the only per-surface question is which cut: dark
mark on neutral or scrimmed fields (the app bar and nav rail included), light
mark on the boot splash's teal field.

## Components

### Buttons
- **Shape:** primary (Filled) at card radius (12px); secondary (Elevated) at
  input radius (8px).
- **Primary:** scheme primary (seeded from Aegean Teal) with white foreground;
  padding 24px horizontal, 12px vertical; Inter w600 label, sentence case.
- **Hover / Focus:** Material state layers; no glows, no halos.
- **Note:** M3 `copyWith` without an explicit color paints `onSurface`, not
  the button foreground — state colors are always set explicitly.

### Chips
- **Style:** fully-rounded (999px), Inter label, quiet fills — tint or tool
  accent at low alpha; on the landing canvas, the glass-ladder well (white 12%).
- **State:** selected takes the brand tint family; filter chip rows are the
  entire secondary navigation on list screens (the Airbnb move).

### Cards / Containers
- **Corner Style:** 12px.
- **Background:** surface (light) / `surfaceContainerHigh` (dark) — the
  promoted trip heroes included: a hero is a photo-led flat card (route-map
  band on top, serif title, Circle-style date square, state pills), promoted
  by imagery and typography rather than by a colored field.
- **Shadow Strategy:** card theme elevation 3, tint transparent (see
  Elevation).
- **Internal Padding:** 16px.
- **Photo-led cards** (place/hotel/event rails): the image owns the card top,
  text is a few quiet rows where only the key figure carries weight; fixed
  200×160 chat cards so images never reflow the transcript.

### Inputs / Fields
- **Style:** outlined at 8px radius, filled — Paper Fill (#FAFAFA) light,
  `surfaceContainerHighest` dark; on the landing canvas, the glass-ladder
  field rung (white 10%).
- **Focus:** scheme primary outline; no glow.

### Navigation
- **App bar:** flat `surface` in both themes under a hairline
  `outlineVariant` bottom border — the brand rides in the wordmark's ink
  (`wordmarkInk`: Harbor Dark light / scheme primary dark) and the dark-cut
  rose, never in a colored field. Page title in the display face at 25px,
  `BrandWordmark` as the persistent brand anchor (left-aligned, measured
  tracking), `onSurface` foreground.
- **Menus:** open below the bar (`position: under`), styled to match cards
  (12px radius, elevation 3, tint off) so every raised thing reads the same.
- **Mobile:** bottom sheets are the phone's overflow vocabulary; the wordmark
  yields to the page title when width demands it.

### The Wind Rose & Wordmark (signature)
`BrandLogo` (mark) and `BrandWordmark` (Cormorant Garamond 600 full-caps
ANEMOS) are components, not assets to recreate. Sizes shipped: **58 in chrome**
(nav rail and app bar), 28 default, 72 auth, 96 boot splash, 16 legible floor.
Clear space ≥25% of mark height. Rasters come only from
`scripts/brand-render.sh`.

**Every number in that ladder is a BOX, not the rose.** `anemos_mark.png` is a
540×540 canvas holding art that measures 515×410, so `BrandLogo.mark(size: n)`
paints a rose `0.759 n` tall — the chrome 58 paints 44, and the 16px "legible
floor" paints 12. Chrome moved 44→58 for exactly that reason: at 44 the rose
painted 33 and its rays read thin. 64 is the ceiling and it fails — a 64 box
paints a 48.6 rose, 61 wide, leaving 9.5px of clear space in the 80px rail
against the ≥25% minimum (11px). The real fix is to trim the padding out of
the asset so `size` means what it says at all four call sites; that re-tunes
auth and the splash too and rewrites this ladder, so it is a pass of its own.

### The Hero Scrim (signature)
Text sits on photography only over `heroScrim` — Harbor Dark densest in the
lower-left where text and actions live, opening to the photo upper-right — or
over `mapScrim` on satellite imagery. The landing hero may additionally
dissolve its photo into Midnight Harbor via `landingHeroBlend`, but that
gradient never carries text.

## Do's and Don'ts

### Do:
- **Do** build only with tokens — `AppColors`, `AppFonts`/textTheme,
  `AppSpacing`, `AppRadius`, `AppShadows`, `BrandLogo`/`BrandWordmark`; a
  value that isn't a token becomes one in `lib/theme/` first.
- **Do** keep photography real — real places in real light, credited in
  `CREDITS.md`/`LICENSES.md` — and put a scrim under any text on it.
- **Do** check both themes; the bar is `surface` in both — dark mode is the
  same build with brightness flipped, chrome included.
- **Do** state the weight on every style naming Cormorant Garamond — `w500`
  for `AppFonts.display`, `w600` for `AppFonts.wordmark` — and set numbers in
  Inter.
- **Do** run `.claude/skills/brand-guidelines/scripts/check.sh` on touched
  Dart files before shipping.

### Don't:
- **Don't** put a plate, tile, or container behind the wind rose, or redraw
  the mark "close enough".
- **Don't** use gradient text, colored glows, zero-offset halos, teal-tinted
  photos, purple-blue AI gradients, or glassmorphism as decoration.
- **Don't** add a third typeface (the app is down to two — Cormorant Garamond
  and Inter), load `google_fonts` (prod CSP blocks it), or let emoji stand in
  for icons.
- **Don't** use off-ladder spacing, radii outside 8/12/20/full, ad-hoc
  `BoxShadow`s, or raw hex in widgets (sanctioned exceptions: `app_map.dart`
  canvas, the easter egg).
- **Don't** ship kickers/eyebrows (except the one destination place eyebrow),
  Title Case Headings, section-number decoration, same-size icon-card grids
  as page structure, or the hero-metric template.
