import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';

/// Shared pool of one-tap trip prompts for the agent chat's empty state and
/// the home hero card. Selectors, not strings: WHICH prompts show is
/// locale-independent; WHAT they say resolves at render time, so a locale
/// switch relabels the same picks without reshuffling. Every label is BOTH
/// what the traveler reads and what gets sent (see `_SuggestionChip`).
/// ORDER IS API: the first three are the legacy trio; tests pin picks by
/// pool index, so append new prompts at the tail and never reorder.
final List<String Function(AppLocalizations)> suggestionPool = [
  (l) => l.suggestionParis,
  (l) => l.suggestionRome,
  (l) => l.suggestionTokyo,
  (l) => l.suggestionGreece,
  (l) => l.suggestionLisbon,
  (l) => l.suggestionBarcelona,
  (l) => l.suggestionBangkok,
  (l) => l.suggestionAmalfi,
  (l) => l.suggestionNewYork,
  (l) => l.suggestionBali,
  (l) => l.suggestionPatagonia,
  (l) => l.suggestionKenya,
];

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
