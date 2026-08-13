import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/providers/theme_mode_provider.dart';

/// Persistence half of specs/dark-mode: the appearance choice defaults to
/// following the system, survives a relaunch, and a stored value this build
/// doesn't recognize falls back to system rather than picking a brightness.
ProviderContainer _container() {
  final c = ProviderContainer();
  addTearDown(c.dispose);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('nothing stored follows the system, and stays unstored', () async {
    final container = _container();
    await container.read(themeModeProvider.notifier).load();

    final state = container.read(themeModeProvider);
    expect(state.mode, ThemeMode.system);
    expect(state.loaded, isTrue);

    // Unlike the locale there is no write-back on load: "system" is the
    // absence of a choice, and storing it would turn the default into a
    // decision.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), isNull);
  });

  test('a stored choice is restored on launch', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
    final container = _container();
    await container.read(themeModeProvider.notifier).load();
    expect(container.read(themeModeProvider).mode, ThemeMode.dark);
  });

  test('an unrecognized stored value falls back to system', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': 'blue'});
    final container = _container();
    await container.read(themeModeProvider.notifier).load();
    expect(container.read(themeModeProvider).mode, ThemeMode.system);
  });

  test('an explicit choice is persisted and restored on next launch',
      () async {
    final container = _container();
    await container.read(themeModeProvider.notifier).setMode(ThemeMode.dark);
    expect(container.read(themeModeProvider).mode, ThemeMode.dark);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'dark');

    // A fresh container stands in for a relaunch: the choice must come back
    // from device storage rather than resetting to system.
    final relaunched = _container();
    await relaunched.read(themeModeProvider.notifier).load();
    expect(relaunched.read(themeModeProvider).mode, ThemeMode.dark);
  });

  test('returning to system is itself a stored, restored choice', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
    final container = _container();
    await container.read(themeModeProvider.notifier).load();
    await container.read(themeModeProvider.notifier).setMode(ThemeMode.system);

    final relaunched = _container();
    await relaunched.read(themeModeProvider.notifier).load();
    expect(relaunched.read(themeModeProvider).mode, ThemeMode.system);
  });

  test('stored strings round-trip through the parser', () {
    for (final mode in ThemeMode.values) {
      expect(parseStoredThemeMode(storedThemeModeValue(mode)), mode);
    }
    expect(parseStoredThemeMode(null), ThemeMode.system);
  });
}
