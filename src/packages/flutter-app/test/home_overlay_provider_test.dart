import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/providers/home_overlay_provider.dart';

void main() {
  test('no choice: visibility follows the form factor', () {
    expect(homeOverlayVisible(choice: null, wideLayout: true), isTrue);
    expect(homeOverlayVisible(choice: null, wideLayout: false), isFalse);
  });

  test('an explicit choice overrides the form-factor default both ways', () {
    expect(homeOverlayVisible(choice: false, wideLayout: true), isFalse);
    expect(homeOverlayVisible(choice: true, wideLayout: false), isTrue);
    expect(homeOverlayVisible(choice: true, wideLayout: true), isTrue);
    expect(homeOverlayVisible(choice: false, wideLayout: false), isFalse);
  });

  test('the provider starts with no choice and records setShown', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(homeOverlayChoiceProvider), isNull);

    container.read(homeOverlayChoiceProvider.notifier).setShown(false);
    expect(container.read(homeOverlayChoiceProvider), isFalse);

    container.read(homeOverlayChoiceProvider.notifier).setShown(true);
    expect(container.read(homeOverlayChoiceProvider), isTrue);
  });
}
