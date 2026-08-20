#!/usr/bin/env bash
# Render every brand raster asset from docs/branding/{mark,lockup}.svg via
# headless Chrome + sips (no extra dependencies; macOS).
#
# Usage: ./scripts/brand-render.sh
# Re-run after editing the SVGs or the harnesses in docs/branding/render/,
# then: (flutter-app) dart run flutter_native_splash:create
#       (flutter-app) dart run flutter_launcher_icons
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BR="$ROOT/docs/branding"
APP="$ROOT/src/packages/flutter-app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || { echo "Chrome not found at $CHROME" >&2; exit 1; }

# render <harness.html> <WxH> <out.png>
render() {
  "$CHROME" --headless=new --disable-gpu --allow-file-access-from-files \
    --default-background-color=00000000 --hide-scrollbars \
    --force-device-scale-factor=1 --window-size="$2" \
    --screenshot="$3" "file://$BR/render/$1" >/dev/null 2>&1
}

# shrink <in> <size> <out>  (square resample, preserves alpha)
shrink() { sips -z "$2" "$2" "$1" --out "$3" >/dev/null; }

# A plain shrink of the master, no crop harness: the Threaded Bezel's ink is
# already 94% of its artboard, so a favicon rendered straight from it is
# effectively full-bleed. (The bare-rose mark needed a 125% crop harness here
# to reach the same place — it wasted 24% of a 16px icon on its own margin.)
echo "· mark (1080 master) + favicon"
render mark.html 1080,1080 "$TMP/mark1080.png"
shrink "$TMP/mark1080.png" 540 "$APP/assets/images/anemos_mark.png"
shrink "$TMP/mark1080.png" 64 "$APP/web/favicon.png"

echo "· mark-light (1080 master)"
render mark-light.html 1080,1080 "$TMP/marklight1080.png"
shrink "$TMP/marklight1080.png" 540 "$APP/assets/images/anemos_mark_light.png"
mkdir -p "$APP/web/splash"
cp "$APP/assets/images/anemos_mark_light.png" "$APP/web/splash/anemos_mark_light.png"

# 512 = 4x the 128dp splash mark (splash_screen.dart / index.html). The
# android12 seed is NOT derived from it — Android pins that icon's size to its
# own circular safe zone, so it stays put when the in-app mark moves.
echo "· native splash seeds (light mark)"
mkdir -p "$APP/assets/splash"
shrink "$TMP/marklight1080.png" 512 "$APP/assets/splash/mark_light_4x.png"
render splash-android12.html 1152,1152 "$APP/assets/splash/mark_light_android12.png"

echo "· PWA icons (ink at 84%)"
render icon84.html 1024,1024 "$APP/web/icons/Icon-512.png"
shrink "$APP/web/icons/Icon-512.png" 384 "$APP/web/icons/Icon-192.png"

echo "· PWA maskable icons (ink radius at the 80% safe circle, on white)"
render maskable.html 1024,1024 "$APP/web/icons/Icon-maskable-512.png"
shrink "$APP/web/icons/Icon-maskable-512.png" 384 "$APP/web/icons/Icon-maskable-192.png"

echo "· lockup"
render lockup.html 1024,1024 "$APP/assets/images/anemos_logo.png"

echo "· og card"
render ogcard.html 1200,630 "$APP/web/og-card.png"

echo "done — rendered into $APP"
