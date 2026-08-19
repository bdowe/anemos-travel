# Anemos brand mark

The **Waypoint Thread rose** — an 8-point **wind rose** (άνεμος is Greek for
wind, the thing every journey rides on) in sun-bronze, each point split
light/dark (`#D2A24C` light halves / `#8B6D3A` dark), threaded west→northeast
by an azure route line (`#3B9CC4` over `#20578B`) with a waypoint dot: **chat
in, trip out**. Meltemi palette. It is an organic vector drawing, not a
polygon recipe — edit it in a vector tool, not by hand-computing points.
Installed 2026-08, replacing the geometric teal/gold rose. The old
horse-in-horseshoe mark retired with the Golden Tempo name; the chat agent
persona **Ferdinand** keeps the equine nod. `mark-bezel-backup.svg` is the
approved alternate take on this rose (bezel ring concept) — unshipped, kept
as-is.

`mark.svg` is the icon and the **single source of truth** — `lockup.svg`
references it (`<image href="mark.svg">`) and adds the "ANEMOS" wordmark as
live Cormorant Garamond SemiBold text — a static w600 instance of the
variable font, subsetted (font declared *inside* the SVG, loaded from
`src/packages/flutter-app/assets/fonts/`). Cormorant Garamond HAS a true
lowercase; the approved wordmark is full caps, so the caps come from the
string itself. Because of that external reference + live text, always render
via the pipeline below, never by loading lockup.svg as a plain `<img>`.

`mark-light.svg` is the **reversed variant for teal fields** (the boot
splash): the route thread is recolored white / pale azure (`#D6ECF5`) — the
dark mark's azure thread would vanish on the teal gradient — while the
bronze rose is shared with mark.svg unchanged. It duplicates mark.svg's
geometry — a geometry change in one must be mirrored in the other (both
headers say so).

**Plate policy (v3): the rose always floats bare.** No plate is drawn anywhere
in the app. The only question a surface asks is which cut it needs: neutral
page surfaces and scrimmed imagery take the dark `mark`; the teal
`brandGradient` fields — the splash **and the gradient app bar** — take
`mark-light`, where the dark artwork's azure thread would vanish against the
teal. v2 kept a white plate on gradient app bars; it was retired because that
gradient does not change with theme, so the plate stayed white in dark mode
and became the brightest object on the screen. The policy is stated in
`lib/widgets/brand_logo.dart` — re-litigate it there.

Two artifacts outside the app keep a baked-in plate on purpose: `web/og-card.png`
(lands on arbitrary social backgrounds) and `web/icons/Icon-maskable-512.png`
(the maskable spec requires an opaque field). The print packet's header keeps
one too — see `print_view_handler.go`.

## Type

Three faces, declared once in `flutter-app/lib/theme/app_typography.dart`
(`AppFonts`) and bundled as subsetted TTFs — never `google_fonts`, which prod
CSP blocks:

- **Cormorant Garamond** — the wordmark, and only the wordmark: full caps
  "ANEMOS" at w600 (a static instance of the variable font, Latin-subsetted;
  Greek falls back to system faces by design). The caps come from the string
  (`AppInfo.name.toUpperCase()` in `BrandWordmark`), never from
  `text-transform` alone — the face has a true lowercase.
- **Marcellus** — headings and app-bar page titles. Roman inscriptional
  shapes in the same register as the wordmark's caps, but with a true
  lowercase, so headings read engraved rather than shouted. It ships in its
  ONE weight (400): any style naming it must say `w400`, because asking for a
  weight the family lacks gets synthetic faux-bold on web.
- **Inter** — body, labels, buttons, and every number, including the big values
  in stat tiles (which opt out of the heading face explicitly).

Only the wordmark face is baked into rasters (`anemos_logo.png`,
`og-card.png`); a heading face change needs no re-render and no `?v=` bump.

**Stale, awaiting a follow-up refresh:** `brand-guidelines.html` and
`anemos-brand-guidelines.pdf` still describe the previous identity (the
geometric teal/gold rose and the Cinzel wordmark — which is why the Cinzel
font files remain in `assets/fonts/`). Treat this README as current.

## Rendering pipeline (committed — do not run rasterizers ad hoc)

```
./scripts/brand-render.sh                                # repo root
cd src/packages/flutter-app
dart run flutter_native_splash:create                    # native launch screens
dart run flutter_launcher_icons                          # all app icons
```

`brand-render.sh` drives headless Chrome (transparent screenshots) + `sips`
through the harnesses in `docs/branding/render/*.html`. **Every raster asset
below is generated — edit the SVGs or harnesses, never the PNGs.**

| Rendered via | File | Size |
|---|---|---|
| render/mark.html | `flutter-app/assets/images/anemos_mark.png` | 540 |
| render/favicon.html (125% crop → rose ~95%) | `flutter-app/web/favicon.png` | 64 |
| render/mark-light.html | `flutter-app/assets/images/anemos_mark_light.png` | 540 |
| render/mark-light.html | `flutter-app/web/splash/anemos_mark_light.png` (copy) | 540 |
| render/mark-light.html (shrunk, 4× the 128dp splash mark) | `flutter-app/assets/splash/mark_light_4x.png` | 512 |
| render/splash-android12.html (768 mark in 1152 safe zone) | `flutter-app/assets/splash/mark_light_android12.png` | 1152 |
| render/icon84.html (110% → rose at 84%, transparent) | `flutter-app/web/icons/Icon-192/512.png` | 384 / 1024 |
| render/maskable.html (69% → ink inside the 80% safe circle, white) | `flutter-app/web/icons/Icon-maskable-192/512.png` | 384 / 1024 |
| render/lockup.html | `flutter-app/assets/images/anemos_logo.png` | 1024 |
| render/ogcard.html (teal gradient + tagline) | `flutter-app/web/og-card.png` | 1200×630 |
| ↳ flutter_native_splash (from the mark_light seeds) | iOS LaunchImage*, Android `splash.png`/`android12splash.png` (+night) | ladders |
| ↳ flutter_launcher_icons (from Icon-maskable-512) | iOS/Android/macOS/Windows app icons | ladders |

Historical gotcha this table exists to prevent: og-card and badge_4x were
missing from the old README's table, so they silently kept two-brands-ago art
(a metronome!) through two renames. If you add a brand asset, add its row.

**Reading the crop percentages.** `mark.svg`'s solid bronze rose is 76% of its
own square artboard; the remaining 24% belongs to the route thread's hairline
tails, which antialias to nothing below ~48px. So a percentage here is
ambiguous unless it says what it measures, and the icon harnesses used to
measure the artboard — which is why they shipped a rose at 64% (PWA) and 48.6%
(maskable) while their names claimed 84% and 64%. They now state the number
they actually control. Two rules fall out of this:

- **Unmasked surfaces** (favicon, PWA icon) size to the *rose* and let the
  thread's tails bleed off the frame. Nothing legible is lost.
- **Masked surfaces** (maskable, Android 12 splash) size to the ink's furthest
  *radius* from centre, not its bounding-box width — the tails leave the hub
  diagonally, so they sit near the corners where a circular mask cuts. Measured
  on the art, that radius is `0.571 × the mark's drawn width`.

Cache note: `/app/icons/*` is served `no-cache` (nginx), so a changed icon
propagates on the next load without help. It used to be `immutable` for a year,
which is why the `?v=N` query exists in `web/index.html`, `web/manifest.json`
and `print_view_handler.go` — those are now belt-and-braces rather than the
mechanism, and are still worth bumping for anything a browser may have cached
from before 2026-08-15. (The `immutable` header was removed because Flutter
does not content-hash these filenames; see
`dockerize/deployment/nginx/snippets/app-locations.conf`.)

"Propagates on the next load without help" holds only for objects the CDN
stored **after** 2026-08-15. A stored response keeps the freshness lifetime it
was stored with, so anything Cloudflare cached under the old `immutable` header
sits there until 2027 whatever the origin now sends — correcting a header never
evicts. `scripts/verify-edge-parity.sh` is what catches that; a purge is what
fixes it (runbook in `dockerize/production/README.md`).
