import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/trip_finding.dart';
import 'package:travel_route_planner/providers/trip_review_provider.dart';
import 'package:travel_route_planner/widgets/home_next_step_band.dart';

import 'support/l10n_test_app.dart';

/// The continue hero's sequel band on Home. Its whole job is knowing when NOT
/// to render — the band decorates a section that already exists, so every
/// absent case has to collapse to zero height rather than leave a tinted strip
/// under the hero.
void main() {
  const tripId = 't1';

  NextStep step({String kind = 'add_lodging', String? detail}) => NextStep(
        kind: kind,
        title: 'Book your stay in Kraków',
        detail: detail,
      );

  Future<void> pump(
    WidgetTester tester, {
    required AsyncValue<TripReview> review,
  }) async {
    var taps = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripReviewProvider(const TripReviewKey(tripId))
              .overrideWith((ref) async => review.value ?? (throw 'pending')),
        ],
        child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: Scaffold(
            body: HomeNextStepBand(tripId: tripId, onTap: () => taps++),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('renders the step, its detail, and the ladder counter',
      (tester) async {
    await pump(
      tester,
      review: AsyncValue.data(TripReview(
        findings: const [],
        nextStep: step(detail: 'No lodging for Aug 29 – Sep 3'),
        planProgress: const PlanProgress(done: 2, total: 6),
      )),
    );

    expect(find.text('Book your stay in Kraków'), findsOneWidget);
    expect(find.text('No lodging for Aug 29 – Sep 3'), findsOneWidget);
    // done + 1 — the step being shown is the one in progress, not the last
    // finished one, exactly as NextStepCard's eyebrow counts.
    expect(find.text('3 of 6'), findsOneWidget);
  });

  testWidgets('carries no action button — the trip page owns the real one',
      (tester) async {
    await pump(
      tester,
      review: AsyncValue.data(TripReview(
        findings: const [],
        nextStep: step(),
      )),
    );

    // The band states the step and inherits the hero's tap. A button here
    // would have to name an action Home cannot perform.
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
  });

  testWidgets('the whole band is one tap target', (tester) async {
    await pump(
      tester,
      review: AsyncValue.data(TripReview(
        findings: const [],
        nextStep: step(),
      )),
    );

    expect(
      find.descendant(
          of: find.byType(HomeNextStepBand), matching: find.byType(InkWell)),
      findsOneWidget,
    );
  });

  testWidgets('all_set collapses — Home is not where a celebration belongs',
      (tester) async {
    await pump(
      tester,
      review: AsyncValue.data(TripReview(
        findings: const [],
        nextStep: step(kind: 'all_set'),
      )),
    );

    expect(find.byType(InkWell), findsNothing);
    expect(tester.getSize(find.byType(HomeNextStepBand)), Size.zero);
  });

  testWidgets('a step-less payload collapses', (tester) async {
    await pump(
      tester,
      review: const AsyncValue.data(TripReview(findings: [])),
    );

    expect(tester.getSize(find.byType(HomeNextStepBand)), Size.zero);
  });

  testWidgets('no counter when the server sent no ladder', (tester) async {
    await pump(
      tester,
      review: AsyncValue.data(TripReview(
        findings: const [],
        nextStep: step(),
      )),
    );

    expect(find.text('Book your stay in Kraków'), findsOneWidget);
    expect(find.textContaining(' of '), findsNothing);
  });
}
