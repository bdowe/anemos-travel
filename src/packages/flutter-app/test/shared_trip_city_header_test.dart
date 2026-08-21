// The shared trip view's city header and its one-line run of place names
// (specs artifact: share-view-calendar-days).
//
// **These tests assert structure, presence, ordering and the dateless /
// zero-night branches — never layout.** This suite installs no
// `flutter_test_config.dart` and loads no fonts, so every width, line count,
// wrap point and overflow it could measure would be a fact about Flutter's
// built-in test font and not about the shipped app. The wide/narrow rendering
// and the fold of a long places run were verified in the running app at real
// widths instead, and the assertions that would have pinned them are
// deliberately absent.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/shared_trip.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/shared_trip_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';

import 'support/l10n_test_app.dart';

class _FakeTripsApiService extends TripsApiService {
  final SharedTrip shared;
  _FakeTripsApiService(this.shared) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<SharedTrip> getSharedTrip(String token) async => shared;
}

ItineraryItem _item(int pos, String name, {String? city, String? address}) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      city: city,
      address: address,
      // A day number on every item: these tests have to be able to see that
      // nothing renders "Day N" any more, which needs the data that used to
      // produce it to still be present.
      day: pos + 1,
    );

SharedTrip _shared(
  List<ItineraryItem> items, {
  String? startDate = '2026-09-01',
  String? endDate = '2026-09-05',
}) =>
    SharedTrip(
      ownerName: 'Ann',
      trip: Trip(
        id: 't1',
        title: 'Grand tour',
        createdAt: '2026-06-01',
        updatedAt: '2026-06-01',
        startDate: startDate,
        endDate: endDate,
        items: items,
      ),
    );

void main() {
  Future<void> pumpScreen(WidgetTester tester, SharedTrip shared) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tripsApiServiceProvider
              .overrideWithValue(_FakeTripsApiService(shared)),
        ],
        child: localizedTestApp(home: SharedTripScreen(token: 'tok')),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The rendered text of a city's places run, as one string.
  String placesTextFor(WidgetTester tester, int index) {
    final line = tester
        .widgetList<SharedCityPlacesLine>(find.byType(SharedCityPlacesLine))
        .toList()[index];
    // Rebuilt from the widget's own inputs would prove nothing; read what the
    // element actually painted.
    final richText = tester.widget<RichText>(
      find
          .descendant(
            of: find.byWidget(line),
            matching: find.byType(RichText),
          )
          .first,
    );
    return richText.text.toPlainText();
  }

  group('the day pills are gone', () {
    testWidgets('no "Day N" text survives anywhere on the screen',
        (WidgetTester tester) async {
      await pumpScreen(
        tester,
        _shared([
          _item(0, 'Louvre', city: 'Paris'),
          _item(1, 'Orsay', city: 'Paris'),
        ]),
      );

      // The items still CARRY day numbers (see [_item]) — nothing renders them.
      expect(find.textContaining('Day '), findsNothing);
      // And the numbered circles that shadowed the map's per-CITY pins are
      // gone with them: no per-place list rows at all.
      expect(find.byType(ListTile), findsNothing);
    });
  });

  group('the city header carries the leg dates', () {
    testWidgets('a dated trip renders the range, and the nights beside it',
        (WidgetTester tester) async {
      await pumpScreen(
        tester,
        _shared([
          _item(0, 'Louvre', city: 'Paris'),
          _item(1, 'Colosseum', city: 'Rome'),
        ]),
      );

      final headers = tester
          .widgetList<SharedCityHeader>(find.byType(SharedCityHeader))
          .toList();
      expect(headers.map((h) => h.label), ['Paris', 'Rome']);
      // Both legs land inside the trip's own span, so both get a range.
      expect(headers.every((h) => h.range != null), isTrue);
      // The nights label owns its leading middot — asserted here so a future
      // refactor that folds it into the range string fails loudly.
      for (final h in headers) {
        if (h.nights != null) expect(h.nights, startsWith('· '));
      }
    });

    testWidgets(
        'a DATELESS trip renders the city name and no range — never a day '
        'number, never an invented date', (WidgetTester tester) async {
      await pumpScreen(
        tester,
        _shared(
          [
            _item(0, 'Louvre', city: 'Paris'),
            _item(1, 'Colosseum', city: 'Rome'),
          ],
          startDate: null,
          endDate: null,
        ),
      );

      final headers = tester
          .widgetList<SharedCityHeader>(find.byType(SharedCityHeader))
          .toList();
      expect(headers.map((h) => h.label), ['Paris', 'Rome']);
      // The absence is carried, not substituted for.
      expect(headers.every((h) => h.range == null), isTrue);
      expect(headers.every((h) => h.nights == null), isTrue);
      // The city names are still on screen; only the dates are absent.
      expect(
        find.descendant(
          of: find.byType(SharedCityHeader),
          matching: find.text('Paris'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Day '), findsNothing);
    });

    testWidgets(
        'the unresolved-locality run still speaks this view\'s "Places", not '
        'trip detail\'s "Other places"', (WidgetTester tester) async {
      await pumpScreen(
        tester,
        // No city and no parseable address: falls into the kOtherPlacesLabel
        // bucket, which this screen renames via _sharedLegLabel. Three
        // surfaces speak that name and the header must not become a fourth.
        _shared([_item(0, 'A mystery stop')]),
      );

      final headers = tester
          .widgetList<SharedCityHeader>(find.byType(SharedCityHeader))
          .toList();
      expect(headers.single.label, 'Places');
      expect(find.text('Other places'), findsNothing);
    });
  });

  group('the zero-night rule is structural', () {
    // Pinned on the header widget directly rather than through a trip that
    // collapses a leg: the rule under test is "the middot leaves with the
    // nights", and the header is where that is decided.
    testWidgets('nights == null renders the range alone, with no middot',
        (WidgetTester tester) async {
      await tester.pumpWidget(localizedTestApp(
        home: const Scaffold(
          body: SharedCityHeader(
            label: 'Naxos',
            range: 'Sep 3 – Sep 3',
            nights: null,
            narrow: false,
          ),
        ),
      ));

      expect(find.text('Sep 3 – Sep 3'), findsOneWidget);
      // The middot lives in `tripLegNights`; with no nights there is no Text
      // carrying one, rather than a range string with a dangling separator.
      expect(find.textContaining('·'), findsNothing);
    });

    testWidgets('nights present renders as a SECOND Text, not one joined string',
        (WidgetTester tester) async {
      await tester.pumpWidget(localizedTestApp(
        home: const Scaffold(
          body: SharedCityHeader(
            label: 'Naxos',
            range: 'Sep 3 – Sep 6',
            nights: '· 3 nights',
            narrow: false,
          ),
        ),
      ));

      // Two Texts, found separately — a joined "$range · $nights" would fail
      // both of these and pass a single textContaining, which is why the
      // assertion is spelled this way.
      expect(find.text('Sep 3 – Sep 6'), findsOneWidget);
      expect(find.text('· 3 nights'), findsOneWidget);
    });

    testWidgets('the same two-Text rule holds in the stacked narrow form',
        (WidgetTester tester) async {
      await tester.pumpWidget(localizedTestApp(
        home: const Scaffold(
          body: SharedCityHeader(
            label: 'Naxos',
            range: 'Sep 3 – Sep 6',
            nights: '· 3 nights',
            narrow: true,
          ),
        ),
      ));

      expect(find.text('Sep 3 – Sep 6'), findsOneWidget);
      expect(find.text('· 3 nights'), findsOneWidget);
      // The stacked form drops the calendar glyph — the pin beside it already
      // anchors the row.
      expect(find.byIcon(Icons.event), findsNothing);
      expect(find.byIcon(Icons.location_on), findsOneWidget);
    });

    testWidgets('the wide form carries the calendar glyph the stacked one drops',
        (WidgetTester tester) async {
      await tester.pumpWidget(localizedTestApp(
        home: const Scaffold(
          body: SharedCityHeader(
            label: 'Naxos',
            range: 'Sep 3 – Sep 6',
            nights: '· 3 nights',
            narrow: false,
          ),
        ),
      ));

      expect(find.byIcon(Icons.event), findsOneWidget);
    });

    testWidgets('a dateless header renders neither a range nor a glyph',
        (WidgetTester tester) async {
      await tester.pumpWidget(localizedTestApp(
        home: const Scaffold(
          body: SharedCityHeader(
            label: 'Naxos',
            range: null,
            nights: null,
            narrow: false,
          ),
        ),
      ));

      expect(find.text('Naxos'), findsOneWidget);
      expect(find.byIcon(Icons.event), findsNothing);
    });
  });

  group('the places run', () {
    testWidgets('lists a city\'s places in itinerary order, separated by "·"',
        (WidgetTester tester) async {
      await pumpScreen(
        tester,
        _shared([
          _item(0, 'Louvre', city: 'Paris'),
          _item(1, 'Orsay', city: 'Paris'),
        ]),
      );

      expect(placesTextFor(tester, 0), 'Louvre · Orsay');
    });

    testWidgets(
        'a name that already contains a pipe survives intact — the separator '
        'is "·" and must never be "|"', (WidgetTester tester) async {
      await pumpScreen(
        tester,
        _shared([
          _item(0, 'SOVA | Modern Czech Cuisine', city: 'Prague'),
          _item(1, 'Hemingway Bar', city: 'Prague'),
        ]),
      );

      final text = placesTextFor(tester, 0);
      expect(text, contains('SOVA | Modern Czech Cuisine'));
      expect(text, 'SOVA | Modern Czech Cuisine · Hemingway Bar');
    });

    testWidgets('caps a long run with the "+N more" idiom',
        (WidgetTester tester) async {
      // Nine places in one city, against the wide cap of six.
      await pumpScreen(
        tester,
        _shared([
          for (var i = 0; i < 9; i++) _item(i, 'Place $i', city: 'Krakow'),
        ]),
      );

      final text = placesTextFor(tester, 0);
      expect(text, endsWith('+3 more'));
      // The sixth is shown and the seventh is folded into the count.
      expect(text, contains('Place 5'));
      expect(text, isNot(contains('Place 6')));
    });

    testWidgets('a run at exactly the cap shows every place and no "+N more"',
        (WidgetTester tester) async {
      await pumpScreen(
        tester,
        _shared([
          for (var i = 0; i < 6; i++) _item(i, 'Place $i', city: 'Krakow'),
        ]),
      );

      final text = placesTextFor(tester, 0);
      expect(text, contains('Place 5'));
      expect(text, isNot(contains('more')));
    });
  });
}
