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
    fontFamily: "Cinzel, Georgia, serif"
    fontWeight: 600
    letterSpacing: "0.05em"
  headline:
    fontFamily: "Marcellus, Georgia, serif"
    fontSize: "26px"
    fontWeight: 400
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
> (v1.2) is law for rules and carries the pre-ship checklist and lint;
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

One deep-teal spine seeded into the whole Material 3 scheme; warm neutral
surfaces; accents at chip-and-pin scale only.

### Primary
- **Aegean Teal** (#00796B): the brand seed (`AppColors.brand`, teal-700). The
  entire M3 `ColorScheme` in both light and dark derives from it. Identity and
  the primary action — nothing else.
- **Harbor Light** (#00897B) and **Harbor Dark** (#004D40): the ends of
  `brandGradient` (top-left → bottom-right), the one sanctioned teal field —
  the app bar and brand hero cards. The gradient bar stays teal in dark mode
  by design. Harbor Dark also anchors `heroScrim` (0.88 alpha lower-left →
  0.35 upper-right) — the layer under any text on a photo.
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
- **Tool accents** (chip-and-pin scale only, one meaning each): route
  deep-orange 600 · flights blue 700 · stays pink 600 · events purple 600 ·
  ferries cyan 700 · local amber 800 · parking blue-grey 700.
- **Semantic pairs, two registers**: translucent containers (green 15% /
  amber 20% alpha with shade-800/900 foregrounds) for pills on cards; solid
  brightness-aware marks (`upMark`/`degradedMark`/`downMark`, shade 400 dark /
  600–700 light) for status strips. "No data" deliberately has no token — it
  takes `outlineVariant` so absence can never read as a severity.

### Neutral
- Surfaces are the seed-derived M3 neutrals — warm, plaster-leaning; light
  input fields take **Paper Fill** (#FAFAFA), dark takes
  `surfaceContainerHighest`.
- **Map Scrim** (black 60%): the one translucent layer for text and controls
  over satellite imagery.

### Named Rules
**The Earned Color Rule.** Every non-teal color means exactly one thing and
appears at chip-and-pin scale, never as a field. Color is never decoration.

**The Gold-in-the-Mark Rule.** Heritage Gold enters a screen only inside the
wind-rose mark. Anywhere else it is a finding.

**The One Dark Exception Rule.** Midnight Harbor exists only on the signed-out
landing. Everywhere else, surfaces are the neutral scheme and dark mode is the
same build with brightness flipped.

## Typography

**Display Font:** Marcellus (with Georgia, serif)
**Body Font:** Inter (with system-ui, sans-serif)
**Wordmark Font:** Cinzel 600 (wordmark only, via `BrandWordmark`)

**Character:** Roman inscriptional letterforms carrying the register of the
Cinzel wordmark, but with a true lowercase — headings read engraved rather
than shouted, over a working sans that does everything else.

### Hierarchy
- **Wordmark** (Cinzel 600, small-caps ANEMOS): only via `BrandWordmark`, with
  per-surface measured tracking (app bar 19px/1.0, auth 26px/1.5, boot splash
  22px/3.0). Never retyped, never rasterized outside `brand-render.sh`.
- **Headline** (Marcellus w400, 34/30/26px, line-height 1.2): page and section
  headings, app-bar titles. Sentence case, always. Sizes step up 2px over the
  M3 defaults to match Inter's x-height optically.
- **Title** (Inter w700 large / w600 medium-small, M3 sizes): card titles and
  row headers.
- **Body** (Inter w400, 14–16px): prose and transcripts.
- **Label** (Inter w600, 14px): buttons, chips, field labels — sentence case.
- **Numbers** (Inter, always): stat values opt out of the serif on purpose.

### Named Rules
**The One Weight Rule.** Marcellus ships in exactly one weight; every style
naming it states `w400` explicitly, or the web synthesizes faux-bold and
smears the serif.

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
  standard card and menu treatment.
- **Brand card** (`0 4px 10px` Harbor Dark 30%): under brand-gradient cards —
  hero strips, recent/live trip cards.
- **Hero** (`0 6px 16px` Harbor Dark 40%): full-bleed landing heroes.

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
mark on neutral or scrimmed fields, light mark on teal gradient fields.

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
- **Background:** surface (light) / `surfaceContainerHigh` (dark); brand hero
  cards take `brandGradient`.
- **Shadow Strategy:** card theme elevation 3, tint transparent (see
  Elevation); brand cards take the Harbor Dark shadow.
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
- **App bar:** the teal `brandGradient` in both themes, centered title in
  Marcellus, `BrandWordmark` as the persistent brand anchor (left-aligned,
  measured tracking). White foreground throughout.
- **Menus:** open below the bar (`position: under`), styled to match cards
  (12px radius, elevation 3, tint off) so every raised thing reads the same.
- **Mobile:** bottom sheets are the phone's overflow vocabulary; the wordmark
  yields to the page title when width demands it.

### The Wind Rose & Wordmark (signature)
`BrandLogo` (mark) and `BrandWordmark` (Cinzel small-caps ANEMOS) are
components, not assets to recreate. Sizes shipped: 36 in chrome, 28 default,
72 auth, 96 boot splash, 16 legible floor. Clear space ≥25% of mark height.
Rasters come only from `scripts/brand-render.sh`.

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
- **Do** check both themes; the gradient bar staying teal in dark is correct.
- **Do** state `w400` on every Marcellus style and set numbers in Inter.
- **Do** run `.claude/skills/brand-guidelines/scripts/check.sh` on touched
  Dart files before shipping.

### Don't:
- **Don't** put a plate, tile, or container behind the wind rose, or redraw
  the mark "close enough".
- **Don't** use gradient text, colored glows, zero-offset halos, teal-tinted
  photos, purple-blue AI gradients, or glassmorphism as decoration.
- **Don't** add a fourth typeface, load `google_fonts` (prod CSP blocks it),
  or let emoji stand in for icons.
- **Don't** use off-ladder spacing, radii outside 8/12/20/full, ad-hoc
  `BoxShadow`s, or raw hex in widgets (sanctioned exceptions: `app_map.dart`
  canvas, the easter egg).
- **Don't** ship kickers/eyebrows (except the one destination place eyebrow),
  Title Case Headings, section-number decoration, same-size icon-card grids
  as page structure, or the hero-metric template.
