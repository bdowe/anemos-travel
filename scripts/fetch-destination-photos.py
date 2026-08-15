#!/usr/bin/env python3
"""Regenerate the chat empty-state destination photos.

Like the brand rasters (docs/branding/README.md, scripts/brand-render.sh),
these WebPs are GENERATED, never hand-edited: re-run this script instead of
touching the files. It also rewrites CREDITS.md from live Wikimedia metadata,
so the attribution shown in the app can never drift from what actually
shipped.

Every source is a Wikimedia Commons file pinned by exact title, under a
license that permits commercial use with attribution. Output is sized for
`DestinationSuggestionCard`'s 200x96 logical image slot at 3x DPR.

Usage:  python3 scripts/fetch-destination-photos.py [slug ...]
Needs:  Python 3.9+ and Pillow  (pip install Pillow)
"""
import html
import io
import json
import os
import re
import sys
import unicodedata
import urllib.parse
import urllib.request

try:
    from PIL import Image
except ImportError:  # pragma: no cover - developer tooling
    sys.exit("Pillow is required: pip install Pillow")

UA = "anemos-travel-asset-tool/1.0 (goldentempollc@gmail.com)"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(REPO, "src/packages/flutter-app")
DEST = os.path.join(APP, "assets/images/destinations")
DART = os.path.join(APP, "lib/providers/destination_photos.dart")

# The card renders a 200x96 logical slot; 3x covers the densest screens we
# ship to. Keep in sync with kPlaceCardWidth / kPlaceCardImageHeight.
OUT_W, OUT_H = 600, 288
QUALITY = 80

# slug -> (Commons file title, focus, zoom).
#
# `focus` is the 0..1 point the crop centres on and `zoom` (>= 1) tightens it
# before the aspect crop. Both exist because a centre crop of a wide source
# leaves the landmark unreadable at 200x96 — Paris's tower shrinks to a
# silhouette, Rome's arena loses its top. Every value here was set by looking
# at the generated card, not at the source photo.
SOURCES = {
    # Wide sunset skyline: zoom in or the Eiffel Tower is a speck.
    "paris": ("File:Eiffel Tower sunset skyline (Unsplash).jpg",
              (0.62, 0.55), 1.9),
    # Lift the crop so the top tier of the arena stays in frame.
    "rome": ("File:Colosseum in Rome-April 2007-1- copie 2B.jpg",
             (0.5, 0.34), 1.0),
    "tokyo": ("File:Tokyo Tower, Minato City.jpg", (0.5, 0.5), 1.0),
    "greece": ("File:1000 Three domes of Oia in Santorini Photo by Giles "
               "Laurent.jpg", (0.5, 0.5), 1.0),
    "lisbon": ("File:Trams in Lisbon -a.jpg", (0.5, 0.5), 1.0),
    "barcelona": ("File:La Boqueria.JPG", (0.5, 0.5), 1.0),
    "bangkok": ("File:Chinatown, Bangkok (5).jpg", (0.5, 0.5), 1.0),
    "amalfi": ("File:Positano (Italy) 03.jpg", (0.5, 0.5), 1.0),
    "newyork": ("File:Lower Manhattan from Jersey City November 2014 "
                "panorama 2.jpg", (0.5, 0.5), 1.0),
    "bali": ("File:Atuh Beach, Nusa Penida Bali.jpg", (0.5, 0.5), 1.0),
    "patagonia": ("File:Cuernos del Paine in Torres del Paine National "
                  "Park.jpg", (0.5, 0.5), 1.0),
    # Cheetahs, not the wide bush landscape the search ranked first: at card
    # size distant game is invisible and the card stops saying "safari".
    "kenya": ("File:2 Male Cheetahs of the Tano Bora (magnificent five), "
              "Maasai Mara - Flickr - . Ray in Manila.jpg", (0.5, 0.5), 1.0),
}


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=90) as r:
        return r.read()


def plain(value):
    """Commons ships extmetadata as HTML fragments; we want a credit line."""
    return html.unescape(re.sub(r"<[^>]+>", " ", value or "")).strip()


def metadata(titles):
    url = ("https://commons.wikimedia.org/w/api.php?action=query&titles="
           + urllib.parse.quote("|".join(titles))
           + "&prop=imageinfo&iiprop=url|extmetadata&iiurlwidth=%d"
           % (OUT_W * 3) + "&format=json")
    pages = json.loads(get(url))["query"]["pages"].values()
    out = {}
    for page in pages:
        info = page["imageinfo"][0]
        meta = info.get("extmetadata", {})
        out[page["title"]] = {
            "thumb": info["thumburl"],
            "page": info["descriptionurl"],
            "artist": re.sub(r"\s+", " ", plain(
                meta.get("Artist", {}).get("value"))),
            "license": plain(meta.get("LicenseShortName", {}).get("value")),
            "license_url": meta.get("LicenseUrl", {}).get("value", ""),
        }
    return out


def render(raw, focus, zoom=1.0):
    """Cover-crop to the card aspect around `focus`, then downscale.

    `zoom` > 1 first takes a tighter window (still anchored on `focus`), so a
    landmark can be enlarged without re-sourcing the photo.
    """
    im = Image.open(io.BytesIO(raw)).convert("RGB")
    target = OUT_W / OUT_H
    if im.width / im.height > target:          # too wide -> trim the sides
        cw, ch = int(round(im.height * target)), im.height
    else:                                      # too tall -> trim top/bottom
        cw, ch = im.width, int(round(im.width / target))
    if zoom > 1.0:
        cw, ch = max(1, int(cw / zoom)), max(1, int(ch / zoom))
    left = int(round((im.width - cw) * focus[0]))
    top = int(round((im.height - ch) * focus[1]))
    im = im.crop((left, top, left + cw, top + ch))
    if im.width < OUT_W:
        print("  ! %dpx-wide crop upscaled to %d — lower the zoom"
              % (im.width, OUT_W), file=sys.stderr)
    return im.resize((OUT_W, OUT_H), Image.LANCZOS)


def main():
    slugs = sys.argv[1:] or sorted(SOURCES)
    unknown = [s for s in slugs if s not in SOURCES]
    if unknown:
        sys.exit("unknown slug(s): %s" % ", ".join(unknown))

    os.makedirs(DEST, exist_ok=True)
    meta = metadata([SOURCES[s][0] for s in slugs])

    credits = {}
    for slug in slugs:
        title, focus, zoom = SOURCES[slug]
        info = meta[title]
        out = os.path.join(DEST, "%s.webp" % slug)
        render(get(info["thumb"]), focus, zoom).save(
            out, "WEBP", quality=QUALITY, method=6)
        credits[slug] = dict(info, title=title,
                             bytes=os.path.getsize(out))
        print("%-10s %6.1f KB  %s" % (
            slug, credits[slug]["bytes"] / 1024, info["license"]))

    if len(slugs) != len(SOURCES):
        print("\n(partial run — CREDITS.md and destination_photos.dart left "
              "untouched; re-run with no arguments to regenerate them)")
        return
    write_credits(credits)
    write_dart(credits)


def dart_string(value):
    return "'%s'" % value.replace("\\", "\\\\").replace("'", "\\'")


def short_author(artist):
    """Commons `Artist` is freeform HTML — real values include
    ". Ray in Manila", "Pedro Kummel pedrokummel" and "Jorge Franganillo from
    Barcelona, Spain". The card overlays ~30 characters of 9px text, so a raw
    value just ellipsizes and credits nobody. Trim it to a name for the
    overlay; CREDITS.md keeps the untouched string as the full record.
    """
    name = re.sub(r"\s+", " ", artist or "").strip(" .,-–")
    name = re.sub(r"\s+from\s+[^,]+(,.*)?$", "", name)   # "... from <place>"
    words = name.split(" ")
    if len(words) > 1:                                   # "Name name_handle"
        # Compare without diacritics: the handle for "Pedro Kümmel" is
        # "pedrokummel", which only matches once the umlaut is folded.
        def fold(text):
            stripped = unicodedata.normalize("NFKD", text)
            return "".join(c for c in stripped.lower()
                           if c.isalnum() and not unicodedata.combining(c))
        if fold(words[-1]) == fold("".join(words[:-1])):
            words = words[:-1]
    return " ".join(words)


def write_dart(credits):
    """Emit the credit line the card overlays, from the same run that wrote
    the files — so a swapped photo can never keep the old author's name."""
    lines = [
        "// GENERATED by scripts/fetch-destination-photos.py — do not edit.",
        "// Re-run that script to change a destination photo or its credit;",
        "// it rewrites the .webp files, CREDITS.md, and this table together,",
        "// which is what stops the on-card attribution from drifting away",
        "// from the image that actually shipped.",
        "",
        "/// A bundled destination photo: its asset path and the short credit",
        "/// rendered over it. Full attribution lives in",
        "/// assets/images/destinations/CREDITS.md.",
        "class DestinationPhoto {",
        "  final String asset;",
        "  final String credit;",
        "",
        "  const DestinationPhoto(this.asset, this.credit);",
        "}",
        "",
        "/// Keyed by the slug each suggestion prompt names in `suggestionPool`.",
        "const Map<String, DestinationPhoto> kDestinationPhotos = {",
    ]
    for slug in sorted(credits):
        c = credits[slug]
        credit = " / ".join(
            p for p in (short_author(c["artist"]), c["license"]) if p)
        lines += [
            "  %s: DestinationPhoto(" % dart_string(slug),
            "    %s," % dart_string(
                "assets/images/destinations/%s.webp" % slug),
            "    %s," % dart_string(credit),
            "  ),",
        ]
    lines += ["};", ""]
    with open(DART, "w") as f:
        f.write("\n".join(lines))
    print("wrote", DART)


def write_credits(credits):
    path = os.path.join(DEST, "CREDITS.md")
    lines = [
        "# Destination photo credits",
        "",
        "Generated by `scripts/fetch-destination-photos.py` — do not edit by",
        "hand. Every image is a crop of a Wikimedia Commons file, resized to",
        "%dx%d WebP for the chat empty-state suggestion cards." % (OUT_W, OUT_H),
        "",
        "The crops are derivative works, so each one stays under its source's",
        "license: the CC BY-SA files below remain CC BY-SA. The credit line is",
        "rendered over the card in-app; the full attribution is here.",
        "",
        "| File | Source | Author | License |",
        "| --- | --- | --- | --- |",
    ]
    for slug in sorted(credits):
        c = credits[slug]
        lic = ("[%s](%s)" % (c["license"], c["license_url"])
               if c["license_url"] else c["license"])
        lines.append("| `%s.webp` | [%s](%s) | %s | %s |" % (
            slug, c["title"][5:], c["page"], c["artist"] or "—", lic))
    lines.append("")
    with open(path, "w") as f:
        f.write("\n".join(lines))
    print("\nwrote", path)


if __name__ == "__main__":
    main()
