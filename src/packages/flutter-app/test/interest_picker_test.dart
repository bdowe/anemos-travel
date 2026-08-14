import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/constants/interest_bank.dart';
import 'package:travel_route_planner/widgets/interest_picker.dart';

import 'support/l10n_test_app.dart';

/// Hosts the picker the way both screens do: a parent-owned selection set,
/// replaced wholesale from onChanged.
class Harness extends StatefulWidget {
  final Set<String> initial;
  const Harness({super.key, this.initial = const {}});

  @override
  State<Harness> createState() => HarnessState();
}

class HarnessState extends State<Harness> {
  late final Set<String> selected = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        children: [
          InterestPicker(
            selected: selected,
            onChanged: (next) => setState(
              () => selected
                ..clear()
                ..addAll(next),
            ),
          ),
        ],
      ),
    );
  }
}

Future<HarnessState> pumpPicker(
  WidgetTester tester, {
  Set<String> initial = const {},
  Locale? locale,
}) async {
  // Tall surface so every chip is on-screen and tappable.
  await tester.binding.setSurfaceSize(const Size(800, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    localizedTestApp(home: Harness(initial: initial), locale: locale),
  );
  return tester.state<HarnessState>(find.byType(Harness));
}

List<String> chipLabelsInOrder(WidgetTester tester) => tester
    .widgetList<FilterChip>(find.byType(FilterChip))
    .map((c) => (c.label as Text).data!)
    .toList();

void main() {
  testWidgets('renders the full suggested bank in curated order, unselected',
      (tester) async {
    await pumpPicker(tester);

    final labels = chipLabelsInOrder(tester);
    expect(labels.length, suggestedInterests.length);
    expect(labels.first, 'museums');
    expect(labels[10], 'live music');
    expect(labels.last, 'sports events');
    final anySelected = tester
        .widgetList<FilterChip>(find.byType(FilterChip))
        .any((c) => c.selected);
    expect(anySelected, isFalse);
  });

  testWidgets('toggling a chip on and off round-trips the selection',
      (tester) async {
    final state = await pumpPicker(tester);

    await tester.tap(find.widgetWithText(FilterChip, 'coffee'));
    await tester.pump();
    expect(state.selected, {'coffee'});

    await tester.tap(find.widgetWithText(FilterChip, 'coffee'));
    await tester.pump();
    expect(state.selected, isEmpty);
  });

  testWidgets('adding a custom interest selects it and appends its chip',
      (tester) async {
    final state = await pumpPicker(tester);

    await tester.enterText(find.byType(TextField), 'kayaking');
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    expect(state.selected, {'kayaking'});
    final labels = chipLabelsInOrder(tester);
    expect(labels.length, suggestedInterests.length + 1);
    expect(labels.last, 'kayaking'); // rendered raw, after the bank
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, 'kayaking'))
          .selected,
      isTrue,
    );
  });

  testWidgets(
      'a saved case variant of a bank value lights the bank chip '
      'instead of duplicating it, and deselecting removes the variant',
      (tester) async {
    final state = await pumpPicker(tester, initial: {'Live Music'});

    expect(chipLabelsInOrder(tester).length, suggestedInterests.length);
    expect(
      tester
          .widget<FilterChip>(find.widgetWithText(FilterChip, 'live music'))
          .selected,
      isTrue,
    );

    await tester.tap(find.widgetWithText(FilterChip, 'live music'));
    await tester.pump();
    expect(state.selected, isEmpty);
  });

  testWidgets('typing a bank value selects the canonical chip, no raw dup',
      (tester) async {
    final state = await pumpPicker(tester);

    await tester.enterText(find.byType(TextField), 'Coffee');
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    expect(state.selected, {'coffee'});
    expect(chipLabelsInOrder(tester).length, suggestedInterests.length);
  });

  testWidgets('bank chips translate in Spanish; custom interests stay raw',
      (tester) async {
    await pumpPicker(
      tester,
      initial: {'kayaking'},
      locale: const Locale('es'),
    );

    expect(find.widgetWithText(FilterChip, 'música en vivo'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'senderismo'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'kayaking'), findsOneWidget);
  });
}
