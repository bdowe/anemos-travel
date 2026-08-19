// A saved booking's edit/delete affordances (specs — bookings tab redesign,
// wave 2). Before the redesign these were two bare IconButtons at the end of
// the row, so a confirmed record — the CHILD of the todo row above it — ended
// in more trailing weight than its own parent, with a destructive delete one
// pixel from a routine edit. They fold into ONE overflow menu now.
//
// This file exists because NOTHING covered the editor path: the only edit-icon
// assertion in the suite is `findsNothing` on a VIEWER row
// (trip_detail_booking_lockstep_test.dart), which passes with or without the
// affordance and so proves nothing about it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/accommodation.dart';
import 'package:travel_route_planner/models/trip_segment.dart';
import 'package:travel_route_planner/widgets/booking_detail_row.dart';

import 'support/l10n_test_app.dart';

const _stay = Accommodation(
  id: 'a1',
  name: 'Hotel Lutetia',
  checkIn: '2026-06-10',
  checkOut: '2026-06-12',
);

const _segment = TripSegment(
  id: 's1',
  mode: 'train',
  origin: 'Paris',
  destination: 'Rome',
  departDate: '2026-06-12',
);

Future<void> _pump(WidgetTester tester, Widget row) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: Scaffold(body: SingleChildScrollView(child: row)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an editable stay row carries one kebab, not bare icons',
      (tester) async {
    await _pump(
      tester,
      BookingDetailRow.stay(
        tripId: 't1',
        stay: _stay,
        onEdit: () {},
        onDelete: () {},
      ),
    );

    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    // The register fix itself: edit and delete no longer sit in the row.
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  testWidgets('the kebab drives edit and delete for a stay', (tester) async {
    var edited = 0, deleted = 0;
    await _pump(
      tester,
      BookingDetailRow.stay(
        tripId: 't1',
        stay: _stay,
        onEdit: () => edited++,
        onDelete: () => deleted++,
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit stay'));
    await tester.pumpAndSettle();
    expect((edited, deleted), (1, 0));

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove stay'));
    await tester.pumpAndSettle();
    expect((edited, deleted), (1, 1));
  });

  testWidgets('a transport row names transport in its menu', (tester) async {
    var edited = 0, deleted = 0;
    await _pump(
      tester,
      BookingDetailRow.segment(
        tripId: 't1',
        segment: _segment,
        onEdit: () => edited++,
        onDelete: () => deleted++,
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    // Stay wording on a transport row would be the copy bug the two-tooltip
    // spelling was there to avoid.
    expect(find.text('Edit stay'), findsNothing);
    await tester.tap(find.text('Edit transport'));
    await tester.pumpAndSettle();
    expect((edited, deleted), (1, 0));

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove transport'));
    await tester.pumpAndSettle();
    expect((edited, deleted), (1, 1));
  });

  testWidgets('a row with neither callback shows no kebab at all',
      (tester) async {
    // Viewers and offline copies: an overflow button opening an empty menu is
    // worse than the two icons it replaced.
    await _pump(tester, const BookingDetailRow.stay(tripId: 't1', stay: _stay));
    expect(find.byIcon(Icons.more_vert), findsNothing);
  });

  testWidgets('a row with only one callback offers only that entry',
      (tester) async {
    await _pump(
      tester,
      BookingDetailRow.stay(tripId: 't1', stay: _stay, onEdit: () {}),
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('Edit stay'), findsOneWidget);
    expect(find.text('Remove stay'), findsNothing);
  });
}
