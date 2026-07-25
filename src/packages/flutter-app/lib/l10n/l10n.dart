import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

/// Localization entry points (specs/i18n-spanish).
///
/// [kSupportedLocales] is the single source of truth for which languages the
/// app ships: `MaterialApp.supportedLocales`, the locale provider's device
/// matching, and the settings picker all read it. Enabling a language is
/// therefore one line here plus its `.arb` file — and, just as importantly,
/// they can never disagree (a locale the provider resolved but MaterialApp
/// didn't support would send a language header for text the app can't render).
///
/// Adding a locale here is what makes it selectable; the translations and the
/// server-side catalog land in earlier PRs, so this stays a one-line change.
const List<Locale> kSupportedLocales = [
  Locale('en'),
  Locale('es'),
];

/// True when [languageCode] is a language this build can actually render.
bool isSupportedLanguage(String languageCode) =>
    kSupportedLocales.any((l) => l.languageCode == languageCode);

/// The display name of a supported language, in its own language — shared by
/// the account-settings picker and the app-bar language menu so they can
/// never disagree.
String languageDisplayName(AppLocalizations l10n, String code) =>
    switch (code) {
      'en' => l10n.languageEnglish,
      'es' => l10n.languageSpanish,
      _ => code,
    };

/// Shorthand for the generated lookups: `context.l10n.commonSave`.
extension AppLocalizationsX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
