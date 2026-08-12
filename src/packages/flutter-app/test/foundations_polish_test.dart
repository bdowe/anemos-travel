import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/widgets/map_leg_chips.dart';
import 'package:travel_route_planner/widgets/status_pill.dart';

import 'support/l10n_test_app.dart';

/// Wave-2 foundations (polish/wave2-foundations): the shared StatusPill and
/// map chip widgets must resolve their labels through AppLocalizations —
/// they previously shipped hardcoded English onto the trips list, the
/// trip-detail header, and all three map surfaces. (MapLegChips' city labels
/// are data; only its "All" chip localizes.)
void main() {
  Widget pill(String status, {Locale? locale}) => localizedTestApp(
        home: Scaffold(body: StatusPill(status: status)),
        locale: locale,
      );

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

  group('StatusPill localization', () {
    testWidgets('renders English labels under en', (tester) async {
      await tester.pumpWidget(pill('draft'));
      expect(find.text('Draft'), findsOneWidget);
    });

    testWidgets('renders Spanish labels under es', (tester) async {
      await tester.pumpWidget(pill('draft', locale: const Locale('es')));
      expect(find.text('Borrador'), findsOneWidget);
      expect(find.text('Draft'), findsNothing);

      await tester.pumpWidget(pill('planned', locale: const Locale('es')));
      expect(find.text('Planificado'), findsOneWidget);
    });

    testWidgets('empty status falls back to draft copy', (tester) async {
      await tester.pumpWidget(pill('', locale: const Locale('es')));
      expect(find.text('Borrador'), findsOneWidget);
    });

    testWidgets('unknown status title-cases instead of rendering blank',
        (tester) async {
      await tester.pumpWidget(pill('archived'));
      expect(find.text('Archived'), findsOneWidget);
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
