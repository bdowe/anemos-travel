import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:travel_route_planner/models/checklist_item.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/weather.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/checklist_api_service.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/services/weather_api_service.dart';
import 'package:travel_route_planner/providers/checklist_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/providers/weather_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/widgets/wear_pack_sheet.dart';
import 'package:travel_route_planner/widgets/wear_recs.dart';

import 'support/l10n_test_app.dart';

/// "What to wear & pack" (specs/what-to-wear), now an app-bar luggage icon
/// opening a modal sheet (the Trip health precedent): the sheet header shows
/// the cross-region temperature envelope + rain signal and the checked/total
/// pill; the body is deterministic phrase rows above the intact checklist,
/// with consecutive same-guidance legs folded into ONE grouped row
/// (groupWearRegions); historical data yields a single trailing footnote,
/// never a per-row qualifier; a revisited city keeps per-visit weather
/// queries (distinct guidance keeps its rows separate); a leg whose report is
/// empty drops out without hiding the icon; recommendations alone show the
/// icon for read-only viewers; without weather the old checklist gating
/// holds. The checklist stays LIVE inside the sheet (its provider), while
/// the regions are a press-time snapshot.

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

/// One fixed report for every lookup — enough when every leg should resolve
/// the same way.
class _FakeWeatherApiService extends WeatherApiService {
  final WeatherReport report;
  _FakeWeatherApiService(this.report)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<WeatherReport> getTripWeather(String city, String startDate,
          {String? endDate}) async =>
      report;
}

/// Per-window reports keyed '<city>|<startDate>', recording every query — for
/// pinning per-visit windows and the empty-report drop-out. Unknown keys get
/// an empty report (the server's own failure contract).
class _MapWeatherApiService extends WeatherApiService {
  final Map<String, WeatherReport> byKey;
  final List<String> calls = [];
  _MapWeatherApiService(this.byKey) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<WeatherReport> getTripWeather(String city, String startDate,
      {String? endDate}) async {
    final key = '$city|$startDate';
    calls.add(key);
    return byKey[key] ?? const WeatherReport();
  }
}

class _FakeChecklistApiService extends ChecklistApiService {
  final List<ChecklistItem> items;
  _FakeChecklistApiService(this.items)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<ChecklistItem>> list(String tripId) async => items;
}

/// Mutable checklist fake: update() patches in place so the reconcile-by-
/// invalidate round trip (toggle → PATCH → list) is observable — pins the
/// live-checklist half of the sheet's snapshot/live split.
class _MutableChecklistApiService extends ChecklistApiService {
  final List<ChecklistItem> items;
  _MutableChecklistApiService(this.items)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<ChecklistItem>> list(String tripId) async => List.of(items);

  @override
  Future<ChecklistItem> update(
      String tripId, String itemId, Map<String, dynamic> body) async {
    final i = items.indexWhere((e) => e.id == itemId);
    items[i] = items[i].copyWith(
      checked: body['checked'] as bool?,
      title: body['title'] as String?,
    );
    return items[i];
  }
}

ItineraryItem _item(int pos, String name, int day, {String city = 'Paris'}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$name street, $city',
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

Trip _trip({String? access, List<ItineraryItem>? items, String? endDate}) =>
    Trip(
      id: 't1',
      title: 'Paris',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      startDate: '2026-09-15',
      endDate: endDate ?? '2026-09-16',
      access: access,
      items: items ??
          [
            _item(0, 'Louvre', 1),
            _item(1, 'Orsay', 2),
          ],
    );

/// Warm + rainy forecast: envelope 15° – 24°, median high 24 → warm band,
/// day 1 at 70% → rain likely; spreads under 12 → no swing flag.
final _warmRainyForecast = WeatherReport(
  location: 'Paris, France',
  kind: 'forecast',
  days: const [
    WeatherDay(
        date: '2026-09-15', tempMinC: 16, tempMaxC: 24, precipProbability: 70),
    WeatherDay(
        date: '2026-09-16', tempMinC: 15, tempMaxC: 22, precipProbability: 10),
  ],
);

final _dryHistorical = WeatherReport(
  location: 'Paris, France',
  kind: 'historical',
  days: const [
    WeatherDay(date: '2025-09-15', tempMinC: 18, tempMaxC: 27),
    WeatherDay(date: '2025-09-16', tempMinC: 17, tempMaxC: 26),
  ],
);

Future<void> _pump(
  WidgetTester tester, {
  required Trip trip,
  WeatherReport? report,
  WeatherApiService? weather,
  List<ChecklistItem> checklist = const [],
  ChecklistApiService? checklistApi,
  Locale? locale,
  Size size = const Size(800, 3000),
}) async {
  // Tall default viewport so the whole page lays out without scrolling.
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
        weatherApiServiceProvider
            .overrideWithValue(weather ?? _FakeWeatherApiService(report!)),
        checklistApiServiceProvider.overrideWithValue(
            checklistApi ?? _FakeChecklistApiService(checklist)),
      ],
      child: localizedTestApp(
          home: TripDetailScreen(tripId: 't1'), locale: locale),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _wearIcon({String tooltip = 'What to wear & pack'}) =>
    find.byTooltip(tooltip);

/// Taps the app-bar luggage icon (always on screen — no ensureVisible) and
/// settles with the sheet open.
Future<void> _openSheet(WidgetTester tester,
    {String tooltip = 'What to wear & pack'}) async {
  await tester.tap(_wearIcon(tooltip: tooltip));
  await tester.pumpAndSettle();
}

/// Finder scoped to the wear block, so day-chip text (which shares strings
/// like the "typical" qualifier) can never satisfy a wear-row assertion.
Finder _inRecs(String text) => find.descendant(
    of: find.byType(WearRecsList), matching: find.textContaining(text));

Finder _sheetDividers() => find.descendant(
    of: find.byType(WearPackSheetBody), matching: find.byType(Divider));

void main() {
  testWidgets('icon opens the sheet; header shows the summary and the pill',
      (tester) async {
    await _pump(
      tester,
      trip: _trip(),
      report: _warmRainyForecast,
      checklist: const [
        ChecklistItem(id: 'c1', category: 'general', title: 'Umbrella'),
        ChecklistItem(
            id: 'c2', category: 'clothing', title: 'Jacket', checked: true),
      ],
    );

    // The entry is the app-bar icon: no body row, no summary, no content
    // until the sheet opens.
    expect(_wearIcon(), findsOneWidget);
    expect(find.text('What to wear & pack'), findsNothing);
    expect(find.text('15° – 24° · rain likely'), findsNothing);
    expect(find.textContaining('Warm —'), findsNothing);
    expect(find.text('Umbrella'), findsNothing);

    await _openSheet(tester);
    expect(find.text('What to wear & pack'), findsOneWidget);
    expect(find.text('15° – 24° · rain likely'), findsOneWidget);
    // Checked count stays glanceable via the pill while recs own the summary.
    expect(find.text('1/2'), findsOneWidget);
  });

  testWidgets('sheet body: per-region phrase rows above the intact checklist',
      (tester) async {
    await _pump(
      tester,
      trip: _trip(),
      report: _warmRainyForecast,
      checklist: const [
        ChecklistItem(id: 'c1', category: 'general', title: 'Umbrella'),
      ],
    );
    await _openSheet(tester);

    // Region line: label · dates · envelope.
    expect(_inRecs('Paris · Sep 15 – Sep 16 · 15° – 24°'), findsOneWidget);
    // Band phrase plus the rain flag, joined on one line; no "typical" for a
    // forecast, and no swing flag for these mild spreads.
    expect(_inRecs('Warm — summer clothes, a light evening layer'),
        findsOneWidget);
    expect(_inRecs('rain likely, pack an umbrella'), findsOneWidget);
    expect(_inRecs('typical for these dates'), findsNothing);
    expect(_inRecs('big day–night range'), findsNothing);
    // All-forecast trip: no historical footnote either.
    expect(_inRecs('Beyond the 16-day forecast'), findsNothing);
    // Recs and checklist both present → exactly one separating divider.
    expect(_sheetDividers(), findsOneWidget);
    // The checklist renders below, still editable: item row + add field.
    expect(find.text('Umbrella'), findsOneWidget);
    expect(find.byType(Checkbox), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
  });

  testWidgets('historical: no per-row qualifier, one footnote after the rows',
      (tester) async {
    await _pump(
      tester,
      trip: _trip(),
      report: _dryHistorical,
      checklist: const [
        ChecklistItem(id: 'c1', category: 'general', title: 'Umbrella'),
      ],
    );
    await _openSheet(tester);

    expect(_inRecs('Warm — summer clothes'), findsOneWidget);
    // The old per-row tail is gone. Scoped to the wear block: the day chips
    // still render the shared qualifier string elsewhere on the screen, and
    // wearHistoricalFootnote says "typical weather for these dates" so the
    // footnote can never satisfy this substring by accident.
    expect(_inRecs('typical for these dates'), findsNothing);
    expect(_inRecs('Beyond the 16-day forecast'), findsOneWidget);
    // Dry historical days: no rain phrase, summary has no rain suffix.
    expect(find.textContaining('rain likely'), findsNothing);
    expect(find.text('17° – 27°'), findsOneWidget);
  });

  testWidgets('a revisited city queries per visit; distinct guidance keeps rows',
      (tester) async {
    // Paris (day 1) → Nice (day 2) → Paris (day 3): the wear rows must come
    // from the leg LIST, not a label-keyed map (which would collapse the two
    // Paris visits into the last window). Bands differ on purpose — cool /
    // mild / warm — so same-guidance grouping cannot merge them and the
    // per-visit contract stays observable.
    final weather = _MapWeatherApiService({
      'Paris|2026-09-15': const WeatherReport(kind: 'forecast', days: [
        WeatherDay(date: '2026-09-15', tempMinC: 8, tempMaxC: 15),
      ]),
      'Nice|2026-09-15': const WeatherReport(kind: 'forecast', days: [
        WeatherDay(date: '2026-09-16', tempMinC: 14, tempMaxC: 22),
      ]),
      'Paris|2026-09-16': const WeatherReport(kind: 'forecast', days: [
        WeatherDay(date: '2026-09-17', tempMinC: 16, tempMaxC: 25),
      ]),
    });
    await _pump(
      tester,
      trip: _trip(endDate: '2026-09-17', items: [
        _item(0, 'Louvre', 1),
        _item(1, 'Promenade', 2, city: 'Nice'),
        _item(2, 'Orsay', 3),
      ]),
      weather: weather,
    );
    await _openSheet(tester);

    // Two Paris rows with their own visit windows and temps, Nice between.
    // Displayed dates AND the weather queries are both the VISIBLE ranges
    // (arrival-inclusive, matching the city headers), so the guidance can
    // never describe a window the traveler was never shown.
    expect(_inRecs('Paris · Sep 15 · 8° – 15°'), findsOneWidget);
    expect(_inRecs('Nice · Sep 15 – Sep 16 · 14° – 22°'), findsOneWidget);
    expect(_inRecs('Paris · Sep 16 – Sep 17 · 16° – 25°'), findsOneWidget);
    // Both Paris visit windows were genuinely queried (per-visit keys).
    expect(weather.calls, contains('Paris|2026-09-15'));
    expect(weather.calls, contains('Paris|2026-09-16'));
    // Header summary spans all three legs: 8..25, no rain.
    expect(find.text('8° – 25°'), findsOneWidget);
  });

  testWidgets('consecutive same-guidance legs merge into one grouped row',
      (tester) async {
    // Paris and Nice both derive warm with no advisories → one row with the
    // joined labels and the merged envelope. Exactly one band phrase pins the
    // fold (a regression to per-leg rows would find two). The header summary
    // is computed from the UNGROUPED per-leg recs and must agree (exact-text
    // match: the grouped row's longer string can't satisfy it).
    final weather = _MapWeatherApiService({
      'Paris|2026-09-15': const WeatherReport(kind: 'forecast', days: [
        WeatherDay(date: '2026-09-15', tempMinC: 16, tempMaxC: 24),
      ]),
      'Nice|2026-09-15': const WeatherReport(kind: 'forecast', days: [
        WeatherDay(date: '2026-09-16', tempMinC: 15, tempMaxC: 23),
      ]),
    });
    await _pump(
      tester,
      trip: _trip(items: [
        _item(0, 'Louvre', 1),
        _item(1, 'Promenade', 2, city: 'Nice'),
      ]),
      weather: weather,
    );
    await _openSheet(tester);

    expect(find.text('15° – 24°'), findsOneWidget);
    expect(
        _inRecs('Paris, Nice · Sep 15 – Sep 16 · 15° – 24°'), findsOneWidget);
    expect(_inRecs('Warm — summer clothes, a light evening layer'),
        findsOneWidget);
    expect(_inRecs('Beyond the 16-day forecast'), findsNothing);
    // The display merged, but weather stayed per-leg.
    expect(weather.calls, contains('Paris|2026-09-15'));
    expect(weather.calls, contains('Nice|2026-09-15'));
  });

  testWidgets('forecast + historical legs still merge; one footnote total',
      (tester) async {
    // Kind must not block the fold — the nuance moves into the single
    // footnote, which renders once for the whole block.
    final weather = _MapWeatherApiService({
      'Paris|2026-09-15': const WeatherReport(kind: 'forecast', days: [
        WeatherDay(date: '2026-09-15', tempMinC: 16, tempMaxC: 24),
      ]),
      'Nice|2026-09-15': const WeatherReport(kind: 'historical', days: [
        WeatherDay(date: '2025-09-16', tempMinC: 15, tempMaxC: 23),
      ]),
    });
    await _pump(
      tester,
      trip: _trip(items: [
        _item(0, 'Louvre', 1),
        _item(1, 'Promenade', 2, city: 'Nice'),
      ]),
      weather: weather,
    );
    await _openSheet(tester);

    expect(
        _inRecs('Paris, Nice · Sep 15 – Sep 16 · 15° – 24°'), findsOneWidget);
    expect(
        _inRecs('Beyond the 16-day forecast, ranges show typical weather'
            ' for these dates.'),
        findsOneWidget);
    expect(_inRecs('typical for these dates'), findsNothing);
  });

  testWidgets('a leg with an empty report drops out; the rest still render',
      (tester) async {
    final weather = _MapWeatherApiService({
      'Paris|2026-09-15': const WeatherReport(kind: 'forecast', days: [
        WeatherDay(date: '2026-09-15', tempMinC: 16, tempMaxC: 24),
      ]),
      // Nice deliberately absent → empty report (provider failure contract).
    });
    await _pump(
      tester,
      trip: _trip(items: [
        _item(0, 'Louvre', 1),
        _item(1, 'Promenade', 2, city: 'Nice'),
      ]),
      weather: weather,
    );
    await _openSheet(tester);

    // Summary is Paris's envelope alone — the unresolved leg can't zero it.
    expect(find.text('16° – 24°'), findsOneWidget);
    expect(_inRecs('Paris · Sep 15'), findsOneWidget);
    expect(_inRecs('Nice'), findsNothing);
  });

  testWidgets('read-only viewer with an empty checklist still sees the recs',
      (tester) async {
    await _pump(
      tester,
      trip: _trip(access: 'viewer'),
      report: _warmRainyForecast,
    );

    expect(_wearIcon(), findsOneWidget);
    await _openSheet(tester);

    expect(find.text('What to wear & pack'), findsOneWidget);
    expect(find.text('15° – 24° · rain likely'), findsOneWidget);
    // No checked pill for an empty checklist.
    expect(find.text('0/0'), findsNothing);
    expect(_inRecs('Warm — summer clothes'), findsOneWidget);
    // Viewer + empty checklist: no add affordance, no checkboxes, and no
    // dangling divider under the recs (the checklist rendered nothing).
    expect(find.byType(Checkbox), findsNothing);
    expect(find.textContaining('Add an item'), findsNothing);
    expect(_sheetDividers(), findsNothing);
  });

  testWidgets('no weather: gating is exactly the old checklist behavior',
      (tester) async {
    // Viewer + empty checklist + empty weather → no icon at all.
    await _pump(
      tester,
      trip: _trip(access: 'viewer'),
      report: const WeatherReport(),
    );
    expect(_wearIcon(), findsNothing);
    expect(find.text('What to wear & pack'), findsNothing);
  });

  testWidgets('no weather, owner: checklist-only sheet with the count summary',
      (tester) async {
    await _pump(
      tester,
      trip: _trip(),
      report: const WeatherReport(),
      checklist: const [
        ChecklistItem(id: 'c1', category: 'general', title: 'Umbrella'),
      ],
    );

    // The checklist gate alone shows the icon.
    expect(_wearIcon(), findsOneWidget);
    await _openSheet(tester);

    expect(find.text('What to wear & pack'), findsOneWidget);
    // Old summary shape (checked of total), no envelope text anywhere.
    expect(find.textContaining('° – '), findsNothing);
    expect(find.textContaining('0/1'), findsNothing); // count is not a pill…
    expect(find.textContaining('0 of 1'), findsOneWidget); // …but the summary
  });

  testWidgets('ticking a checkbox in the sheet live-updates the header pill',
      (tester) async {
    // Pins the sheet's snapshot/live split: regions freeze at open, but the
    // checklist half (rows AND the header pill) watches the provider the
    // toggle invalidates, so an edit made inside the sheet lands live.
    final api = _MutableChecklistApiService([
      const ChecklistItem(id: 'c1', category: 'general', title: 'Umbrella'),
      const ChecklistItem(
          id: 'c2', category: 'clothing', title: 'Jacket', checked: true),
    ]);
    await _pump(
      tester,
      trip: _trip(),
      report: _warmRainyForecast,
      checklistApi: api,
    );
    await _openSheet(tester);
    expect(find.text('1/2'), findsOneWidget);

    await tester.tap(find
        .byWidgetPredicate((w) => w is Checkbox && w.value == false));
    await tester.pumpAndSettle();

    expect(find.text('2/2'), findsOneWidget);
    // The weather half kept its snapshot — summary unchanged.
    expect(find.text('15° – 24° · rain likely'), findsOneWidget);
  });

  testWidgets('Escape dismisses the sheet', (tester) async {
    await _pump(
      tester,
      trip: _trip(),
      report: _warmRainyForecast,
      checklist: const [
        ChecklistItem(id: 'c1', category: 'general', title: 'Umbrella'),
      ],
    );
    await _openSheet(tester);
    expect(find.byType(WearPackSheetBody), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(WearPackSheetBody), findsNothing);
  });

  testWidgets('icon shows on phone and desktop widths (not narrow-gated)',
      (tester) async {
    await _pump(
      tester,
      trip: _trip(),
      report: _warmRainyForecast,
      size: const Size(390, 800),
    );
    expect(_wearIcon(), findsOneWidget);

    await _pump(
      tester,
      trip: _trip(),
      report: _warmRainyForecast,
      size: const Size(1200, 800),
    );
    expect(_wearIcon(), findsOneWidget);
  });

  testWidgets('the icon stays put in the Budget view', (tester) async {
    // The old body row was suppressed under Budget; the app-bar icon is not
    // view-gated (the health precedent) — packing stays one tap away.
    await _pump(
      tester,
      trip: _trip(),
      report: _warmRainyForecast,
      checklist: const [
        ChecklistItem(id: 'c1', category: 'general', title: 'Umbrella'),
      ],
    );
    await tester.tap(find.text('Budget'));
    await tester.pumpAndSettle();

    expect(_wearIcon(), findsOneWidget);
    await _openSheet(tester);
    expect(find.text('15° – 24° · rain likely'), findsOneWidget);
  });

  testWidgets('renders the Spanish strings under the es locale',
      (tester) async {
    // The locale provider sets Intl.defaultLocale in the real app; tests set
    // it explicitly (same pattern as guides_polish_test.dart).
    await initializeDateFormatting('es');
    Intl.defaultLocale = 'es';
    addTearDown(() => Intl.defaultLocale = null);

    await _pump(
      tester,
      trip: _trip(),
      report: _warmRainyForecast,
      locale: const Locale('es'),
    );

    expect(_wearIcon(tooltip: 'Qué ponerte y qué llevar'), findsOneWidget);
    await _openSheet(tester, tooltip: 'Qué ponerte y qué llevar');
    expect(find.text('Qué ponerte y qué llevar'), findsOneWidget);
    expect(find.textContaining('lluvia probable'), findsWidgets);
    expect(
        find.descendant(
            of: find.byType(WearRecsList),
            matching: find.textContaining('Cálido — ropa de verano')),
        findsOneWidget);
  });

  testWidgets('renders the Spanish footnote for historical data',
      (tester) async {
    await initializeDateFormatting('es');
    Intl.defaultLocale = 'es';
    addTearDown(() => Intl.defaultLocale = null);

    await _pump(
      tester,
      trip: _trip(),
      report: _dryHistorical,
      locale: const Locale('es'),
    );
    await _openSheet(tester, tooltip: 'Qué ponerte y qué llevar');

    expect(
        find.descendant(
            of: find.byType(WearRecsList),
            matching:
                find.textContaining('el tiempo habitual en estas fechas')),
        findsOneWidget);
  });
}
