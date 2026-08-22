import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/widgets/booking_migration_dialog.dart';

import 'support/l10n_test_app.dart';

/// The migrate_booking finding's three-way choice (stale-transport-orphans
/// ticket 2): the traveler — never the app — decides what happens to a booked
/// checklist row the route left behind. Move it onto the replacement leg,
/// keep it as an other-booking, or remove it.

Future<void> _pumpAndOpen(
  WidgetTester tester, {
  Locale? locale,
  required void Function(BookingMigrationChoice?) onResult,
  String message =
      'Your booked transport Gothenburg → Sorrento no longer matches the route — those two places are not consecutive stops anymore.',
  String moveLabel = 'Move booking to Gothenburg → Naples (Sep 13)',
}) async {
  await tester.pumpWidget(
    localizedTestApp(
      locale: locale,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              onResult(await showBookingMigrationDialog(
                context,
                message: message,
                moveLabel: moveLabel,
              ));
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('presents the three-way choice, naming the finding',
      (tester) async {
    await _pumpAndOpen(tester, onResult: (_) {});

    expect(find.text('Move this booking?'), findsOneWidget);
    // The finding's own message names the stale pair.
    expect(find.textContaining('Gothenburg → Sorrento'), findsOneWidget);
    // The three choices: move (naming the replacement leg), keep, remove.
    expect(find.text('Move booking to Gothenburg → Naples (Sep 13)'),
        findsOneWidget);
    expect(find.text('Keep as other booking'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
  });

  testWidgets('move resolves to BookingMigrationChoice.move', (tester) async {
    BookingMigrationChoice? result;
    await _pumpAndOpen(tester, onResult: (r) => result = r);
    await tester
        .tap(find.text('Move booking to Gothenburg → Naples (Sep 13)'));
    await tester.pumpAndSettle();
    expect(result, BookingMigrationChoice.move);
  });

  testWidgets('keep resolves to BookingMigrationChoice.keep', (tester) async {
    BookingMigrationChoice? result;
    await _pumpAndOpen(tester, onResult: (r) => result = r);
    await tester.tap(find.text('Keep as other booking'));
    await tester.pumpAndSettle();
    expect(result, BookingMigrationChoice.keep);
  });

  testWidgets('remove resolves to BookingMigrationChoice.remove',
      (tester) async {
    BookingMigrationChoice? result;
    await _pumpAndOpen(tester, onResult: (r) => result = r);
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(result, BookingMigrationChoice.remove);
  });

  testWidgets('dismissing resolves null — no choice made', (tester) async {
    var called = false;
    BookingMigrationChoice? result = BookingMigrationChoice.keep;
    await _pumpAndOpen(tester, onResult: (r) {
      called = true;
      result = r;
    });
    await tester.tapAt(const Offset(10, 10)); // outside the dialog
    await tester.pumpAndSettle();
    expect(called, isTrue);
    expect(result, isNull);
  });

  testWidgets('Spanish copy renders', (tester) async {
    await _pumpAndOpen(tester, locale: const Locale('es'), onResult: (_) {});
    expect(find.text('¿Mover esta reserva?'), findsOneWidget);
    expect(find.text('Conservar como otra reserva'), findsOneWidget);
    expect(find.text('Quitar'), findsOneWidget);
  });
}
