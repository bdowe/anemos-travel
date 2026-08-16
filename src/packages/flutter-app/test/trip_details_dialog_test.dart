import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/trip_details_dialog.dart';

import 'support/l10n_test_app.dart';

/// The trip page's editor for a trip's name and description
/// (specs/trip-description).
///
/// Before it, `trips.summary` was write-once at creation: the traveler could not
/// fix the blurb the planner wrote, and the planner could not either once the
/// trip was saved. The header pencil used to rename only.

class _FakeTripsApiService extends TripsApiService {
  Trip trip;

  /// Every patch this fake received, as (title, summary). The summary entry is
  /// the point: `null` means the key was omitted and `''` means an explicit
  /// clear, and the two must not collapse into each other.
  final List<(String?, String?)> patches = [];

  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;

  @override
  Future<Trip> patchTrip(
    String id, {
    String? title,
    String? startDate,
    String? endDate,
    String? summary,
  }) async {
    patches.add((title, summary));
    trip = Trip(
      id: trip.id,
      title: title ?? trip.title,
      summary: (summary == null || summary.isEmpty) ? null : summary,
      startDate: trip.startDate,
      endDate: trip.endDate,
      createdAt: trip.createdAt,
      updatedAt: trip.updatedAt,
      access: trip.access,
      items: trip.items,
    );
    return trip;
  }
}

ItineraryItem _item(int pos, String name, String city) => ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$city, IT',
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: pos + 1,
      city: city,
    );

Trip _trip({String title = 'Sicily in September', String? summary, String? access}) =>
    Trip(
      id: 't1',
      title: title,
      summary: summary,
      startDate: '2026-09-12',
      endDate: '2026-09-16',
      createdAt: '2026-08-01',
      updatedAt: '2026-08-01',
      access: access,
      items: [
        _item(0, 'Teatro Massimo', 'Palermo'),
        _item(1, 'Teatro Romano', 'Catania'),
      ],
    );

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pumpTrip(WidgetTester tester, _FakeTripsApiService trips) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [tripsApiServiceProvider.overrideWithValue(trips)],
      child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: const TripDetailScreen(tripId: 't1')),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openEditor(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Edit trip details'));
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.widgetWithText(TextField, label);

void main() {
  testWidgets('the header pencil edits the name and the description together',
      (tester) async {
    _useTallViewport(tester);
    final trips = _FakeTripsApiService(
        _trip(summary: 'Three days around Palermo.'));
    await _pumpTrip(tester, trips);
    await _openEditor(tester);

    // Both fields arrive seeded with what the page was showing.
    expect(find.byType(TripDetailsEdit), findsNothing); // value object, not a widget
    expect(
        tester.widget<TextField>(_field('Name')).controller?.text,
        'Sicily in September');
    expect(
        tester.widget<TextField>(_field('Description')).controller?.text,
        'Three days around Palermo.');

    await tester.enterText(_field('Name'), 'Sicily Loop');
    await tester.enterText(
        _field('Description'), '  Ten days circling Sicily.  ');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    // One request carries both, and the description is trimmed.
    expect(trips.patches, [('Sicily Loop', 'Ten days circling Sicily.')]);
    // The page re-seeds from the server's response rather than a hopeful local
    // value, so the new prose is what is now on screen.
    expect(find.text('Ten days circling Sicily.'), findsOneWidget);
  });

  testWidgets('emptying the description sends an explicit clear',
      (tester) async {
    _useTallViewport(tester);
    final trips =
        _FakeTripsApiService(_trip(summary: 'Three days around Palermo.'));
    await _pumpTrip(tester, trips);
    await _openEditor(tester);

    await tester.enterText(_field('Description'), '');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    // '' not null: null would mean "leave it alone", and the traveler asked for
    // it to go. This is the distinction UpdateTrip's COALESCE could not carry.
    expect(trips.patches, [('Sicily in September', '')]);
    expect(find.text('Three days around Palermo.'), findsNothing);
  });

  testWidgets('a blank name cannot be saved', (tester) async {
    _useTallViewport(tester);
    final trips = _FakeTripsApiService(_trip(summary: 'A blurb.'));
    await _pumpTrip(tester, trips);
    await _openEditor(tester);

    await tester.enterText(_field('Name'), '   ');
    await tester.pumpAndSettle();

    final save =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
    expect(save.onPressed, isNull,
        reason: 'the server rejects a blank title, so Save must not offer one');
    expect(find.text('A trip needs a name'), findsOneWidget);
    // And the description stays editable while the name is invalid — only Save
    // is blocked.
    await tester.enterText(_field('Description'), 'Still typing.');
    await tester.pumpAndSettle();
    expect(trips.patches, isEmpty);
  });

  testWidgets('a legacy trip promotes its long title into the description',
      (tester) async {
    _useTallViewport(tester);
    // Pre-00013 shape: no summary, and the prose IS the title. The header shows
    // a computed short title above that prose, so the editor must offer what is
    // on screen — otherwise it would show an empty description box underneath a
    // description the traveler can plainly read.
    final trips = _FakeTripsApiService(_trip(
      title: 'A ten day loop of Sicily taking in Palermo, Agrigento and '
          'Catania, with time for the beaches in between.',
    ));
    await _pumpTrip(tester, trips);
    await _openEditor(tester);

    final name = tester.widget<TextField>(_field('Name')).controller!.text;
    final description =
        tester.widget<TextField>(_field('Description')).controller!.text;
    expect(description, startsWith('A ten day loop of Sicily'));
    expect(name, isNot(contains('Agrigento')),
        reason: 'the name field must offer the computed short title, not the prose');

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(trips.patches, hasLength(1));
    final (savedTitle, savedSummary) = trips.patches.single;
    expect(savedSummary, startsWith('A ten day loop of Sicily'));
    expect(savedTitle, isNot(contains('Agrigento')));
  });

  testWidgets('a viewer gets no pencil', (tester) async {
    _useTallViewport(tester);
    final trips = _FakeTripsApiService(
        _trip(summary: 'Three days around Palermo.', access: 'viewer'));
    await _pumpTrip(tester, trips);

    expect(find.byTooltip('Edit trip details'), findsNothing);
    // The description itself still renders — a viewer reads the trip, they just
    // don't write it.
    expect(find.text('Three days around Palermo.'), findsOneWidget);
  });
}
