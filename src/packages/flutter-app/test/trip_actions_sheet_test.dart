import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/widgets/trip_actions_sheet.dart';

import 'support/l10n_test_app.dart';

// The trip's `⋮`, in its two faces.
//
// The contract:
//   * ONE ordered list of [TripAction] sections renders both faces, so the
//     sheet and the popup cannot come to offer different things — the
//     guarantee the share-entry builder used to give for six of ten rows;
//   * separators are DERIVED from section boundaries and empty sections drop
//     out, so a leading, trailing, or doubled divider is unrepresentable.
//     What this replaced fenced each block with a hand-written `||` chain
//     that grew a term per feature and was already a term out of step;
//   * every row has a leading icon. Six of them used to be bare `Text`, which
//     is what put two different left edges in one list;
//   * a destructive row tints icon AND label — a red label over a neutral
//     icon reads as a rendering slip, not a warning;
//   * choosing a row RETURNS the action; the caller invokes it after the
//     surface closes (share_plus must anchor on a live button, not a dead
//     sheet route).

// ---------------------------------------------------------------- renderers

TripAction _action(String label, {bool destructive = false, VoidCallback? on}) =>
    TripAction(
      icon: Icons.link,
      label: label,
      destructive: destructive,
      onSelected: on ?? () {},
    );

/// Pumps both faces over the same [sections] so a single test can compare
/// them. The popup is opened by tapping its button; the sheet by tapping the
/// other.
Future<void> _pumpBothFaces(
  WidgetTester tester,
  List<List<TripAction>> sections, {
  void Function(TripAction?)? onSheetResult,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Row(children: [
          PopupMenuButton<TripAction>(
            tooltip: 'popup',
            onSelected: (a) => a.onSelected(),
            itemBuilder: (c) => tripActionPopupEntries(c, sections),
          ),
          TextButton(
            child: const Text('open sheet'),
            onPressed: () async {
              final a =
                  await showTripActionsSheet(context, sections: sections);
              onSheetResult?.call(a);
            },
          ),
        ]),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('open sheet'));
  await tester.pumpAndSettle();
}

Future<void> _openPopup(WidgetTester tester) async {
  await tester.tap(find.byTooltip('popup'));
  await tester.pumpAndSettle();
}

/// Separators inside the sheet's own body — scoped so the drag handle and any
/// framework chrome can't be miscounted as one.
int _sheetDividers(WidgetTester tester) => tester
    .widgetList(find.descendant(
        of: find.byType(TripActionsSheetBody), matching: find.byType(Divider)))
    .length;

int _popupDividers(WidgetTester tester) =>
    tester.widgetList(find.byType(PopupMenuDivider)).length;

// -------------------------------------------------------------- trip screen

class _FakeTripsApiService extends TripsApiService {
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  final Trip trip;
  int revokes = 0;

  @override
  Future<Trip> getTrip(String id) async => trip;

  @override
  Future<void> revokeShareLink(String tripId) async => revokes++;
}

ItineraryItem _item(int pos, String city, int day) => ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: 'Stop $pos',
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      day: day,
      city: city,
    );

/// Two dated city runs, so the fold control has groups to act on. No weather
/// and no checklist, so the wear entry stays out and the list is the gates'
/// alone.
Trip _trip({String? access}) => Trip(
      id: 't1',
      title: 'Grand tour',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      startDate: '2026-06-01',
      endDate: '2026-06-04',
      access: access,
      ownerName: access == null ? null : 'Brian',
      items: [
        _item(0, 'Paris', 1),
        _item(1, 'Paris', 2),
        _item(2, 'Rome', 3),
        _item(3, 'Rome', 4),
      ],
    );

Future<void> _pumpTrip(
  WidgetTester tester,
  _FakeTripsApiService trips, {
  required Size surface,
}) async {
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [tripsApiServiceProvider.overrideWithValue(trips)],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: const TripDetailScreen(tripId: 't1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openOverflow(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More options'));
  await tester.pumpAndSettle();
}

void main() {
  group('the two faces render one list', () {
    testWidgets('sheet and popup offer the same labels, in the same order',
        (tester) async {
      final sections = [
        [_action('Collapse all'), _action('What to wear & pack')],
        [_action('Copy share link'), _action('Turn off sharing')],
        [_action('Delete trip', destructive: true)],
      ];
      await _pumpBothFaces(tester, sections);

      await _openPopup(tester);
      final fromPopup = tester
          .widgetList<Text>(find.descendant(
              of: find.byType(PopupMenuItem<TripAction>),
              matching: find.byType(Text)))
          .map((t) => t.data)
          .toList();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await _openSheet(tester);
      final fromSheet = tester
          .widgetList<Text>(find.descendant(
              of: find.byType(TripActionsSheetBody), matching: find.byType(Text)))
          .map((t) => t.data)
          .toList();

      expect(fromSheet, fromPopup);
      expect(fromSheet, [
        'Collapse all',
        'What to wear & pack',
        'Copy share link',
        'Turn off sharing',
        'Delete trip',
      ]);
    });

    testWidgets('every row carries a leading icon', (tester) async {
      await _pumpBothFaces(tester, [
        [_action('One'), _action('Two')],
        [_action('Three')],
      ]);

      await _openSheet(tester);
      // One icon per row, no row without one — the bare-Text regression.
      expect(
          find.descendant(
              of: find.byType(TripActionsSheetBody),
              matching: find.byType(Icon)),
          findsNWidgets(3));
      expect(
          find.descendant(
              of: find.byType(TripActionsSheetBody),
              matching: find.byType(ListTile)),
          findsNWidgets(3));
    });

    testWidgets('the sheet lets a long label wrap, the popup ellipsizes it',
        (tester) async {
      // Deliberately different. "Copy invite link (can edit)" in Spanish only
      // differs from the row above it by that parenthetical, and a sheet has
      // the room to show it; Material caps a popup at 280px, where a second
      // line buys a much taller menu for the same words.
      await _pumpBothFaces(tester, [
        [_action('Copiar enlace de invitación (puede editar)')]
      ]);

      await _openSheet(tester);
      expect(
          tester
              .widget<Text>(find.descendant(
                  of: find.byType(TripActionsSheetBody),
                  matching: find.byType(Text)))
              .maxLines,
          2);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await _openPopup(tester);
      expect(
          tester
              .widget<Text>(find.descendant(
                  of: find.byType(PopupMenuItem<TripAction>),
                  matching: find.byType(Text)))
              .maxLines,
          1);
    });

    testWidgets('a destructive row tints icon and label alike', (tester) async {
      await _pumpBothFaces(tester, [
        [_action('Keep')],
        [_action('Delete trip', destructive: true)],
      ]);
      await _openSheet(tester);

      final error = Theme.of(tester.element(find.text('Delete trip')))
          .colorScheme
          .error;
      final tile = find.widgetWithText(ListTile, 'Delete trip');
      final icon = tester.widget<Icon>(
          find.descendant(of: tile, matching: find.byType(Icon)));
      final label = tester.widget<Text>(find.text('Delete trip'));
      expect(icon.color, error);
      expect(label.style?.color, error);

      // …and a neighbouring row is left alone.
      final plain = tester.widget<Text>(find.text('Keep'));
      expect(plain.style?.color, isNot(error));
    });

    testWidgets('choosing a row returns it without invoking it',
        (tester) async {
      var ran = 0;
      TripAction? chosen;
      await _pumpBothFaces(
        tester,
        [
          [_action('Copy share link', on: () => ran++)]
        ],
        onSheetResult: (a) => chosen = a,
      );

      await _openSheet(tester);
      await tester.tap(find.text('Copy share link'));
      await tester.pumpAndSettle();

      // The sheet hands the action back; running it is the caller's job,
      // after the route is gone.
      expect(chosen?.label, 'Copy share link');
      expect(ran, 0);
    });

    testWidgets('dismissing the sheet resolves to null', (tester) async {
      var called = false;
      TripAction? chosen;
      await _pumpBothFaces(
        tester,
        [
          [_action('Copy share link')]
        ],
        onSheetResult: (a) {
          called = true;
          chosen = a;
        },
      );
      await _openSheet(tester);
      await tester.tapAt(const Offset(5, 5)); // barrier
      await tester.pumpAndSettle();
      expect(called, isTrue);
      expect(chosen, isNull);
    });
  });

  group('separators are derived, never placed', () {
    // One case per shape the gates can produce. The old hand-placed dividers
    // could emit a leading one (a block whose own gate was false while the
    // divider's guard was true) or a doubled one; neither is expressible now.
    final cases = <String, (List<List<TripAction>>, int)>{
      'one section has none': (
        [
          [_action('a'), _action('b')]
        ],
        0
      ),
      'two sections have one': (
        [
          [_action('a')],
          [_action('b')]
        ],
        1
      ),
      'an empty section between two does not double': (
        [
          [_action('a')],
          <TripAction>[],
          [_action('b')]
        ],
        1
      ),
      'a leading empty section does not lead with a divider': (
        [
          <TripAction>[],
          [_action('a')],
          [_action('b')]
        ],
        1
      ),
      'a trailing empty section does not trail with one': (
        [
          [_action('a')],
          [_action('b')],
          <TripAction>[]
        ],
        1
      ),
      'four sections have three': (
        [
          [_action('a')],
          [_action('b')],
          [_action('c')],
          [_action('d')]
        ],
        3
      ),
    };

    cases.forEach((name, spec) {
      final (sections, expected) = spec;
      testWidgets(name, (tester) async {
        await _pumpBothFaces(tester, sections);

        await _openSheet(tester);
        expect(_sheetDividers(tester), expected, reason: 'sheet');
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        await _openPopup(tester);
        expect(_popupDividers(tester), expected, reason: 'popup');
      });
    });

    testWidgets('a wholly empty list opens nothing', (tester) async {
      TripAction? chosen;
      var called = false;
      await _pumpBothFaces(
        tester,
        [<TripAction>[], <TripAction>[]],
        onSheetResult: (a) {
          called = true;
          chosen = a;
        },
      );
      await _openSheet(tester);
      expect(find.byType(TripActionsSheetBody), findsNothing);
      expect(called, isTrue);
      expect(chosen, isNull);
    });
  });

  group('on the trip page', () {
    testWidgets('narrow opens a sheet, wide a popup', (tester) async {
      final trips = _FakeTripsApiService(_trip());
      await _pumpTrip(tester, trips, surface: const Size(390, 1400));
      await _openOverflow(tester);
      expect(find.byType(TripActionsSheetBody), findsOneWidget);
      expect(find.byType(PopupMenuItem<TripAction>), findsNothing);
      // The whole point of the sheet: the share entries live here on a phone.
      // "Manage access" rather than the copy/share row, whose label swaps on
      // `shareUsesNativeSheet` — which the test platform reports as native.
      expect(find.text('Manage access'), findsOneWidget);
      expect(find.text('Collapse all'), findsOneWidget);
      expect(find.text('Delete trip'), findsOneWidget);
    });

    testWidgets('wide keeps the popup, down to the destructive exit',
        (tester) async {
      final trips = _FakeTripsApiService(_trip());
      await _pumpTrip(tester, trips, surface: const Size(1200, 1400));
      await _openOverflow(tester);
      expect(find.byType(TripActionsSheetBody), findsNothing);
      // Fold lives in the itinerary header at wide, share in its own button,
      // so one entry is left — behind a menu on purpose (#356), never a bare
      // trash icon.
      expect(find.byType(PopupMenuItem<TripAction>), findsOneWidget);
      expect(find.text('Delete trip'), findsOneWidget);
      expect(find.byType(PopupMenuDivider), findsNothing);
    });

    testWidgets('a viewer gets fold and leave, with one divider between',
        (tester) async {
      final trips = _FakeTripsApiService(_trip(access: 'viewer'));
      await _pumpTrip(tester, trips, surface: const Size(390, 1400));
      await _openOverflow(tester);

      expect(find.text('Collapse all'), findsOneWidget);
      expect(find.text('Remove from my trips'), findsOneWidget);
      // No sharing surface for a viewer, and the gap it leaves closes up.
      expect(find.text('Manage access'), findsNothing);
      expect(find.text('Delete trip'), findsNothing);
      expect(_sheetDividers(tester), 1);
    });

    testWidgets('turning off sharing confirms before it revokes',
        (tester) async {
      final trips = _FakeTripsApiService(_trip());
      await _pumpTrip(tester, trips, surface: const Size(390, 1400));

      // Cancel leaves the links alone.
      await _openOverflow(tester);
      await tester.tap(find.text('Turn off sharing'));
      await tester.pumpAndSettle();
      expect(find.text('Turn off sharing?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(trips.revokes, 0);

      // Confirming goes through.
      await _openOverflow(tester);
      await tester.tap(find.text('Turn off sharing'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Turn off'));
      await tester.pumpAndSettle();
      expect(trips.revokes, 1);
    });
  });
}
