import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/widgets/brand_logo.dart';

/// Logo-links-home: the brand badge is tappable when given onTap (Home app
/// bar; the rail brand is a bare mark with its own InkWell, pinned in
/// nav_tab_reset_test.dart), and goHome mirrors the shell's tab-select
/// behavior (selectTab): land on the Home ROOT — the Home stack is popped to
/// its root whether the tap switches tabs or Home is already active.
void main() {
  testWidgets('BrandBadge with onTap fires the callback',
      (WidgetTester tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrandBadge(
            onTap: () => taps++,
            child: const SizedBox(width: 24, height: 24),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(BrandBadge));
    expect(taps, 1);
  });

  testWidgets('BrandBadge without onTap stays a plain surface',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: BrandBadge(child: SizedBox(width: 24, height: 24)),
        ),
      ),
    );

    expect(
      find.descendant(
          of: find.byType(BrandBadge), matching: find.byType(InkWell)),
      findsNothing,
    );
  });

  testWidgets('goHome switches back to the Home tab from another tab',
      (WidgetTester tester) async {
    late WidgetRef capturedRef;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(builder: (context, ref, _) {
            capturedRef = ref;
            return const SizedBox();
          }),
        ),
      ),
    );
    final container =
        ProviderScope.containerOf(tester.element(find.byType(Consumer)));
    container.read(navIndexProvider.notifier).state = AppTab.trips.index;

    goHome(capturedRef);

    expect(container.read(navIndexProvider), AppTab.home.index);
  });

  testWidgets('goHome pops the Home stack to its root when already on Home',
      (WidgetTester tester) async {
    late WidgetRef capturedRef;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(builder: (context, ref, _) {
          capturedRef = ref;
          final keys = ref.watch(tabNavKeysProvider);
          return MaterialApp(
            home: Navigator(
              key: keys[AppTab.home.index],
              onGenerateRoute: (settings) => MaterialPageRoute(
                builder: (_) => const Text('home root'),
                settings: settings,
              ),
            ),
          );
        }),
      ),
    );
    final container =
        ProviderScope.containerOf(tester.element(find.byType(Consumer)));
    container
        .read(tabNavKeysProvider)[AppTab.home.index]
        .currentState!
        .push(MaterialPageRoute(builder: (_) => const Text('pushed page')));
    await tester.pumpAndSettle();
    expect(find.text('pushed page'), findsOneWidget);

    goHome(capturedRef);
    await tester.pumpAndSettle();

    expect(find.text('pushed page'), findsNothing);
    expect(find.text('home root'), findsOneWidget);
    expect(container.read(navIndexProvider), AppTab.home.index);
  });

  testWidgets(
      'goHome from another tab also pops the Home stack to its root',
      (WidgetTester tester) async {
    // Mutation pin for the selectTab reset: the old goHome only flipped the
    // index when coming from another tab, leaving a page stacked on Home to
    // greet the user. Nav buttons must land on the page they name.
    late WidgetRef capturedRef;
    await tester.pumpWidget(
      ProviderScope(
        child: Consumer(builder: (context, ref, _) {
          capturedRef = ref;
          final keys = ref.watch(tabNavKeysProvider);
          return MaterialApp(
            home: Navigator(
              key: keys[AppTab.home.index],
              onGenerateRoute: (settings) => MaterialPageRoute(
                builder: (_) => const Text('home root'),
                settings: settings,
              ),
            ),
          );
        }),
      ),
    );
    final container =
        ProviderScope.containerOf(tester.element(find.byType(Consumer)));
    container
        .read(tabNavKeysProvider)[AppTab.home.index]
        .currentState!
        .push(MaterialPageRoute(builder: (_) => const Text('pushed page')));
    await tester.pumpAndSettle();
    container.read(navIndexProvider.notifier).state = AppTab.trips.index;

    goHome(capturedRef);
    await tester.pumpAndSettle();

    expect(find.text('pushed page'), findsNothing);
    expect(find.text('home root'), findsOneWidget);
    expect(container.read(navIndexProvider), AppTab.home.index);
  });
}
