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
/// button (it becomes an app-bar sparkle) and the dates chip humanizes.
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

void main() {
  const phone = Size(390, 844);

  testWidgets('narrow owner: sparkle in app bar opens refine; dates humanize',
      (tester) async {
    await _pump(tester, _trip(), surface: phone);

    // Meta row: no Refine button, humanized dates instead of raw ISO.
    expect(find.text('Refine with AI'), findsNothing);
    expect(find.textContaining('2026-09-01'), findsNothing);
    expect(find.text('Sep 1 – Sep 3'), findsOneWidget);

    // The app-bar sparkle opens the refine panel (narrow => sheet).
    final sparkle = find.byTooltip('Refine with AI');
    expect(sparkle, findsOneWidget);
    await tester.tap(sparkle);
    await tester.pumpAndSettle();
    expect(find.byType(TripRefinePanel), findsOneWidget);
  });

  testWidgets('narrow editor collaborator keeps the sparkle (spec)',
      (tester) async {
    await _pump(tester, _trip(access: 'editor'), surface: phone);
    expect(find.byTooltip('Refine with AI'), findsOneWidget);
  });

  testWidgets('narrow viewer never gets the sparkle', (tester) async {
    await _pump(tester, _trip(access: 'viewer'), surface: phone);
    expect(find.byTooltip('Refine with AI'), findsNothing);
    expect(find.byIcon(Icons.auto_awesome), findsNothing);
  });

  testWidgets('wide keeps the header button and raw ISO dates; no sparkle',
      (tester) async {
    await _pump(tester, _trip(), surface: const Size(1200, 900));
    expect(find.text('Refine with AI'), findsOneWidget);
    expect(find.text('2026-09-01 → 2026-09-03'), findsOneWidget);
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

    for (final label in ['Itinerary', 'Bookings · 0/1', 'Budget']) {
      expect(find.text(label), findsOneWidget);
      expectNoTruncation(tester, label);
    }
    expect(find.text('Add place'), findsNothing);
    expect(find.byTooltip('Add place'), findsOneWidget);
  });

  testWidgets('narrow Spanish: tabs render whole too', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 0.5;
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await _pump(tester, _trip(todos: oneTodo),
        surface: phone, locale: const Locale('es'));

    // minScale 0.95: the square test font at 0.5 overshoots real glyph
    // widths by a few percent on the long Spanish trio (every glyph is
    // fontSize/2 wide; real 'i'/'r'/'l' are narrower), so the cluster may
    // sit a hair into the FittedBox's scale-down here while fitting whole
    // in a real browser at 390px (verified 2026-08-13). Anything below
    // ~0.95 would be a genuinely visible shrink — that's the tripwire for
    // dropping the Bookings counter on narrow.
    for (final label in ['Itinerario', 'Reservas · 0/1', 'Presupuesto']) {
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

    await tester.tap(find.text('Bookings · 0/1'));
    await tester.pumpAndSettle();

    // Same icon-only rule as Add place, same row-must-fit reason; the swap
    // means the two add CTAs never share the header.
    expect(find.text('Add booking'), findsNothing);
    expect(find.byTooltip('Add booking'), findsOneWidget);
    expect(find.byTooltip('Add place'), findsNothing);
  });
}
