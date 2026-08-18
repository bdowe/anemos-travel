import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import 'destination_photos.dart';

/// One entry in [suggestionPool]: what the prompt says, and which destination
/// photo stands for it.
///
/// The two travel together deliberately. A parallel `suggestionImages` list
/// indexed by pool position would work right up until someone appended a
/// prompt and not an image — the implicit-convention coupling `docs/zen.md`
/// says this repo has already paid for once. Here a prompt without a photo
/// does not compile.
typedef SuggestionPrompt = ({
  /// Resolves the localized label at render time.
  String Function(AppLocalizations) label,

  /// Key into [kDestinationPhotos], which
  /// `scripts/fetch-destination-photos.py` generates alongside the images
  /// themselves.
  String photo,
});

/// Shared pool of one-tap trip prompts for the agent chat's empty state and
/// the home hero card. Selectors, not strings: WHICH prompts show is
/// locale-independent; WHAT they say resolves at render time, so a locale
/// switch relabels the same picks without reshuffling. Every label is BOTH
/// what the traveler reads and what gets sent (see `DestinationSuggestionCard`
/// and the home hero's chips).
/// ORDER IS API: the first three are the legacy trio; tests pin picks by
/// pool index, so append new prompts at the tail and never reorder.
final List<SuggestionPrompt> suggestionPool = [
  (label: (l) => l.suggestionParis, photo: 'paris'),
  (label: (l) => l.suggestionRome, photo: 'rome'),
  (label: (l) => l.suggestionTokyo, photo: 'tokyo'),
  (label: (l) => l.suggestionGreece, photo: 'greece'),
  (label: (l) => l.suggestionLisbon, photo: 'lisbon'),
  (label: (l) => l.suggestionBarcelona, photo: 'barcelona'),
  (label: (l) => l.suggestionBangkok, photo: 'bangkok'),
  (label: (l) => l.suggestionAmalfi, photo: 'amalfi'),
  (label: (l) => l.suggestionNewYork, photo: 'newyork'),
  (label: (l) => l.suggestionBali, photo: 'bali'),
  (label: (l) => l.suggestionPatagonia, photo: 'patagonia'),
  (label: (l) => l.suggestionKenya, photo: 'kenya'),
];

/// The photo for [prompt], or a thrown error naming the missing slug.
///
/// The pool and [kDestinationPhotos] are edited in different places — the
/// prompt by hand, the table by `scripts/fetch-destination-photos.py` — so a
/// slug can go stale between them. Failing here with the slug in the message
/// beats a bare null-check crash or, worse, a card that silently renders its
/// fallback box forever. `suggestion_pool_assets_test.dart` pins that every
/// pool entry resolves, so this should only ever fire mid-edit.
DestinationPhoto photoFor(SuggestionPrompt prompt) {
  final photo = kDestinationPhotos[prompt.photo];
  if (photo == null) {
    throw StateError(
      'No destination photo for "${prompt.photo}". Add it to SOURCES in '
      'scripts/fetch-destination-photos.py and re-run the script.',
    );
  }
  return photo;
}

/// How many suggestion chips a surface shows (the near-me chip is extra).
const int kSuggestionCount = 3;

/// Pure and unit-testable: [count] distinct pool indices in random order.
List<int> pickSuggestionIndices(Random random, {int count = kSuggestionCount}) =>
    (List<int>.generate(suggestionPool.length, (i) => i)..shuffle(random))
        .sublist(0, count);

/// The one determinism seam. Production entropy lives only here; tests
/// override with an explicit-index picker such as `() => const [0, 1, 2]`
/// rather than a seeded [Random], whose mapping to picks would couple them
/// to `List.shuffle` internals.
final suggestionPickerProvider = Provider<List<int> Function()>((ref) {
  final random = Random();
  return () => pickSuggestionIndices(random);
});

/// EVERY pool index, in random order — the destination rails (the agent
/// empty state's and the landing page's) carry the whole pool rather than
/// a sample of it.
///
/// A sibling of [suggestionPickerProvider] rather than a parameter on it: the
/// home hero still shows [kSuggestionCount] chips it can fit, and the two
/// surfaces now want genuinely different draws. Which provider a surface
/// reads is stated at its call site (`RandomSuggestions.picker`), so neither
/// can silently inherit the other's count. Same determinism seam rules apply.
final suggestionOrderProvider = Provider<List<int> Function()>((ref) {
  final random = Random();
  return () => pickSuggestionIndices(random, count: suggestionPool.length);
});
