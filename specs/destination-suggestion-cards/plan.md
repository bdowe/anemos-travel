# Plan: Destination Suggestion Cards

> **HOW.** Translates `spec.md` into a file-level technical approach.

## Technical Approach

Client-only. The suggestion prompts already exist as a randomized pool shared
by two surfaces; this feature gives each prompt a bundled photo and renders the
agent screen's picks as photo cards instead of pills.

Three decisions carry the design:

1. **Bundled assets, not live photos.** The app has a Places photo proxy
   (`/api/v1/places/photo`), but it only serves refs the server itself recently
   emitted (`knownPhotoRefs`), so an empty state would have to run — and pay
   for — a Places search before it could show anything. Bundled WebP costs one
   cached request per shown card and works offline. Cost: ~460 KB of assets, of
   which a web visit fetches only the three drawn (~40 KB each), and the service
   worker cache is what makes repeat visits free. (This originally read "nginx
   already serves `/app/assets/` `immutable` for a year" — that header was
   removed on 2026-08-15, because Flutter does not content-hash asset filenames,
   so those URLs are stable while the bytes change.)
2. **Photo and prompt in one record.** See "Divergences" below.
3. **A dedicated card widget, not a fifth `PlaceCardData` factory.** See
   "Divergences" below.

## Go API Changes

None.

## Flutter Changes

`src/packages/flutter-app/`:

- **`lib/providers/suggestions_provider.dart`** — `suggestionPool` becomes a
  list of `SuggestionPrompt` records `(label, photo)` instead of bare label
  selectors. Pool ORDER IS API as before (tests pin picks by index; append at
  the tail). Adds `photoFor(prompt)`, which throws a slug-naming `StateError`
  rather than letting a missing photo degrade to a silent fallback box.
- **`lib/providers/destination_photos.dart`** — **GENERATED**; asset path +
  short credit per slug. Never hand-edit.
- **`lib/widgets/random_suggestions.dart`** — the builder now receives
  `List<ResolvedSuggestion>` (`text`, `asset`, `credit`) rather than
  `List<String>`. Label resolution stays inside this widget, so the
  "locale relabels without reshuffling" contract keeps one implementation.
- **`lib/widgets/destination_suggestion_card.dart`** — new.
  `DestinationSuggestionCard` (photo, credit overlay, two-line prompt) and
  `DestinationSuggestionRow` (LayoutBuilder + centered Wrap, owns the width
  math). Geometry constants are imported from `place_photo_card.dart`.
- **`lib/widgets/empty_state.dart`** — two strictly additive changes to a
  widget with ~45 call sites: a `content` slot between message and actions,
  and `icon` loosened to `IconData?`. Every existing caller still passes an
  icon, so both are source-compatible.
- **`lib/screens/agent_screen.dart`** — `_EmptyState` puts the cards in
  `content` and keeps only `NearMeChip` + the import button in `actions`;
  `icon: null`. `_SuggestionChip` deleted (dead).
- **`lib/screens/home_screen.dart`** — mechanical: `s` → `s.text`. The hero
  keeps chips (photo-on-photo otherwise).
- **`pubspec.yaml`** — `assets/images/destinations/` needs its own entry;
  Flutter's directory declaration is not recursive.

No model, service, provider-of-server-state, or `.g.dart` changes. No new
l10n strings — the card's label is the existing prompt, and the credit is
data, so `app_es.arb` is untouched.

## Assets

`scripts/fetch-destination-photos.py` generates everything: the twelve
600×288 WebPs, `assets/images/destinations/CREDITS.md`, and
`lib/providers/destination_photos.dart`. Sources are Wikimedia Commons files
pinned by exact title, each with a per-slug crop `focus` and `zoom` that were
tuned by looking at the rendered 200×96 card, not the source photo — at that
size a centre crop loses the Eiffel Tower and distant game on a savanna.

Same rule as the brand rasters (`docs/branding/README.md`): re-run the script,
never hand-edit the output. Generating the credits in the same pass as the
images is the point — attribution is a license obligation, and a hand-kept
credit list drifts the first time a photo is swapped.

**Permissive licenses only.** A crop is a derivative work, so a share-alike
source would put our file under share-alike too — an obligation we don't want
riding along in a commercial app's asset bundle. Sources are limited to CC0,
public domain and plain CC BY. This is enforced twice: `allowed_license()`
aborts the generator *before it writes anything* if any pinned source fails
(a half-generated set with one bad license is worse than no change), and a
test rejects a share-alike string in the generated table, which catches a
hand-edit the generator never sees.

The wider asset-provenance record lives in `assets/images/LICENSES.md`, added
here because this feature is what surfaced that `hero_santorini.jpg` had none.

## Divergences  ← per docs/zen.md, written down and pinned

**1. `suggestionPool` holds records, not two parallel lists.** The obvious
smaller change was a `suggestionImages` list indexed by pool position. That is
precisely the implicit-convention coupling the leg-dates arc cost us: it works
until someone appends a prompt and not an image, and then fails silently as a
fallback box. Pairing them in one record makes the omission a compile error.
Pinned by `test/suggestion_pool_assets_test.dart`.

**2. `DestinationSuggestionCard` is not a `PlaceCardData` factory.**
"Second implementation of anything? Stop." — so: `PlaceCardData` models live
search results (rating, price level, category accent, add-to-trip, network
photo URL). A suggestion card has none of those and is a way *into* a
conversation, not a result; a fifth factory would carry six unused fields plus
an asset/network branch through the chat's hot card path. What the two
genuinely share is chrome, so the geometry constants (`kPlaceCardWidth`,
`kPlaceCardHeight`, `kPlaceCardImageHeight`) are imported from
`place_photo_card.dart` rather than re-declared — the two card families cannot
drift in size — and the fallback and credit-overlay idioms are copied from the
proven ones there.

## Testing

- `test/suggestion_pool_assets_test.dart` (new) — the seam between the
  hand-written pool and the generated table: every prompt names a photo that
  exists, paths are unique and correctly located, credits are non-empty, every
  asset loads through the real `rootBundle` (so a missing pubspec entry fails
  here, not in the app) and is under 150 KB, and the table has no unused slugs.
- `test/agent_empty_state_suggestions_test.dart` (updated) — picks now render
  as `kSuggestionCount` cards in `content` with `actions` down to
  `[NearMeChip, OutlinedButton]` and `icon` null; each card carries ITS own
  destination's asset and a rendered credit; tapping still sends exactly the
  visible label; draw-once-per-mount and locale-relabel unchanged.
- `test/suggestion_pool_test.dart` (updated) — `pick(l10n)` → `pick.label(l10n)`.

## Rollout

No migration, no flag, no server deploy coupling. Reverting is a code revert;
the assets are inert once unreferenced.
