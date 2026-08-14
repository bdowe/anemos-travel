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

const _progress = PlanProgress(done: 2, total: 6, phases: [
  PlanPhase(id: 'dates', label: 'Set your travel dates'),
  PlanPhase(id: 'itinerary', label: 'Plan your days'),
  PlanPhase(id: 'bookings', label: 'Book travel & stays'),
  PlanPhase(id: 'schedule', label: 'Tidy up your schedule'),
  PlanPhase(id: 'confirm', label: 'Book everything'),
  PlanPhase(id: 'packing', label: 'Start your packing list'),
]);

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
      progress: _progress,
      onPrimary: () {},
      onViewAll: () {},
    )));

    expect(find.text('NEXT STEP · 3 of 6'), findsOneWidget);
    expect(find.text('Book a place to stay'), findsOneWidget);
    expect(find.textContaining('No lodging booked'), findsOneWidget);
    expect(find.text('Find lodging'), findsOneWidget); // add_lodging action
    // The secondary entry names its destination — the health sheet's own
    // title — instead of the old ambiguous "View all" beside a step counter.
    expect(find.text('Trip health'), findsOneWidget);
    expect(find.byIcon(Icons.hotel_outlined), findsOneWidget);
  });

  // The eyebrow counter is the ladder's entry point (specs/next-step-cta): it
  // must open the progress sheet and, sitting inside the card-wide InkWell,
  // must NOT also fire the primary action.
  testWidgets('the progress counter opens the ladder, not the primary action',
      (tester) async {
    var progressTaps = 0, primaryTaps = 0;
    await tester.pumpWidget(_app(NextStepCard(
      step: _lodgingStep,
      progress: _progress,
      onPrimary: () => primaryTaps++,
      onViewProgress: () => progressTaps++,
    )));

    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('next-step-progress')));
    expect(progressTaps, 1);
    expect(primaryTaps, 0);
  });

  testWidgets('no progress callback leaves a plain, untappable eyebrow',
      (tester) async {
    await tester.pumpWidget(_app(NextStepCard(
      step: _lodgingStep,
      progress: _progress,
      onPrimary: () {},
    )));

    expect(find.text('NEXT STEP · 3 of 6'), findsOneWidget);
    expect(find.byKey(const ValueKey('next-step-progress')), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsNothing);
  });

  // Explaining the counter is a pure read of the payload already on screen, so
  // it survives the offline disable that kills every acting affordance.
  testWidgets('the progress entry still opens while offline', (tester) async {
    var opened = false;
    await tester.pumpWidget(_app(NextStepCard(
      step: _lodgingStep,
      progress: _progress,
      enabled: false,
      onPrimary: () {},
      onViewProgress: () => opened = true,
    )));

    await tester.tap(find.byKey(const ValueKey('next-step-progress')));
    expect(opened, isTrue);
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

  // Compact sheds the detail line and the health entry, but NOT the progress
  // entry: the counter renders at every width, so its explanation must too.
  testWidgets('compact drops detail and Trip health, keeps action + counter',
      (tester) async {
    await tester.pumpWidget(_app(NextStepCard(
      step: _lodgingStep,
      progress: _progress,
      compact: true,
      onPrimary: () {},
      onViewAll: () {},
      onViewProgress: () {},
    )));

    expect(find.textContaining('No lodging booked'), findsNothing);
    expect(find.byKey(const ValueKey('next-step-view-all')), findsNothing);
    expect(find.byKey(const ValueKey('next-step-primary')), findsOneWidget);
    expect(find.byKey(const ValueKey('next-step-progress')), findsOneWidget);
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
      transportHandsOff: true,
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
      transportHandsOff: true,
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
      transportHandsOff: true,
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

  // The findings fallback (no synced row behind the step) still carries a
  // mode on its fix — checkTransit always sets one — but its tap opens the
  // seeded chat, so the button must not promise "Find flights".
  testWidgets('add_transport that cannot hand off keeps the generic label',
      (tester) async {
    await tester.pumpWidget(_app(NextStepCard(
      step: const NextStep(
        kind: 'add_transport',
        title: 'Add transport between cities',
        fix: FindingFix(
          action: 'add_transport',
          label: 'Add transport',
          origin: 'Paris',
          destination: 'Lyon',
          mode: 'flight',
        ),
      ),
      onPrimary: () {},
    )));

    expect(find.text('Find options'), findsOneWidget);
    expect(find.text('Find flights'), findsNothing);
  });
}
