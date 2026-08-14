import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/trip_finding.dart';
import 'package:travel_route_planner/widgets/next_step_card.dart';

import 'support/l10n_test_app.dart';

// Pure widget tests for NextStepCard (specs/next-step-cta) — no providers, no
// network: the step arrives as a plain model and every behavior is a callback.

const _lodgingStep = NextStep(
  kind: 'add_lodging',
  title: 'Book a place to stay',
  detail: 'No lodging booked for the nights of Sep 1 – Sep 2 (2 nights).',
);

const _allSetStep = NextStep(
  kind: 'all_set',
  title: "You're all set",
  detail: 'Dates, plan, lodging, transport and bookings all check out.',
);

Widget _app(NextStepCard card) =>
    localizedTestApp(home: Scaffold(body: card));

void main() {
  testWidgets('renders eyebrow, progress, title, detail, and kind action',
      (tester) async {
    await tester.pumpWidget(_app(NextStepCard(
      step: _lodgingStep,
      progress: const PlanProgress(done: 2, total: 6),
      onPrimary: () {},
      onViewAll: () {},
    )));

    expect(find.text('NEXT STEP · 3 of 6'), findsOneWidget);
    expect(find.text('Book a place to stay'), findsOneWidget);
    expect(find.textContaining('No lodging booked'), findsOneWidget);
    expect(find.text('Find lodging'), findsOneWidget); // add_lodging action
    expect(find.text('View all'), findsOneWidget);
    expect(find.byIcon(Icons.hotel_outlined), findsOneWidget);
  });

  testWidgets('primary fires from the button and the whole card',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(_app(NextStepCard(
      step: _lodgingStep,
      onPrimary: () => taps++,
    )));

    await tester.tap(find.byKey(const ValueKey('next-step-primary')));
    await tester.tap(find.text('Book a place to stay')); // card body InkWell
    expect(taps, 2);
  });

  testWidgets('disabled (offline) card renders but fires nothing',
      (tester) async {
    var fired = false;
    await tester.pumpWidget(_app(NextStepCard(
      step: _lodgingStep,
      enabled: false,
      onPrimary: () => fired = true,
      onViewAll: () => fired = true,
    )));

    expect(find.byKey(const ValueKey('next-step-card')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('next-step-primary')),
        warnIfMissed: false);
    await tester.tap(find.byKey(const ValueKey('next-step-view-all')),
        warnIfMissed: false);
    expect(fired, isFalse);
  });

  testWidgets('compact drops detail and View all but keeps the action',
      (tester) async {
    await tester.pumpWidget(_app(NextStepCard(
      step: _lodgingStep,
      compact: true,
      onPrimary: () {},
      onViewAll: () {},
    )));

    expect(find.textContaining('No lodging booked'), findsNothing);
    expect(find.byKey(const ValueKey('next-step-view-all')), findsNothing);
    expect(find.byKey(const ValueKey('next-step-primary')), findsOneWidget);
  });

  testWidgets('unknown kind falls back to the fix label', (tester) async {
    await tester.pumpWidget(_app(NextStepCard(
      step: const NextStep(
        kind: 'future_phase',
        title: 'Something new',
        fix: FindingFix(action: 'mystery', label: 'Do the thing'),
      ),
      onPrimary: () {},
    )));

    expect(find.text('Do the thing'), findsOneWidget);
    expect(find.byIcon(Icons.place_outlined), findsOneWidget); // icon fallback
  });

  testWidgets('all_set renders the success variant and dismisses',
      (tester) async {
    var dismissed = false;
    await tester.pumpWidget(_app(NextStepCard(
      step: _allSetStep,
      onDismiss: () => dismissed = true,
    )));

    expect(find.byKey(const ValueKey('next-step-all-set')), findsOneWidget);
    expect(find.text("You're all set"), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.byKey(const ValueKey('next-step-primary')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('next-step-dismiss')));
    expect(dismissed, isTrue);
  });

  testWidgets('null step renders nothing', (tester) async {
    await tester.pumpWidget(_app(const NextStepCard(step: null)));
    expect(find.byKey(const ValueKey('next-step-card')), findsNothing);
    expect(find.byKey(const ValueKey('next-step-all-set')), findsNothing);
  });

  testWidgets('progress clamps at the final phase', (tester) async {
    await tester.pumpWidget(_app(NextStepCard(
      step: _lodgingStep,
      progress: const PlanProgress(done: 6, total: 6),
      onPrimary: () {},
    )));
    expect(find.text('NEXT STEP · 6 of 6'), findsOneWidget);
  });

  // The transport action label follows the matched booking todo's mode on the
  // fix (itinerary-order walk, specs/next-step-cta) — mirroring the checklist
  // row's openLabelOverride. Ground modes and fix-less steps from an older
  // server keep the generic label.
  testWidgets('add_transport with a flight fix labels Find flights',
      (tester) async {
    await tester.pumpWidget(_app(NextStepCard(
      step: const NextStep(
        kind: 'add_transport',
        title: 'Book your flight to Lyon',
        fix: FindingFix(
          action: 'add_transport',
          label: 'Find flights',
          origin: 'Paris',
          destination: 'Lyon',
          mode: 'flight',
        ),
      ),
      onPrimary: () {},
    )));

    expect(find.text('Find flights'), findsOneWidget);
    expect(find.byIcon(Icons.directions_transit_outlined), findsOneWidget);
  });

  testWidgets('add_transport with a ferry fix labels Find ferries',
      (tester) async {
    await tester.pumpWidget(_app(NextStepCard(
      step: const NextStep(
        kind: 'add_transport',
        title: 'Book your ferry to Naxos',
        fix: FindingFix(
          action: 'add_transport',
          label: 'Find ferries',
          origin: 'Paros',
          destination: 'Naxos',
          mode: 'ferry',
        ),
      ),
      onPrimary: () {},
    )));

    expect(find.text('Find ferries'), findsOneWidget);
    expect(find.byIcon(Icons.directions_transit_outlined), findsOneWidget);
  });

  testWidgets('add_transport with no mode keeps the generic label',
      (tester) async {
    await tester.pumpWidget(_app(NextStepCard(
      step: const NextStep(
        kind: 'add_transport',
        title: 'Book your travel to Lyon',
        fix: FindingFix(
          action: 'add_transport',
          label: 'Find options',
          origin: 'Paris',
          destination: 'Lyon',
        ),
      ),
      onPrimary: () {},
    )));

    expect(find.text('Find options'), findsOneWidget);
    expect(find.byIcon(Icons.directions_transit_outlined), findsOneWidget);
  });

  testWidgets('fix-less add_transport (old server) keeps the generic label',
      (tester) async {
    await tester.pumpWidget(_app(NextStepCard(
      step: const NextStep(
        kind: 'add_transport',
        title: 'Book your travel to Lyon',
      ),
      onPrimary: () {},
    )));

    expect(find.text('Find options'), findsOneWidget);
    expect(find.byIcon(Icons.directions_transit_outlined), findsOneWidget);
  });
}
