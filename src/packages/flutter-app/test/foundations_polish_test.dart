import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/widgets/map_leg_chips.dart';
import 'package:travel_route_planner/widgets/status_pill.dart';

import 'support/l10n_test_app.dart';

/// Wave-2 foundations (polish/wave2-foundations): the shared map chip widget
/// must resolve its copy through AppLocalizations — it previously shipped
/// hardcoded English onto all three map surfaces. MapLegChips' city labels are
/// data, so its only translated string is the reset's tooltip; that carrier
/// used to be the "All" chip, retired with the chip. StatusPill's draft/planned
/// variant is retired (specs/retire-trip-status); the surviving custom pill
/// renders its explicit label verbatim.
void main() {
  Widget chips({Locale? locale}) => localizedTestApp(
        home: Scaffold(
          body: MapLegChips(
            legs: const [
              (key: 'Praga', label: 'Praga', qualifier: null),
              (key: 'Roma', label: 'Roma', qualifier: null),
            ],
            selected: 'Praga',
            onSelected: (_) {},
          ),
        ),
        locale: locale,
      );

  group('StatusPill.custom', () {
    testWidgets('renders its explicit label', (tester) async {
      await tester.pumpWidget(localizedTestApp(
        home: const Scaffold(
          body: StatusPill.custom(
            label: 'Live',
            background: Colors.green,
            foreground: Colors.white,
          ),
        ),
      ));
      expect(find.text('Live'), findsOneWidget);
    });
  });

  group('MapLegChips localization', () {
    // The fixture is focused on Praga, so the reset — the strip's one piece
    // of localized copy — is on screen.
    String resetTooltip(WidgetTester tester) => tester
        .widget<Tooltip>(find.descendant(
          of: find.byType(MapLegChips),
          matching: find.byType(Tooltip),
        ))
        .message!;

    testWidgets('resolves the reset tooltip under en', (tester) async {
      await tester.pumpWidget(chips());
      expect(resetTooltip(tester), 'Show all places');
      expect(find.text('Praga'), findsOneWidget);
      expect(find.text('Roma'), findsOneWidget);
    });

    testWidgets('resolves the reset tooltip under es; city labels pass '
        'through verbatim', (tester) async {
      await tester.pumpWidget(chips(locale: const Locale('es')));
      expect(resetTooltip(tester), 'Mostrar todos los lugares');
      expect(find.text('Praga'), findsOneWidget);
      expect(find.text('Roma'), findsOneWidget);
    });
  });
}
