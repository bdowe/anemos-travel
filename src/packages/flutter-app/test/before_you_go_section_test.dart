import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/trip_finding.dart';
import 'package:travel_route_planner/providers/trip_review_provider.dart';
import 'package:travel_route_planner/widgets/before_you_go_section.dart';

import 'support/l10n_test_app.dart';

/// The two things "Before you go" has to do that a list of findings does not:
/// say **whose** trip it is describing, and **go somewhere** that can act on
/// it. It shipped without either — a nameless list of gaps with no tap on it,
/// under a header that was one scroll away from any trip name — and the
/// "N more open items" line, the one that named the complete list, was grey
/// text stranded outside the card with nothing behind it.
///
/// Ordering has its own suite (before_you_go_order_test.dart); this one pins
/// the wiring.
void main() {
  const tripId = 't1';

  /// A date-only ISO string [days] from today, by calendar arithmetic (the
  /// constructor normalizes month overflow) so the countdown is exact rather
  /// than a Duration that a DST boundary could shave.
  String inDays(int days) {
    final now = DateTime.now();
    final d = DateTime(now.year, now.month, now.day + days);
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  TripFinding lodging(String city, String checkIn) => TripFinding(
        severity: 'warn',
        category: 'lodging',
        message: 'No lodging booked in $city',
        tripId: tripId,
        fix: FindingFix(
          action: 'add_lodging',
          label: 'Find a stay',
          city: city,
          checkIn: checkIn,
          checkOut: checkIn,
        ),
      );

  /// n findings, chronological so the cap takes a predictable slice.
  List<TripFinding> findings(int n) => [
        for (var i = 0; i < n; i++)
          lodging('City $i', '2026-09-${(i + 1).toString().padLeft(2, '0')}'),
      ];

  late int taps;

  /// [startsIn] is days until departure; null means the trip has no start date
  /// at all, which is the only way to reach the countdown-less card.
  Future<void> pump(
    WidgetTester tester, {
    required TripReview review,
    String title = 'Northern Europe',
    int? startsIn = 6,
  }) async {
    taps = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripReviewProvider(const TripReviewKey(tripId))
              .overrideWith((ref) async => review),
        ],
        child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: Scaffold(
            body: BeforeYouGoSection(
              tripId: tripId,
              tripTitle: title,
              startDate: startsIn == null ? null : inDays(startsIn),
              onTap: () => taps++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  group('it says which trip it is about', () {
    testWidgets('the card prints the trip name', (tester) async {
      await pump(tester, review: TripReview(findings: findings(2)));

      expect(find.text('Northern Europe'), findsOneWidget);
    });

    testWidgets('the name sits INSIDE the card, not in the section header',
        (tester) async {
      // ContinueChatsSection can render any number of saved conversations
      // between the trip block and this section, so a name that lived only in
      // the header could be scrolled off with it.
      await pump(tester, review: TripReview(findings: findings(2)));

      expect(
        find.descendant(
            of: find.byType(Card), matching: find.text('Northern Europe')),
        findsOneWidget,
      );
    });

    testWidgets('and how long is left', (tester) async {
      await pump(tester, review: TripReview(findings: findings(2)));

      expect(find.text('Starts in 6 days'), findsOneWidget);
    });

    testWidgets('a trip with no start date keeps the name, drops the countdown',
        (tester) async {
      await pump(tester,
          review: TripReview(findings: findings(2)), startsIn: null);

      expect(find.text('Northern Europe'), findsOneWidget);
      expect(find.textContaining('Starts in'), findsNothing);
    });

    testWidgets('departing today reads "Starts today", not "in 0 days"',
        (tester) async {
      await pump(tester,
          review: TripReview(findings: findings(2)), startsIn: 0);

      expect(find.text('Starts today'), findsOneWidget);
    });
  });

  group('it goes somewhere', () {
    testWidgets('the whole card is one tap target', (tester) async {
      await pump(tester, review: TripReview(findings: findings(3)));

      // One, not one per row: every row would go to the same health sheet.
      expect(
        find.descendant(
            of: find.byType(BeforeYouGoSection), matching: find.byType(InkWell)),
        findsOneWidget,
      );
    });

    testWidgets('tapping a finding row fires the section tap', (tester) async {
      await pump(tester, review: TripReview(findings: findings(3)));

      await tester.tap(find.text('No lodging booked in City 0'));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('tapping the trip line fires it too', (tester) async {
      await pump(tester, review: TripReview(findings: findings(3)));

      await tester.tap(find.text('Northern Europe'));
      await tester.pump();

      expect(taps, 1);
    });

    testWidgets('it carries no button — the sheet owns the real ones',
        (tester) async {
      await pump(tester, review: TripReview(findings: findings(3)));

      // A "Find a stay" here could only navigate; applying a fix needs the
      // trip screen's mutation providers (the HomeNextStepBand rule).
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(ElevatedButton), findsNothing);
    });
  });

  group('the overflow line', () {
    testWidgets('counts what the cap hid', (tester) async {
      await pump(tester, review: TripReview(findings: findings(15)));

      expect(find.text('No lodging booked in City 0'), findsOneWidget);
      expect(find.text('No lodging booked in City 4'), findsOneWidget);
      expect(find.text('No lodging booked in City 5'), findsNothing);
      expect(find.text('10 more open items'), findsOneWidget);
    });

    testWidgets('is inside the tap target, not stranded under the card',
        (tester) async {
      // The whole defect in one assertion: this line names the complete list,
      // so it must be part of the thing that opens it.
      await pump(tester, review: TripReview(findings: findings(15)));

      expect(
        find.descendant(
            of: find.byType(InkWell), matching: find.text('10 more open items')),
        findsOneWidget,
      );
    });

    testWidgets('is absent when nothing was hidden', (tester) async {
      await pump(tester, review: TripReview(findings: findings(4)));

      expect(find.textContaining('more open item'), findsNothing);
    });
  });

  group('when it renders nothing at all', () {
    testWidgets('no open items — an empty "Before you go" is worse than none',
        (tester) async {
      await pump(tester, review: const TripReview(findings: []));

      expect(tester.getSize(find.byType(BeforeYouGoSection)), Size.zero);
    });

    testWidgets('every item is the one already promoted into the band above',
        (tester) async {
      final gap = lodging('Kraków', '2026-09-01');
      await pump(
        tester,
        review: TripReview(
          findings: [gap],
          nextStep: NextStep(
            kind: 'add_lodging',
            title: 'Book your stay in Kraków',
            fix: gap.fix,
          ),
        ),
      );

      expect(tester.getSize(find.byType(BeforeYouGoSection)), Size.zero);
    });
  });
}
