import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/l10n/l10n.dart';
import 'package:travel_route_planner/theme/app_colors.dart';
import 'package:travel_route_planner/widgets/booking_filter_bar.dart';

import 'support/l10n_test_app.dart';

/// The Bookings view's filter row.
///
/// Everything asserted here is a **property or a callback** — which chip is
/// enabled, what ink it was told to paint, whether a tap reached the parent.
/// Nothing measures a size or a position: this suite has no
/// `flutter_test_config.dart` and loads no fonts, so a widget test lays out
/// with Flutter's fixed-width test font and any pixel claim about text would
/// be a claim about that font rather than about Inter.
///
/// The rule under test is the house selected-chip treatment. `onSelected:
/// null` makes an already-selected [ChoiceChip] *disabled*, and M3 then paints
/// it in the disabled palette — so the unselected chips read louder than the
/// active one, on the row that IS this view's navigation. `DESIGN.md`: a
/// selected chip takes the brand tint family. The atlas's year chips carry
/// the same fix.
const List<BookingDestination> _destinations = [
  (value: 'prague', label: 'Prague', booked: 0, total: 3),
  (value: 'vienna', label: 'Vienna', booked: 2, total: 2),
  (value: 'other', label: 'Other bookings', booked: 1, total: 1),
];

/// Mounts the bar with [selected] applied, recording what it reports back.
///
/// Returns the sink the bar writes destination selections into — including a
/// re-tap on the selected chip, which must stay OUT of it.
Future<List<String?>> _pumpBar(
  WidgetTester tester, {
  String? selected,
  List<BookingDestination> destinations = _destinations,
  ThemeData? theme,
}) async {
  final selections = <String?>[];
  await tester.pumpWidget(localizedTestApp(
    theme: theme,
    home: Scaffold(
      body: BookingFilterBar(
        unbookedOnly: false,
        onUnbookedOnlyChanged: (_) {},
        destinations: destinations,
        selected: selected,
        onSelected: selections.add,
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return selections;
}

ChoiceChip _chipLabelled(WidgetTester tester, String label) =>
    tester.widget<ChoiceChip>(find.ancestor(
        of: find.text(label), matching: find.byType(ChoiceChip)));

Future<String> _allLabel() async =>
    (await AppLocalizations.delegate.load(const Locale('en')))
        .tripBookingsAllDestinations;

void main() {
  testWidgets('the selected destination chip stays enabled', (tester) async {
    await _pumpBar(tester, selected: 'prague');

    // `isEnabled` is `onSelected != null`, and it is the whole finding: a
    // disabled chip is what M3 dims.
    expect(_chipLabelled(tester, 'Prague').isEnabled, isTrue);
    expect(_chipLabelled(tester, 'Vienna').isEnabled, isTrue);
  });

  testWidgets('the selected All chip stays enabled too', (tester) async {
    // All is this strip's resting state, so it is the chip most often
    // selected and the one the dimming showed on most.
    await _pumpBar(tester, selected: null);
    expect(_chipLabelled(tester, await _allLabel()).isEnabled, isTrue);
  });

  testWidgets('re-tapping the selected chip reports nothing', (tester) async {
    // Enabled, but still inert: All is the way back, and a re-tap must not
    // become a second, invisible way to do the same thing.
    final selections = await _pumpBar(tester, selected: 'prague');

    await tester.tap(find.text('Prague'));
    await tester.pumpAndSettle();
    expect(selections, isEmpty);

    // ...while a real selection still gets through, both ways.
    await tester.tap(find.text('Vienna'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(await _allLabel()));
    await tester.pumpAndSettle();
    expect(selections, ['vienna', null]);
  });

  testWidgets('the selected chip takes the brand tint, and legible ink',
      (tester) async {
    await _pumpBar(tester, selected: 'prague');
    final scheme =
        Theme.of(tester.element(find.byType(BookingFilterBar))).colorScheme;

    final prague = _chipLabelled(tester, 'Prague');
    expect(prague.selectedColor, AppColors.brandTintFill(scheme));
    // Stated outright rather than left to default: an M3 label style with no
    // color paints `onSurface`, the wrong ink on a tinted fill.
    expect(prague.labelStyle?.color, AppColors.onBrandTint(scheme));
    expect(_chipLabelled(tester, 'Vienna').labelStyle?.color,
        scheme.onSurfaceVariant);

    final all = _chipLabelled(tester, await _allLabel());
    expect(all.selectedColor, AppColors.brandTintFill(scheme));
    expect(all.labelStyle?.color, scheme.onSurfaceVariant,
        reason: 'All is unselected here — a destination is');
  });

  testWidgets('in dark mode the tint follows the scheme, not teal-50',
      (tester) async {
    // `AppColors.brandTint` is a light-page constant; the token branches on
    // brightness so the chip is not a light block punched into a dark page.
    // A stock dark theme rather than `AppTheme.dark` — all this needs is the
    // brightness branch, and the assertion then holds whatever the app theme
    // seeds `primaryContainer` to.
    await _pumpBar(tester, selected: 'prague', theme: ThemeData.dark());
    final scheme =
        Theme.of(tester.element(find.byType(BookingFilterBar))).colorScheme;
    expect(scheme.brightness, Brightness.dark);

    final prague = _chipLabelled(tester, 'Prague');
    expect(prague.selectedColor, scheme.primaryContainer);
    expect(prague.selectedColor, isNot(AppColors.brandTint));
    expect(prague.labelStyle?.color, scheme.onPrimaryContainer);
  });

  testWidgets('one destination is not a filter: no strip, no All chip',
      (tester) async {
    // Selecting it would show exactly what All shows. The scope chip stays —
    // it filters something else.
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await _pumpBar(tester, destinations: const [
      (value: 'prague', label: 'Prague', booked: 0, total: 3),
    ]);

    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('Prague'), findsNothing);
    expect(find.text(l10n.tripFilterUnbooked), findsOneWidget);
  });
}
