import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/widgets/map_leg_chips.dart';
import 'package:travel_route_planner/widgets/status_pill.dart';

import 'support/l10n_test_app.dart';

/// Wave-2 foundations (polish/wave2-foundations): the shared map chip widget
/// must resolve its labels through AppLocalizations — it previously shipped
/// hardcoded English onto all three map surfaces. (MapLegChips' city labels
/// are data; only its "All" chip localizes.) StatusPill's draft/planned
/// variant is retired (specs/retire-trip-status); the surviving custom pill
/// renders its explicit label verbatim.
void main() {
  Widget chips({Locale? locale}) => localizedTestApp(
        home: Scaffold(
          body: MapLegChips(
            legs: const [
              (key: 'Praga', label: 'Praga'),
              (key: 'Roma', label: 'Roma'),
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
    testWidgets('renders the English All chip under en', (tester) async {
      await tester.pumpWidget(chips());
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Praga'), findsOneWidget);
      expect(find.text('Roma'), findsOneWidget);
    });

    testWidgets('renders the Spanish All chip under es; city labels pass '
        'through verbatim', (tester) async {
      await tester.pumpWidget(chips(locale: const Locale('es')));
      expect(find.text('Todos'), findsOneWidget);
      expect(find.text('All'), findsNothing);
      expect(find.text('Praga'), findsOneWidget);
      expect(find.text('Roma'), findsOneWidget);
    });
  });
}
