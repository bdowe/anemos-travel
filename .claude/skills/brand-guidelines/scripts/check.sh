#!/usr/bin/env bash
# Anemos brand lint — advisory conformance scan for Flutter UI code.
# Digest rules live in ../SKILL.md; the authority is
# docs/branding/brand-guidelines.html. Findings are advisory: fix each one
# or explain it in the PR body. Exit 0 always, unless --strict (exit 1 on
# any finding). Exit 2 if an explicitly named file does not exist.
#
# Usage:
#   check.sh                 # changed .dart files vs merge-base with main
#   check.sh path/a.dart …   # explicit files (relative or absolute)
#   check.sh --strict [...]
set -u

STRICT=0
FILES=()
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    *) FILES+=("$arg") ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git repo" >&2; exit 2; }
cd "$ROOT"
APP="src/packages/flutter-app"

EXPLICIT=1
if [ ${#FILES[@]} -eq 0 ]; then
  EXPLICIT=0
  BASE="$(git merge-base HEAD origin/main 2>/dev/null || git merge-base HEAD main 2>/dev/null || echo HEAD)"
  while IFS= read -r f; do FILES+=("$f"); done < <(
    { git diff --name-only --diff-filter=ACMR "$BASE"
      git diff --name-only --diff-filter=ACMR --cached
      git ls-files --others --exclude-standard
    } | sort -u
  )
fi

# Keep only hand-written Flutter UI sources. Explicit args are never
# dropped silently: outside-scope ones warn, missing ones exit 2.
SCAN=()
MISSING=0
for f in ${FILES[@]+"${FILES[@]}"}; do
  f="${f#"$ROOT"/}"   # absolute paths inside the repo normalize to relative
  case "$f" in
    lib/*.dart) f="$APP/$f" ;;
  esac
  case "$f" in
    "$APP"/lib/*.dart) ;;
    *)
      [ "$EXPLICIT" -eq 1 ] && echo "brand-check: skipped $f (not a $APP/lib .dart file)" >&2
      continue ;;
  esac
  case "$f" in
    *.g.dart|*/l10n/app_localizations*)
      [ "$EXPLICIT" -eq 1 ] && echo "brand-check: skipped $f (generated file)" >&2
      continue ;;
  esac
  if [ ! -f "$f" ]; then
    if [ "$EXPLICIT" -eq 1 ]; then
      echo "brand-check: missing file: $f" >&2
      MISSING=1
    fi
    continue
  fi
  case " ${SCAN[*]-} " in *" $f "*) continue ;; esac
  SCAN+=("$f")
done
[ "$MISSING" -eq 1 ] && exit 2

if [ ${#SCAN[@]} -eq 0 ]; then
  echo "brand-check: no Flutter lib/ .dart files to scan."
  exit 0
fi

COUNT=0
finding() { # file:line rule message
  echo "$1: [$2] $3"
  COUNT=$((COUNT + 1))
}

in_theme() { case "$1" in "$APP"/lib/theme/*) return 0 ;; *) return 1 ;; esac; }

for f in "${SCAN[@]}"; do
  rel="${f#"$APP"/}"

  # 1. google_fonts is banned outright (prod CSP blocks it; faces are bundled).
  while IFS=: read -r ln _; do
    finding "$f:$ln" "google-fonts" "google_fonts is banned — the two faces are bundled subsets (app_typography.dart)"
  done < <(grep -n "package:google_fonts" "$f" 2>/dev/null)

  # Everything below is about token discipline, so theme files are exempt.
  if ! in_theme "$f"; then

    # 2. fontFamily string literals — faces come from AppFonts / textTheme.
    #    No exemptions: brand_logo.dart used to carry the wordmark's own
    #    `fontFamily: 'Cinzel'` literal and was excused from this rule, but the
    #    wordmark has gone through AppFonts.wordmark since, so the exemption
    #    was excusing nothing. Rule 7 is what holds the wordmark's weight.
    while IFS=: read -r ln _; do
      finding "$f:$ln" "font-literal" "fontFamily string literal — use AppFonts.* or a textTheme style"
    done < <(grep -nE "fontFamily:[[:space:]]*[\"']" "$f" 2>/dev/null)

    # 3. Raw hex colors — new colors become AppColors tokens first.
    #    Sanctioned exceptions: the map canvas and the easter egg.
    case "$rel" in
      lib/widgets/app_map.dart|lib/widgets/rick_roll_overlay.dart) ;;
      *)
        while IFS=: read -r ln _; do
          finding "$f:$ln" "raw-hex" "raw Color(0x…) — add an AppColors token (or use the scheme)"
        done < <(grep -nE "Color\(0x" "$f" 2>/dev/null)
        ;;
    esac

    # 4. Material palette shades in widgets — the ramp lives in AppColors;
    #    screens read tokens or ColorScheme roles.
    while IFS=: read -r ln _; do
      finding "$f:$ln" "palette-shade" "Colors.<hue> shade in a widget — use AppColors / ColorScheme"
    done < <(grep -nE "Colors\.(teal|blue|lightBlue|red|green|lightGreen|amber|orange|deepOrange|pink|purple|deepPurple|cyan|indigo|lime|yellow|brown|blueGrey|grey)(\.shade|\[)" "$f" 2>/dev/null)

    # 5. Ad-hoc shadows — elevation comes from AppShadows (always offset down).
    while IFS=: read -r ln _; do
      finding "$f:$ln" "adhoc-shadow" "BoxShadow literal — use AppShadows.soft/brandCard/hero"
    done < <(grep -n "BoxShadow(" "$f" 2>/dev/null)

    # 6. Radius literals — 8/12/20 live in AppRadius. Covers the bare
    #    Radius.circular(...) forms too (BorderRadius.only/.vertical/.all);
    #    micro-radii under 6 (hairline elements the ladder has no stop for)
    #    are deliberately not flagged.
    while IFS=: read -r ln _; do
      finding "$f:$ln" "radius-literal" "Radius.circular(literal) — use AppRadius.sm/md/lg (8/12/20)"
    done < <(grep -nE "Radius\.circular\(([6-9]|[0-9][0-9])" "$f" 2>/dev/null)
  fi

  # 7. The One Weight Rule. Cormorant Garamond ships exactly TWO real files —
  #    500 (display) and 600 (wordmark) — so a style naming the family without
  #    saying which one it wants may ask for a weight that does not exist, and
  #    web answers with synthetic faux-bold, which smears a Garamond's stroke
  #    contrast. Each AppFonts constant therefore has ONE legal weight, and it
  #    must be stated at the call site. (Window: 2 lines back, 6 forward —
  #    named args order-free, and weight comments push it down.)
  #
  #    This used to read "Marcellus without an explicit w400", and it keys on
  #    the CONSTANT rather than the face's name — so when the display face
  #    followed the wordmark to Cormorant Garamond it did not quietly stop
  #    matching, it inverted: every one of the nine call sites became a
  #    finding, correctly weighted and reported as faux-bold risk. An advisory
  #    lint that is wrong about every site it names is read once and then
  #    ignored, which is the same end state as one that matches nothing.
  #    Keep the expected weight in this table, never in prose.
  for spec in "display:w500" "wordmark:w600"; do
    const="AppFonts.${spec%%:*}"
    weight="FontWeight.${spec##*:}"
    while IFS=: read -r ln _; do
      start=$((ln > 2 ? ln - 2 : 1))
      if ! sed -n "${start},$((ln + 6))p" "$f" | grep -q "$weight"; then
        finding "$f:$ln" "display-weight" "$const without $weight nearby — faux-bold risk"
      fi
    done < <(grep -n "$const" "$f" 2>/dev/null)
  done
done

echo "---"
if [ "$COUNT" -eq 0 ]; then
  echo "brand-check: clean (${#SCAN[@]} file(s))."
else
  echo "brand-check: $COUNT finding(s) across ${#SCAN[@]} file(s) — fix or explain each in the PR body."
fi

[ "$STRICT" -eq 1 ] && [ "$COUNT" -gt 0 ] && exit 1
exit 0
