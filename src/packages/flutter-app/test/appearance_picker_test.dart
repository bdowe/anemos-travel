import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/screens/account_settings_screen.dart';

import 'support/account_settings_harness.dart';

/// End-to-end of the user-visible half of specs/dark-mode: the Appearance
/// dropdown in account settings restyles the whole app immediately, persists
/// the choice, and "Use device setting" follows the platform brightness live.
///
/// The MaterialApp comes from the shared account-settings harness, wired
/// exactly like main.dart, so picking from the real dropdown proves the full
/// loop, not just the provider.

// Anchored to the screen rather than to a label: the dropdown's closed state
// keeps every option's text in an IndexedStack, so label finders are ambiguous.
Brightness _appBrightness(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(AccountSettingsScreen))).brightness;

/// Opens the appearance dropdown and picks [label] from the open menu.
/// `DropdownMenuItem` only exists in the menu — the closed field renders the
/// `selectedItemBuilder` widgets — so this finder can't hit the button itself.
Future<void> _pickAppearance(WidgetTester tester, String label) async {
  final field = find.byType(DropdownButtonFormField<ThemeMode>);
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.tap(field);
  await tester.pumpAndSettle();
  await tester.tap(find.descendant(
    of: find.widgetWithText(DropdownMenuItem<ThemeMode>, label),
    matching: find.text(label),
  ));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('tapping Dark restyles the app immediately and persists it',
      (tester) async {
    await pumpAccountSettings(tester, user: testUser());
    expect(_appBrightness(tester), Brightness.light);

    await _pickAppearance(tester, 'Dark');

    expect(_appBrightness(tester), Brightness.dark);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'dark');
  });

  testWidgets('a stored Dark choice comes up dark on launch', (tester) async {
    SharedPreferences.setMockInitialValues({'theme_mode': 'dark'});
    await pumpAccountSettings(tester, user: testUser());
    // The platform is light in tests — dark can only come from the store.
    expect(_appBrightness(tester), Brightness.dark);
  });

  testWidgets('"Use device setting" follows the platform brightness live',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    // Nothing stored: the default (system) mode tracks the OS.
    await pumpAccountSettings(tester, user: testUser());
    expect(_appBrightness(tester), Brightness.dark);

    // An OS appearance flip mid-session restyles without any tap.
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpAndSettle();
    expect(_appBrightness(tester), Brightness.light);
  });

  testWidgets('choosing Light pins the app against a dark platform',
      (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await pumpAccountSettings(tester, user: testUser());
    expect(_appBrightness(tester), Brightness.dark);

    await _pickAppearance(tester, 'Light');

    expect(_appBrightness(tester), Brightness.light);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), 'light');
  });

  testWidgets('the appearance dropdown fits a 360px phone in Spanish',
      (tester) async {
    // "Usar la configuración del dispositivo" is the longest label either
    // language ships and 360px is the narrow floor, so this is the case the
    // closed field's ellipsis and the menu's variable item height exist for.
    await pumpAccountSettings(
      tester,
      user: testUser(),
      size: const Size(360, 2000),
      locale: const Locale('es'),
    );

    final field = find.byType(DropdownButtonFormField<ThemeMode>);
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(field);
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(
          DropdownMenuItem<ThemeMode>, 'Usar la configuración del dispositivo'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
