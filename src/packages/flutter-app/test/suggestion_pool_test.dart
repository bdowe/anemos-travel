import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/l10n/l10n.dart';
import 'package:travel_route_planner/providers/suggestions_provider.dart';

/// The suggestion pool's contracts: picks are distinct in-range indices, the
/// whole pool is reachable (no prompt is dead weight), and every label is
/// usable as BOTH display text and sent message in each shipped locale.
void main() {
  test('pickSuggestionIndices returns distinct in-range indices', () {
    expect(suggestionPool.length, greaterThanOrEqualTo(kSuggestionCount));
    for (var seed = 0; seed < 20; seed++) {
      final picks = pickSuggestionIndices(Random(seed));
      expect(picks, hasLength(kSuggestionCount));
      expect(picks.toSet(), hasLength(kSuggestionCount));
      for (final i in picks) {
        expect(i, inInclusiveRange(0, suggestionPool.length - 1));
      }
    }
  });

  test('every pool prompt is reachable', () {
    final random = Random(42);
    final seen = <int>{};
    for (var draw = 0;
        draw < 200 && seen.length < suggestionPool.length;
        draw++) {
      seen.addAll(pickSuggestionIndices(random));
    }
    expect(seen, hasLength(suggestionPool.length));
  });

  test('labels are non-empty and distinct in every shipped locale', () {
    for (final locale in kSupportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      final labels = [for (final pick in suggestionPool) pick(l10n)];
      expect(labels.where((s) => s.trim().isEmpty), isEmpty,
          reason: 'empty label in $locale');
      // Distinctness is load-bearing: labels are find.text targets in tests
      // and become literal user messages when tapped.
      expect(labels.toSet(), hasLength(labels.length),
          reason: 'duplicate label in $locale');
    }
  });
}
