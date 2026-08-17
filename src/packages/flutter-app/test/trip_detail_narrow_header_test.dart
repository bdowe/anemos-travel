import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/trip_refine_panel.dart';

import 'support/l10n_test_app.dart';

/// Mobile declutter, header half: on narrow the meta row drops the Refine
/// button. It became an app-bar sparkle, and since 2026-08-17 it is a row in
/// the `⋮` actions sheet instead — the app bar needed those ~48px so the
/// trip's own NAME could be read at 375px rather than clipped to "Big Su…".
/// Health keeps the only narrow icon, because its severity badge is glanceable
/// and a badge inside a menu is a badge nobody sees.
///
/// The header card is deliberately NOT where refine went back to: narrow drops
/// its button for one clean chip row, and putting it back undoes that.
///
/// The dates chip humanizes at BOTH widths — it read raw ISO on wide until
/// 2026-08-14, so the two assertions below are deliberately the same string.
class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

Trip _trip({String? access, List<BookingTodo>? todos}) => Trip(
      id: 't1',
      title: 'Sevilla week',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      startDate: '2026-09-01',
      endDate: '2026-09-03',
      access: access,
      ownerName: access == null ? null : 'Brian',
      items: [
        ItineraryItem(
          id: 'i0',
          position: 0,
          name: 'Real Alcázar',
          latitude: 0,
          longitude: 0,
          category: 'attraction',
          day: 1,
          city: 'Sevilla',
        ),
      ],
      bookingTodos: todos,
    );

Future<void> _pump(WidgetTester tester, Trip trip,
    {required Size surface, Locale? locale}) async {
  await tester.binding.setSurfaceSize(surface);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        supportedLocales: const [Locale('en'), Locale('es')],
        locale: locale,
        home: const TripDetailScreen(tripId: 't1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Opens the `⋮` sheet and picks Refine — the phone route since refine gave
/// up its app-bar icon to the trip's name.
Future<void> _refineFromOverflow(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More options'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Refine with AI'));
  // The caller runs the action AFTER the sheet closes — never from inside its
  // dead context — so this settles two transitions, not one.
  await tester.pumpAndSettle();
}

void main() {
  const phone = Size(390, 844);

  testWidgets('narrow owner: refine rides the ⋮; dates humanize',
      (tester) async {
    await _pump(tester, _trip(), surface: phone);

    // Meta row: no Refine button, humanized dates instead of raw ISO.
    // Scoped to the meta chip: the sole city leg now renders the same span
    // (it runs through the trip's end date — the last-leg anchor), so an
    // unscoped find.text would match twice and say nothing about the row
    // under test.
    expect(find.text('Refine with AI'), findsNothing);
    expect(find.textContaining('2026-09-01'), findsNothing);
    expect(find.widgetWithText(ActionChip, 'Sep 1 – Sep 3'), findsOneWidget);

    // ...and no app-bar sparkle either: that icon is what bought the header
    // the room for the trip's name. Scoped to the AppBar — the itinerary rows
    // keep their own per-item sparkles, which is why an unscoped byIcon here
    // finds two and says nothing about the header.
    expect(find.byTooltip('Refine with AI'), findsNothing);
    expect(
      find.descendant(
          of: find.byType(AppBar), matching: find.byIcon(Icons.auto_awesome)),
      findsNothing,
    );

    await _refineFromOverflow(tester);
    expect(find.byType(TripRefinePanel), findsOneWidget);
  });

  // The sheet used to open at 0.45 of the body, and the panel's own header and
  // composer are fixed costs inside it — so the transcript got ~200px: one
  // quick-reply chip and a clipped bubble. It now opens full. Measured against
  // the DraggableScrollableSheet's own box, which IS the space the body gives
  // it, so the assertion doesn't hardcode the app bar's height.
  testWidgets('narrow: the refine sheet opens full-height', (tester) async {
    await _pump(tester, _trip(), surface: phone);
    await _refineFromOverflow(tester);

    final available = tester.getRect(find.byType(DraggableScrollableSheet));
    final panel = tester.getRect(find.byType(TripRefinePanel));

    // > 0.85 rather than == 1.0: the drag handle strip sits above the panel
    // inside the sheet, so the panel is always the extent minus that strip.
    expect(panel.height / available.height, greaterThan(0.85));
    // And it reaches the bottom — a tall panel floating above the fold would
    // pass the ratio alone.
    expect(panel.bottom, moreOrLessEquals(available.bottom, epsilon: 1));
  });

  // The other half of the contract: full is where it OPENS, not where it is
  // stuck. Dragging the handle down snaps to the 0.4 peek, which is what makes
  // the itinerary reachable without closing the chat.
  testWidgets('narrow: dragging the handle down shrinks the sheet',
      (tester) async {
    await _pump(tester, _trip(), surface: phone);
    await _refineFromOverflow(tester);

    final available = tester.getRect(find.byType(DraggableScrollableSheet));
    final opened = tester.getRect(find.byType(TripRefinePanel)).height;

    await tester.drag(
        find.byKey(const Key('refineSheetHandle')), const Offset(0, 300));
    await tester.pumpAndSettle();

    final dragged = tester.getRect(find.byType(TripRefinePanel)).height;
    expect(dragged, lessThan(opened));
    // Snapped to minChildSize (0.4), not to some arbitrary resting point.
    expect(dragged / available.height, closeTo(0.4, 0.06));
  });

  testWidgets('the phone app bar folds everything but health into the ⋮',
      (tester) async {
    // The width budget, enumerated. Every icon up here costs the trip's name
    // ~48px, and at 375px the name has only ~131px to begin with — so what is
    // pinned is which actions are ALLOWED an icon, not a count. (A count would
    // need the health provider resolved; this fixture leaves it pending, so
    // health renders a SizedBox and any total would be fixture noise. The
    // ceiling on how many the bar can hold lives in brand_everywhere_test's
    // _narrowActionCounts.)
    await _pump(tester, _trip(), surface: phone);

    final bar = find.byType(AppBar);
    void expectFolded(IconData icon, String what) {
      expect(find.descendant(of: bar, matching: find.byIcon(icon)), findsNothing,
          reason: '$what belongs in the ⋮ on a phone');
    }

    // Both mutation-checked: restoring the refine icon, or dropping `!_narrow`
    // from share, reds this test.
    expectFolded(Icons.auto_awesome, 'refine');
    expectFolded(Icons.share_outlined, 'share');
    // Wear is deliberately NOT asserted here. Its action reads a provider this
    // fixture leaves unresolved, so it renders a SizedBox either way and
    // `expectFolded(Icons.luggage_outlined, …)` passes whether it is folded or
    // not — a green line that proves nothing. Its fold predates this lane and
    // is unchanged; a real assertion needs a wear-state override.
    expect(find.descendant(of: bar, matching: find.byIcon(Icons.more_vert)),
        findsOneWidget);

    // And the point of the budget: the trip's name is up there, whole.
    final title = find.descendant(of: bar, matching: find.text('Sevilla week'));
    expect(title, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow editor collaborator keeps refine (spec)',
      (tester) async {
    await _pump(tester, _trip(access: 'editor'), surface: phone);
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    expect(find.text('Refine with AI'), findsOneWidget);
  });

  testWidgets('narrow viewer never gets refine', (tester) async {
    await _pump(tester, _trip(access: 'viewer'), surface: phone);
    expect(find.byTooltip('Refine with AI'), findsNothing);
    expect(find.byIcon(Icons.auto_awesome), findsNothing);

    // ...and it is not hiding in the ⋮ either. Without opening the sheet this
    // assertion would pass on a build that put refine in there ungated —
    // exactly the regression moving it into a menu makes easy to ship.
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    expect(find.text('Refine with AI'), findsNothing);
  });

  testWidgets('wide keeps the header button; dates humanize there too',
      (tester) async {
    await _pump(tester, _trip(), surface: const Size(1200, 900));
    expect(find.text('Refine with AI'), findsOneWidget);
    // Same string as narrow: the chip's format is a property of the trip, not
    // of the viewport. Wide showed the raw ISO pair until 2026-08-14 purely
    // because only narrow was ever fixed.
    expect(find.widgetWithText(ActionChip, 'Sep 1 – Sep 3'), findsOneWidget);
    expect(find.text('2026-09-01 → 2026-09-03'), findsNothing);
    expect(find.byTooltip('Refine with AI'), findsNothing);
  });

  // Itinerary-header half: the view tabs must fit a phone row whole, which
  // is what the icon-only Add place buys (a labeled button + all three tabs
  // + the filter can't share 358px, especially in Spanish). An overflowing
  // row would fail these pumps outright — but an ellipsized Flexible tab
  // would NOT (find.text still matches truncated text), so the fit is
  // asserted by measurement: the rendered paragraph must be at least the
  // label's intrinsic single-line width.
  const oneTodo = [
    BookingTodo(id: 'td1', kind: 'stay', todoKey: 'stay:sevilla', title: 'S'),
  ];

  // minScale: 1.0 = the label must paint at full size; slightly below 1.0
  // tolerates the FittedBox's uniform scale-down where the square-test-font
  // approximation overshoots real glyph widths (see the Spanish test).
  void expectNoTruncation(WidgetTester tester, String label,
      {double minScale = 1.0}) {
    final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
    final painter = TextPainter(
      text: paragraph.text,
      textDirection: TextDirection.ltr,
      textScaler: paragraph.textScaler,
    )..layout();
    // getRect (not getSize): the global rect includes any FittedBox
    // scale-down transform, so this catches BOTH an ellipsized label and a
    // shrunken tab cluster. Small epsilon for float transforms.
    expect(tester.getRect(find.text(label)).width,
        greaterThanOrEqualTo(painter.width * minScale - 0.1),
        reason: '"$label" painted narrower than its text — the tab row '
            'no longer fits this surface');
  }

  // The fit is measured at textScale 0.5: the square test font renders
  // every glyph fontSize wide (~2× a real proportional font), so at scale
  // 1.0 even the shipped two-tab Spanish row "truncates" in tests while
  // fitting on real phones — 0.5 approximates real glyph widths (same
  // rationale as the wide-fit tests in overview-clip and the chip-geometry
  // tests in leg-nights).
  testWidgets('narrow: all three view tabs whole, icon-only Add place',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 0.5;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await _pump(tester, _trip(todos: oneTodo), surface: phone);

    for (final label in ['Itinerary', 'Bookings', 'Budget']) {
      expect(find.text(label), findsOneWidget);
      expectNoTruncation(tester, label);
    }
    // Narrow drops the booked-progress pill from the Bookings tab — the
    // trio + pill is what genuinely shrank the FittedBox at phone widths;
    // the count is one tap away inside the view.
    expect(find.text('0/1'), findsNothing);
    expect(find.text('Add place'), findsNothing);
    expect(find.byTooltip('Add place'), findsOneWidget);
    // The fold-all control is wide-only for this exact reason — it lives in
    // the app-bar overflow at phone widths (trip_detail_collapse_all_test).
    expect(find.byIcon(Icons.unfold_less), findsNothing);
  });

  // The row's real budget is not 390px — it is the docked-refine-panel
  // width. `_narrow` is read from the WINDOW, but the body loses 401px to
  // the panel, so a 1000px window on the wide path lays this row out in
  // ~567px. 800 is the floor of that band and the width at which the fold
  // control has to share the row with a labeled Add place, a Today chip and
  // the Spanish tab trio.
  testWidgets('wide floor: the tab row still fits with the fold control',
      (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 0.5;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    // Dated around today so the Today chip is present — the worst case.
    final now = DateTime.now();
    String iso(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final live = Trip(
      id: 't1',
      title: 'Sevilla week',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      startDate: iso(now.subtract(const Duration(days: 1))),
      endDate: iso(now.add(const Duration(days: 1))),
      items: [
        ItineraryItem(
          id: 'i0',
          position: 0,
          name: 'Real Alcázar',
          latitude: 0,
          longitude: 0,
          category: 'attraction',
          day: 1,
          city: 'Sevilla',
        ),
      ],
      bookingTodos: oneTodo,
    );
    await _pump(tester, live,
        surface: const Size(800, 900), locale: const Locale('es'));

    // Premise first: without this the test would pass with the control
    // deleted, which is the failure mode it exists to catch.
    expect(find.byTooltip('Contraer todo'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Hoy'), findsOneWidget);
    for (final label in ['Itinerario', 'Reservas', 'Presupuesto']) {
      expectNoTruncation(tester, label, minScale: 0.95);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow Spanish: tabs render whole too', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 0.5;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await _pump(tester, _trip(todos: oneTodo),
        surface: phone, locale: const Locale('es'));

    // The counter tripwire fired (2026-08-13): the Bookings counter is now
    // dropped on narrow, which shortens the Spanish trio. The 0.95 hedge
    // stays only for the square test font's overshoot (every glyph is
    // fontSize/2 wide; real 'i'/'r'/'l' are narrower) — the cluster fits
    // whole in a real browser at 390px.
    for (final label in ['Itinerario', 'Reservas', 'Presupuesto']) {
      expect(find.text(label), findsOneWidget);
      expectNoTruncation(tester, label, minScale: 0.95);
    }
    expect(find.byTooltip('Añadir lugar'), findsOneWidget);
  });

  testWidgets('Budget view has no header add CTA', (tester) async {
    await _pump(tester, _trip(todos: oneTodo), surface: phone);

    await tester.tap(find.text('Budget'));
    await tester.pumpAndSettle();

    // The budget body owns its add-expense row; the header slot is empty.
    expect(find.byTooltip('Add place'), findsNothing);
    expect(find.byTooltip('Add booking'), findsNothing);
    expect(find.text('Add place'), findsNothing);
  });

  testWidgets('wide keeps the labeled Add place button', (tester) async {
    await _pump(tester, _trip(todos: oneTodo),
        surface: const Size(1200, 900));

    expect(find.text('Add place'), findsOneWidget);
    expect(find.byTooltip('Add place'), findsNothing);
  });

  testWidgets('narrow Bookings view: icon-only Add booking replaces Add place',
      (tester) async {
    await _pump(tester, _trip(todos: oneTodo), surface: phone);

    await tester.tap(find.text('Bookings'));
    await tester.pumpAndSettle();

    // Same icon-only rule as Add place, same row-must-fit reason; the swap
    // means the two add CTAs never share the header.
    expect(find.text('Add booking'), findsNothing);
    expect(find.byTooltip('Add booking'), findsOneWidget);
    expect(find.byTooltip('Add place'), findsNothing);
  });
}
