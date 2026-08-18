---
name: design-inspiration
description: Consult BEFORE creating, redesigning, restyling, or polishing ANY UI in the Flutter app — a new screen, widget, dialog, sheet, card, empty state, onboarding step, or landing/marketing surface, and any change to theme, color, typography, spacing, layout, elevation, imagery, or motion. Holds the project's visual reference library (screenshots of admired travel-product and luxury-travel editorial designs) plus the aesthetic direction distilled from them; look at the reference images, don't just read about them. ADD mode: when the owner names a site, screen, or design direction to capture into the library. Complements — never replaces — lib/theme tokens (values), the impeccable skill (process), and the brand-guidelines skill (conformance); this skill is taste. Not for backend, API, data-model, test, or other non-visual work.
---

# Design inspiration

What the app should FEEL like, held in two forms: the distilled aesthetic
direction below, and annotated reference screenshots in
`.claude/skills/design-inspiration/references/`. Consult before touching UI;
add to it when the owner shows you something worth keeping.

## Aesthetic direction

The target: a polished travel product with the calm of a luxury travel
journal — Airbnb/Hopper/Flighty product craft carrying Aman/Belmond/Cereal
editorial restraint. Aegean, not tropical. Engraved, not shouted.

- **Editorial type, quiet hierarchy.** Headings are Marcellus at its one
  weight (w400) — Roman inscriptional letterforms with a true lowercase, so
  headings read engraved rather than shouted. Below the headline line,
  hierarchy is weight not size, set in Inter — body, labels, and every
  number (Cinzel belongs to the wordmark alone). A design earns attention by
  making the space around the important thing quieter, not by making the
  thing bigger. A destination surface may open with the Amanzoe move: a
  letterspaced small-caps place eyebrow above the heading, prose held to a
  narrow centered measure.
- **Aegean palette.** One deep-teal spine (teal-700 seed; the
  teal-600→teal-900 gradient on brand fields), surfaces like sun-bleached
  plaster, heritage gold only where the wind-rose mark brings it. Every
  non-teal color is earned and means exactly one thing (semantic
  success/warning pairs, tool accents) — color is never decoration.
- **Photography-forward.** Heroes are full-bleed travel photography in the
  Santorini register (caldera blues, white walls) under the brandDark
  scrim — darkest lower-left where text and actions sit, opening to the
  photo upper-right. Text sits ON photos behind scrims; it does not share
  the row with them.
- **Restraint on purpose.** M3 surface tint is off everywhere; separation is
  an explicit color choice, never a side effect of elevation. Shadows offset
  downward — light from above, soft, never flat halos. The wind rose always
  floats bare: no plates, no containers around the mark.
- **Card-and-sheet vocabulary, comfortable density.** Cards at 12 radius,
  heroes and large containers at 20, spacing on the 4/8/12/16/24/32 scale,
  48px minimum touch height. The existing vocabulary is cards, bottom
  sheets, chips, and pills — extend it; don't invent a parallel pattern
  language.

## Modes

### CONSULT — before or while doing any design work

1. Internalize the aesthetic direction above.
2. Scan the reference index below and pick the 2–3 entries whose tags best
   match the surface at hand (list screen → `cards` + `density`; hero →
   `photography` + `landing`; …).
3. Read those images from `references/` — the Read tool renders them
   visually, so actually look.
4. Extract principles, not pixels: proportion, spacing rhythm, hierarchy
   moves, photo treatment — guided by each entry's Mimic/Ignore bullets.
5. Apply them WITHIN the app's tokens: color via `AppColors`/ColorScheme,
   type via `AppFonts`/textTheme, spacing via `AppSpacing`, radii via
   `AppRadius`, shadows via `AppShadows`. Nothing from a reference's palette
   or typefaces crosses over.
6. If the index is empty or nothing matches, design from the direction alone
   and say so — never skip the skill silently.

### ADD — capture a new reference

1. Get the image: a file the owner drops into the conversation, or capture
   the page they name headlessly (commands below). Crop to the region that
   matters — one idea per image. Verify the capture by Reading it: a bot
   wall, cookie banner, or blank paint is not a reference.
2. Normalize: JPEG quality 80, max 1600px wide, aim under 500KB
   (references are photographic — PNG blows the budget):

   ```bash
   CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
   REF=".claude/skills/design-inspiration/references"
   "$CHROME" --headless=new --disable-gpu --hide-scrollbars \
     --force-device-scale-factor=1 --window-size=1440,900 \
     --virtual-time-budget=10000 --timeout=20000 \
     --screenshot="$REF/raw.png" "<url>"
   sips -s format jpeg -s formatOptions 80 "$REF/raw.png" \
     --out "$REF/<source>--<subject>.jpg" && rm "$REF/raw.png"
   ```

   Tall editorial pages: `--window-size=1440,2400`, then trim trailing
   whitespace top-anchored via `sips -c <height> 1440 --cropOffset 0 0`.
   Mobile: `--window-size=390,844` plus an iPhone `--user-agent`. Use
   `--resampleWidth 1600` only on imported images wider than that — never
   upscale.
3. Name it `<source>--<subject>.jpg` — lowercase kebab in both halves, `--`
   as the separator so single dashes stay legal inside each half (e.g.
   `airbnb--listing-card.jpg`, `cereal-magazine--article-header.jpg`);
   append `--mobile` for a mobile-viewport capture. On a name collision,
   sharpen the subject rather than numbering.
4. Save into `references/` and append an index entry below in the entry
   format, with tags drawn ONLY from the vocabulary line.
5. If the reference teaches a principle the direction section doesn't
   already state, add one sentence there — distill, don't restate the entry.
6. Past ~30 references or ~10MB total, propose pruning the weakest or
   duplicative entries to the owner before adding more (delete superseded
   files in the same commit — git history keeps them).

## Reference index

Tag vocabulary (closed — extend only by editing this line):
`typography` `color` `cards` `density` `photography` `navigation`
`empty-state` `motion` `landing` `sheets`

Entry format:

```
### <source>--<subject>.jpg
- Source: <site> — <which page/state>, <URL>, captured YYYY-MM
- Tags: 2–4 from the vocabulary
- Mimic: 2–4 bullets — the composition/proportion/hierarchy moves to learn
- Ignore: what must NOT carry over (usually their palette, faces, trade dress)
```

### aman--home-hero.jpg
- Source: Aman — homepage hero (Amanzoe feature), https://www.aman.com, captured 2026-08
- Tags: photography, landing, density
- Mimic: full-bleed photo held INSIDE page margins so the plaster field frames it like a plate in a journal; hairline nav with a tiny letterspaced wordmark centered; acres of empty field above the photo — the emptiness is the luxury signal; muted natural palette lets the sea carry all the color.
- Ignore: near-black CTA styling and serif brand type; homepage-grade information density is not a product-screen move.

### aman--resort-detail.jpg
- Source: Aman — Amanzoe resort page (sub-nav + hero + intro + photo rail), https://www.aman.com/resorts/amanzoe, captured 2026-08
- Tags: photography, typography, landing
- Mimic: the detail-page opening sequence — section sub-nav bar, inset full-width aerial hero, then a letterspaced small-caps place eyebrow ("PORTO HELI, GREECE") over a serif title over a narrow-measure centered intro paragraph, then a photo rail; the place name is the FIRST text a destination page speaks.
- Ignore: all-caps nav links; beige-on-beige contrast levels (below product floors); serif body face.

### belmond--home-hero.jpg
- Source: Belmond — homepage hero, https://www.belmond.com, captured 2026-08
- Tags: photography, typography, navigation
- Mimic: type ON photography with nothing behind it — trust the image plus letterspacing (their wordmark floats on the pool the way our rose floats bare); top-down aerial angle turns pools into graphic color fields, very Aegean; nav is a quiet plaster bar with hairline separation, one floating pill as the sole overlay control.
- Ignore: wordmark-as-hero-title (Cinzel stays in chrome); the absence of CTA hierarchy — a product needs one.

### cereal--home-editorial.jpg
- Source: Cereal Magazine — archive index grid, https://readcereal.com, captured 2026-08
- Tags: typography, density, cards
- Mimic: gallery restraint — varied-aspect images on a calm cream field aligned to a strict grid, with tiny two-line captions (catalog number + title) that never compete with the image; nav treated as typography, not chrome; the ivory field is "sun-bleached plaster" in practice.
- Ignore: captionless obscurity (fine in a magazine, hostile in a product); monochrome-only palette; type sizes below accessibility floors.

### flighty--landing-hero.jpg
- Source: Flighty — landing hero, https://flighty.com, captured 2026-08
- Tags: landing, typography, cards, motion
- Mimic: one huge confident headline, a two-line subhead, a small credibility row, then straight into the product; floating notification cards that fade with distance from the device — depth via opacity, not shadow stacking; a single dark segmented pill grounding the composition; whitespace does the layout work.
- Ignore: Apple-style near-black display grotesque (we head in Marcellus w400); the yellow accent; device-frame-centric composition on a web-first product.

### hopper--landing.jpg
- Source: Hopper — homepage hero, https://hopper.com, captured 2026-08
- Tags: photography, navigation, landing
- Mimic: search anatomy over photography — segmented product tabs (icon + label) floating above one white pill search with labeled slots (Where/Dates/Guests) and a single round primary action; hero photo inset with rounded corners so the page, not the photo, owns the edges; a dusk photo keeps white chrome legible without heavy scrims.
- Ignore: brand blue and coral accents; "NEW" badge noise; the sponsored-card row below.

### wanderlog--landing.jpg
- Source: Wanderlog — landing with product shot, https://wanderlog.com, captured 2026-08
- Tags: landing, cards, density
- Mimic: itinerary list + map as ONE composition — numbered stops in the list are the same colored pins on the map, teaching the pairing at a glance (Anemos trip detail speaks this language); centered headline, one filled CTA, one text CTA — decisive hierarchy; the product screenshot framed as a soft card is the hero.
- Ignore: coral primary; playful logotype energy; map-pin clutter at real zoom levels.

### airbnb--search-cards.jpg
- Source: Airbnb — Santorini stay search results (card grid + map split), https://www.airbnb.com/s/Santorini--Greece/homes, captured 2026-08
- Tags: cards, density, navigation
- Mimic: photo-led card anatomy — the image owns the card top (radius ~12), the text block is four quiet rows (title+rating / meta / dates / price) where only the price carries weight; a chip row of filters as the entire secondary nav; list+map split where map price pills mirror card data; at most one badge, sitting ON the photo, top-left.
- Ignore: pink/red accents and heart iconography; their font stack; "Guest favorite" merchandising tone.

## Notes

- **Four layers, no turf wars.** This skill supplies TASTE (mood,
  references, composition); `src/packages/flutter-app/lib/theme/` supplies
  VALUES and is law; the `impeccable` skill supplies PROCESS; the
  `brand-guidelines` skill supplies CONFORMANCE (the enforceable rulebook
  + checklist). When impeccable triggers on the same prompt, run its
  process with these references as input. If a reference argues a token is
  wrong, propose a change to `lib/theme/` — never fork a value inline.
  Mechanical fixes inside an existing pattern may skip this skill's
  reference pass and go straight to brand-guidelines — say so.
- **Mimic feel, never pixel-copy.** No trade-dress cloning: never reproduce
  another product's identifiable layout, illustration, icon set, or
  copywriting. Learn the move; perform it in Anemos materials.
- **References are internal working material.** Never copy them into
  `assets/`, `web/`, or anything shipped; never reference them from app
  code. They exist only to be Read during design work.
- **Image hygiene.** JPEG, ≤1600px wide, <500KB target, soft cap ~30
  references / ~10MB. Every image has an index entry — an unindexed image
  is dead weight; annotate it or delete it.
