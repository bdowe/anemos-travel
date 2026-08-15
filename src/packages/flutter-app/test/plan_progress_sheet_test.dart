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
  PlanPhase(id: 'itinerary', label: 'Add your destinations', count: 10),
  PlanPhase(
    id: 'bookings',
    label: 'Book travel & stays',
    progress: PhaseProgress(done: 4, total: 11),
  ),
  PlanPhase(
    id: 'schedule',
    label: 'Plan your days',
    progress: PhaseProgress(done: 0, total: 37),
  ),
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

  // Sub-progress: eleven booking slots close one at a time under a single
  // rung, so the rung carries the only number that moves while the ladder
  // itself sits on "3 of 6". Same for the days rung, whose "0 of 37" is the
  // signal that nothing is planned even though the rung is still ahead.
  // Rungs with no honest denominator show nothing.
  testWidgets('a rung with a tally shows it, the others show none',
      (tester) async {
    await tester.pumpWidget(_app(const PlanProgressSheetBody(
      progress: PlanProgress(done: 2, total: 6, phases: _phases),
      currentStep: _step,
    )));

    expect(
        find.descendant(
            of: find.byKey(const ValueKey('plan-phase-bookings')),
            matching: find.text('4 of 11')),
        findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('plan-phase-schedule')),
            matching: find.text('0 of 37')),
        findsOneWidget);
    // The header pill is the ladder's own counter; no other rung invents one.
    expect(find.textContaining(' of '),
        findsNWidgets(3)); // "3 of 6" + "4 of 11" + "0 of 37"
  });

  // Adding destinations has no target to progress toward, so that rung carries
  // a bare count. Rendered as a tally it would read "10 of 10" — finished.
  testWidgets('a rung with a count shows the bare number', (tester) async {
    await tester.pumpWidget(_app(const PlanProgressSheetBody(
      progress: PlanProgress(done: 2, total: 6, phases: _phases),
      currentStep: _step,
    )));

    expect(
        find.descendant(
            of: find.byKey(const ValueKey('plan-phase-itinerary')),
            matching: find.text('10')),
        findsOneWidget);
    expect(find.text('10 of 10'), findsNothing);
  });

  // The days rung's step title IS its label, so printing both would say "Plan
  // your days" twice in two colors. The detail still carries the news.
  testWidgets('a step title identical to the rung label is not repeated',
      (tester) async {
    await tester.pumpWidget(_app(const PlanProgressSheetBody(
      progress: PlanProgress(done: 3, total: 6, phases: _phases),
      currentStep: NextStep(
        kind: 'schedule_items',
        title: 'Plan your days',
        detail: 'Days 1–36 have nothing planned.',
      ),
    )));

    final schedule = find.byKey(const ValueKey('plan-phase-schedule'));
    expect(find.descendant(of: schedule, matching: find.text('Plan your days')),
        findsOneWidget);
    expect(
        find.descendant(
            of: schedule,
            matching: find.text('Days 1–36 have nothing planned.')),
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

  // Six short rows sized the sheet to its content, which on a tall window
  // anchored it to the bottom ~46% and read as a footer (Brian, 2026-08-14).
  // The floor is what puts it on screen rather than under the fold, so it is
  // worth a geometry assertion — the sheet's own body tests cannot see it.
  testWidgets('the modal opens with a height floor, not hugging the bottom',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1800); // 600 x 900 logical
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(localizedTestApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showPlanProgressSheet(context,
                progress:
                    const PlanProgress(done: 2, total: 6, phases: _phases),
                currentStep: _step),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    const screen = 900.0;
    // The scroll viewport is what the floor stretches; its child stays
    // content-sized and top-aligned inside it (the slack falls below).
    final viewport = tester.getSize(find.ancestor(
      of: find.byType(PlanProgressSheetBody),
      matching: find.byType(SingleChildScrollView),
    ));
    expect(viewport.height, greaterThanOrEqualTo(screen * 0.62),
        reason: 'the floor must survive a short ladder');

    // The user-facing claim: the sheet starts above the halfway line.
    final top = tester.getTopLeft(find.byType(PlanProgressSheetBody)).dy;
    expect(top, lessThan(screen / 2));
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
