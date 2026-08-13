import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:travel_route_planner/l10n/l10n.dart';

/// Localization wiring for widget tests (specs/i18n-spanish).
///
/// Screens now read their copy from `context.l10n`, which throws if the
/// delegates aren't installed. Tests that pump a bare `MaterialApp` need these
/// — the same list `main.dart` installs.
const List<LocalizationsDelegate<dynamic>> testLocalizationsDelegates = [
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

/// A `MaterialApp` with localizations installed, for tests that just need a
/// screen on-screen. Tests needing routing or other `MaterialApp` options
/// should build their own and spread [testLocalizationsDelegates] into it.
///
/// [locale] pins the language: leave it null to take English, or pass
/// `Locale('es')` to assert translated copy.
///
/// [theme] pins the ThemeData: leave it null for Flutter's stock light theme
/// (the historic behavior every existing test assumes), or pass
/// `AppTheme.dark` for dark-mode smoke tests (specs/dark-mode).
MaterialApp localizedTestApp({
  required Widget home,
  Locale? locale,
  ThemeData? theme,
}) {
  return MaterialApp(
    localizationsDelegates: testLocalizationsDelegates,
    // Not kSupportedLocales: tests may pin a language that ships translations
    // but is not yet enabled for users.
    supportedLocales: const [Locale('en'), Locale('es')],
    locale: locale,
    theme: theme,
    home: home,
  );
}
