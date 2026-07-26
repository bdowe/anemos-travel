import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/widgets/map_day_chips.dart';
import 'package:travel_route_planner/widgets/status_pill.dart';

import 'support/l10n_test_app.dart';

/// Wave-2 foundations (polish/wave2-foundations): the shared StatusPill and
/// MapDayChips widgets must resolve their labels through AppLocalizations —
/// they previously shipped hardcoded English onto the trips list, the
/// trip-detail header, and all three map surfaces.
void main() {
  Widget pill(String status, {Locale? locale}) => localizedTestApp(
        home: Scaffold(body: StatusPill(status: status)),
        locale: locale,
      );

  Widget chips({Locale? locale}) => localizedTestApp(
        home: Scaffold(
          body: MapDayChips(
            dayCount: 2,
            selected: 1,
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

  group('MapDayChips localization', () {
    testWidgets('renders English labels under en', (tester) async {
      await tester.pumpWidget(chips());
      expect(find.text('All'), findsOneWidget);
      expect(find.text('Day 1'), findsOneWidget);
      expect(find.text('Day 2'), findsOneWidget);
    });

    testWidgets('renders Spanish labels under es', (tester) async {
      await tester.pumpWidget(chips(locale: const Locale('es')));
      expect(find.text('Todos'), findsOneWidget);
      expect(find.text('Día 1'), findsOneWidget);
      expect(find.text('Day 1'), findsNothing);
    });
  });
}
