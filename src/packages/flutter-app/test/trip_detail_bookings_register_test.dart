// Wave 3 bookings register cleanup: the trailing grammar every booking row
// speaks, and the dates a section head is allowed to claim.
//
// These cover paths that had NO coverage before this lane, which on this
// surface is the documented place bugs ship (#501's own edit/delete assertion
// was a `findsNothing` on a VIEWER row, where the affordance is null anyway):
//
//   1. BookingTodoCard's edit/delete moved into the kebab. Nothing asserted
//      they rendered at all for an EDITOR, so nothing would have caught the
//      fold dropping them.
//   2. A residual todo has no provider to search, so its action is null and
//      must not render — it used to sit there as a permanently greyed-out
//      filled button.
//   3. Section-head dates, guarded by the revisited-city rule proven in
//      trip_detail_derivation_test's section-head pin group.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/booking_todo.dart';
import 'package:travel_route_planner/models/itinerary_item.dart';
import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/screens/trip_detail_screen.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/widgets/booking_todo_card.dart';

import 'support/l10n_test_app.dart';

class _FakeTripsApiService extends TripsApiService {
  final Trip trip;
  _FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;
}

ItineraryItem _item(int pos, String name, String city, int day) =>
    ItineraryItem(
      id: 'i$pos',
      position: pos,
      name: name,
      address: '$name, $city',
      // Zero coords so the screen skips the map widget in the test env.
      latitude: 0,
      longitude: 0,
      category: 'attraction',
      city: city,
      day: day,
    );

BookingTodo _todo(String kind, String key, String title,
        {bool auto = true, String? subtitle}) =>
    BookingTodo(
      id: key,
      kind: kind,
      todoKey: key,
      title: title,
      auto: auto,
      subtitle: subtitle,
    );

/// Paris (days 1-2) → Rome (day 3) → Paris again (day 4): Rome owns exactly
/// one leg (a head that CAN carry dates), Paris owns two (one that cannot).
Trip _trip({List<BookingTodo>? todos}) => Trip(
      id: 't1',
      title: 'Europe',
      startDate: '2026-06-10',
      endDate: '2026-06-13',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: [
        _item(0, 'Louvre', 'Paris', 1),
        _item(1, 'Café de Flore', 'Paris', 2),
        _item(2, 'Colosseum', 'Rome', 3),
        _item(3, 'Louvre again', 'Paris', 4),
      ],
      bookingTodos: todos ??
          [
            _todo('stay', 'stay:paris', 'Stay in Paris'),
            _todo('transport', 'transport:paris>>rome', 'Paris → Rome'),
            _todo('stay', 'stay:rome', 'Stay in Rome'),
            _todo('other', 'custom:x', 'Museum tickets', auto: false),
          ],
    );

void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> _pump(WidgetTester tester, Trip trip) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripsApiServiceProvider.overrideWithValue(_FakeTripsApiService(trip)),
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: TripDetailScreen(tripId: 't1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openBookingsTab(WidgetTester tester) async {
  await tester.tap(find.text('Bookings'));
  await tester.pumpAndSettle();
}

void main() {
  group('BookingTodoCard trailing register', () {
    testWidgets('an editor gets edit + remove inside the kebab, not as peers',
        (tester) async {
      _useTallViewport(tester);
      await _pump(tester, _trip());
      await _openBookingsTab(tester);

      final card = find.widgetWithText(BookingTodoCard, 'Museum tickets');
      expect(card, findsOneWidget);

      // The two peer icon buttons are gone from the card…
      expect(find.descendant(of: card, matching: find.byIcon(Icons.edit_outlined)),
          findsNothing);
      expect(find.descendant(of: card, matching: find.byIcon(Icons.delete_outline)),
          findsNothing);

      // …and both actions survive, housed in the row's one overflow. This is
      // the assertion that makes the fold a register change rather than a
      // feature removal.
      final kebab =
          find.descendant(of: card, matching: find.byIcon(Icons.more_vert));
      expect(kebab, findsOneWidget);
      await tester.tap(kebab);
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
    });

    testWidgets('a residual todo renders no action and no "Booked" label',
        (tester) async {
      _useTallViewport(tester);
      await _pump(tester, _trip());
      await _openBookingsTab(tester);

      final card = find.widgetWithText(BookingTodoCard, 'Museum tickets');
      // A custom todo has no provider, so `onOpen` is null: the action is
      // withheld rather than rendered permanently disabled.
      expect(find.descendant(of: card, matching: find.text('Open search')),
          findsNothing);
      // The checkbox carries the state on its own, as it does on every slim
      // row; the word beside it was a second spelling of the same fact.
      expect(find.descendant(of: card, matching: find.text('Booked')),
          findsNothing);
      // The state itself is untouched — one checkbox, still there. The
      // bookings filter test counts these, so this is load-bearing.
      expect(find.descendant(of: card, matching: find.byType(Checkbox)),
          findsOneWidget);
    });

    testWidgets('the card reads at the slim rows\' height, not twice it',
        (tester) async {
      _useTallViewport(tester);
      await _pump(tester, _trip());
      await _openBookingsTab(tester);

      final cardH = tester
          .getSize(find.widgetWithText(BookingTodoCard, 'Museum tickets'))
          .height;
      final rowH = tester
          .getSize(find.widgetWithText(BookingTodoRow, 'Stay in Rome'))
          .height;
      // Was ~2x: a two-line card (title row + Booked/action row) against a
      // one-line row. Both carry a subtitle slot, so a small delta is fine —
      // what must not come back is the doubled register.
      expect(cardH, lessThan(rowH * 1.5),
          reason: 'residual card $cardH vs slim row $rowH');
    });
  });

  group('section-head dates', () {
    testWidgets('a head owning ONE leg carries that leg\'s visible dates',
        (tester) async {
      _useTallViewport(tester);
      await _pump(tester, _trip());
      await _openBookingsTab(tester);

      // Rome is one leg, so its head can speak for it. The string is the same
      // chip the itinerary city header renders — Rome's items sit on day 3,
      // but the leg RENDERS from its arrival (the previous leg's visible end,
      // Jun 11), which is the visibleLegRanges rule. A head derived from the
      // raw ranges would have said "Jun 12" and contradicted the city header.
      //
      // Anchored on the DATE, not on 'Rome': the destination filter chip also
      // renders the bare label, so scoping the other way round picks the chip.
      final date = find.text('Jun 11 – Jun 12');
      expect(date, findsOneWidget);
      final head = find.ancestor(of: date, matching: find.byType(Row)).first;
      expect(find.descendant(of: head, matching: find.text('Rome')),
          findsOneWidget);
    });

    testWidgets('a revisited city\'s head stays silent rather than pick a run',
        (tester) async {
      _useTallViewport(tester);
      await _pump(tester, _trip());
      await _openBookingsTab(tester);

      // Paris owns legs 0 and 2 — two genuinely different windows merged into
      // ONE section. Showing either would re-create the label-keyed range map
      // TripDerivation deleted for collapsing revisits onto one window, so the
      // head shows no date at all.
      //
      // Both windows are named explicitly. Asserting only "the head has no
      // date" would pass just as well if the feature had silently stopped
      // working everywhere; naming the two strings that MUST NOT appear is
      // what makes this fail for the right reason.
      expect(find.text('Paris'), findsWidgets); // the section is there…
      expect(find.text('Jun 10 – Jun 11'), findsNothing); // …run 1's window
      expect(find.text('Jun 12 – Jun 13'), findsNothing); // …and run 2's
    });
  });
}
