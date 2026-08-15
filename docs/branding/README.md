# Anemos brand mark

An 8-point **wind rose** — άνεμος is Greek for wind, the thing every journey
rides on. Long cardinal points in the app's deep teal (`#00796B`/`#004D40`),
short intercardinal points in the heritage gold (`#E8C452`/`#B98B1E`), each
point split light/dark like a portolan chart. The old horse-in-horseshoe mark
retired with the Golden Tempo name; the chat agent persona **Ferdinand** keeps
the equine nod.

`mark.svg` is the icon and the **single source of truth** — `lockup.svg`
references it (`<image href="mark.svg">`) and adds the "Anemos" wordmark as
live Cinzel SemiBold text — a static w600 instance of the variable font,
subsetted (font declared *inside* the SVG, loaded from
`src/packages/flutter-app/assets/fonts/`). Cinzel has no true lowercase, so
the wordmark paints as small-caps "ANEMOS". Because of that external
reference + live text, always render via the pipeline below, never by loading
lockup.svg as a plain `<img>`.

`mark-light.svg` is the **reversed variant for teal fields** (the boot
splash): cardinal points recolored white/`#B2DFDB` (teal-100), gold
intercardinals and the hub unchanged. It duplicates mark.svg's point geometry
— a geometry change in one must be mirrored in the other (both headers say
so). Plate policy after the splash redesign: the **splash floats the bare
light mark** on the teal gradient — no white plate; **gradient app bars still
plate the dark mark** on a light `BrandBadge` (see
`lib/widgets/brand_logo.dart`).

## Type

Three faces, declared once in `flutter-app/lib/theme/app_typography.dart`
(`AppFonts`) and bundled as subsetted TTFs — never `google_fonts`, which prod
CSP blocks:

- **Cinzel** — the wordmark, and only the wordmark.
- **Marcellus** — headings and app-bar page titles. Roman inscriptional shapes
  like Cinzel, but with a true lowercase, so headings read engraved rather than
  shouted. It ships in its ONE weight (400): any style naming it must say
  `w400`, because asking for a weight the family lacks gets synthetic faux-bold
  on web.
- **Inter** — body, labels, buttons, and every number, including the big values
  in stat tiles (which opt out of the heading face explicitly).

Only Cinzel is baked into rasters (`anemos_logo.png`, `og-card.png`); a heading
face change needs no re-render and no `?v=` bump.

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
| render/mark.html | `flutter-app/web/favicon.png` | 64 |
| render/mark-light.html | `flutter-app/assets/images/anemos_mark_light.png` | 540 |
| render/mark-light.html | `flutter-app/web/splash/anemos_mark_light.png` (copy) | 540 |
| render/mark-light.html (shrunk) | `flutter-app/assets/splash/mark_light_4x.png` | 384 |
| render/splash-android12.html (768 mark in 1152 safe zone) | `flutter-app/assets/splash/mark_light_android12.png` | 1152 |
| render/icon84.html (84%, transparent) | `flutter-app/web/icons/Icon-192/512.png` | 384 / 1024 |
| render/maskable.html (64%, white) | `flutter-app/web/icons/Icon-maskable-192/512.png` | 384 / 1024 |
| render/lockup.html | `flutter-app/assets/images/anemos_logo.png` | 1024 |
| render/ogcard.html (teal gradient + tagline) | `flutter-app/web/og-card.png` | 1200×630 |
| ↳ flutter_native_splash (from the mark_light seeds) | iOS LaunchImage*, Android `splash.png`/`android12splash.png` (+night) | ladders |
| ↳ flutter_launcher_icons (from Icon-maskable-512) | iOS/Android/macOS/Windows app icons | ladders |

Historical gotcha this table exists to prevent: og-card and badge_4x were
missing from the old README's table, so they silently kept two-brands-ago art
(a metronome!) through two renames. If you add a brand asset, add its row.

Cache note: `/app/icons/*` is served `immutable` for a year (nginx) — when the
art changes, bump the `?v=N` query in `web/index.html`, `web/manifest.json`,
and `print_view_handler.go`.
