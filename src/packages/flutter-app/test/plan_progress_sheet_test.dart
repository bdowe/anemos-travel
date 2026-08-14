import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/trip_finding.dart';
import 'package:travel_route_planner/widgets/plan_progress_sheet.dart';

import 'support/l10n_test_app.dart';

// Pure widget tests for the Plan progress sheet (specs/next-step-cta): the
// ladder behind the Next Step card's "N of 6" counter. No providers, no
// network — the sheet renders the review payload it is handed.

const _phases = [
  PlanPhase(id: 'dates', label: 'Set your travel dates'),
  PlanPhase(id: 'itinerary', label: 'Plan your days'),
  PlanPhase(id: 'bookings', label: 'Book travel & stays'),
  PlanPhase(id: 'schedule', label: 'Tidy up your schedule'),
  PlanPhase(id: 'confirm', label: 'Book everything'),
  PlanPhase(id: 'packing', label: 'Start your packing list'),
];

const _step = NextStep(
  kind: 'add_transport',
  title: 'Book your flight to Prague',
  detail: 'EWR → Prague · departs Mon, Aug 24',
);

Widget _app(Widget body) => localizedTestApp(home: Scaffold(body: body));

void main() {
  testWidgets('renders the whole ladder in server order', (tester) async {
    await tester.pumpWidget(_app(const PlanProgressSheetBody(
      progress: PlanProgress(done: 2, total: 6, phases: _phases),
      currentStep: _step,
    )));

    expect(find.text('Plan progress'), findsOneWidget);
    expect(find.text('3 of 6'), findsOneWidget);
    for (final p in _phases) {
      expect(find.byKey(ValueKey('plan-phase-${p.id}')), findsOneWidget);
      expect(find.text(p.label), findsOneWidget);
    }
  });

  // Prefix progress IS the state: two rungs complete, the third current, the
  // rest later. The marks are the only place that derivation happens.
  testWidgets('marks done, current and later rungs', (tester) async {
    await tester.pumpWidget(_app(const PlanProgressSheetBody(
      progress: PlanProgress(done: 2, total: 6, phases: _phases),
      currentStep: _step,
    )));

    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(3));
  });

  // The point of the sheet: "step 3" and the card's title are visibly the
  // same thing, and the step block hangs off the CURRENT rung only.
  testWidgets('the current rung carries the card\'s step', (tester) async {
    await tester.pumpWidget(_app(const PlanProgressSheetBody(
      progress: PlanProgress(done: 2, total: 6, phases: _phases),
      currentStep: _step,
    )));

    final bookings = find.byKey(const ValueKey('plan-phase-bookings'));
    expect(
        find.descendant(
            of: bookings, matching: find.text('Book your flight to Prague')),
        findsOneWidget);
    expect(
        find.descendant(
            of: bookings,
            matching: find.text('EWR → Prague · departs Mon, Aug 24')),
        findsOneWidget);
  });

  testWidgets('a complete ladder is all checks and no step block',
      (tester) async {
    await tester.pumpWidget(_app(const PlanProgressSheetBody(
      progress: PlanProgress(done: 6, total: 6, phases: _phases),
      currentStep: NextStep(kind: 'all_set', title: "You're all set"),
    )));

    expect(find.byIcon(Icons.check_circle), findsNWidgets(6));
    expect(find.text('6 of 6'), findsOneWidget); // clamped, never "7 of 6"
    expect(find.text("You're all set"), findsNothing);
  });

  // An older server (or a cached response) sends no ladder; the body must be
  // inert rather than an empty, confusing sheet.
  testWidgets('no phases renders nothing', (tester) async {
    await tester.pumpWidget(_app(const PlanProgressSheetBody(
      progress: PlanProgress(done: 2, total: 6),
    )));

    expect(find.text('Plan progress'), findsNothing);
  });

  testWidgets('labels are server copy, chrome is localized', (tester) async {
    await tester.pumpWidget(localizedTestApp(
      locale: const Locale('es'),
      home: const Scaffold(
        body: PlanProgressSheetBody(
          progress: PlanProgress(done: 2, total: 6, phases: _phases),
        ),
      ),
    ));

    expect(find.text('Progreso del plan'), findsOneWidget);
    // Rung labels arrive localized from the server, so the fixture's English
    // ones render verbatim — the client never translates them.
    expect(find.text('Book travel & stays'), findsOneWidget);
  });
}
