import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/navigation/app_nav.dart';

/// Logo-links-home: goHome mirrors the shell's tab-select behavior
/// (selectTab): land on the Home ROOT — the Home stack is popped to its root
/// whether the tap switches tabs or Home is already active.
///
/// The tap target itself is pinned elsewhere, not here: the brand row carries
/// exactly one InkWell over the whole lockup (home_polish_test.dart), and the
/// rail brand is a bare mark with its own (nav_tab_reset_test.dart). The two
/// widget tests that used to stand in this file exercised the retired
/// BrandBadge plate directly and went with it.
void main() {
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
