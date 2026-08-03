import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../services/account_api_service.dart';
import 'api_client_provider.dart';
import 'auth_provider.dart';

/// The app's language, and the single place it is decided (specs/i18n-spanish).
///
/// The client owns locale resolution: it picks the language once and states it
/// on every request via `Accept-Language`. The server never re-derives it,
/// which is what keeps the picker from disagreeing with what the backend
/// thinks the user reads.
///
/// There is no "follow the system" mode: a device that has never chosen
/// resolves its language once at startup — the device language when this build
/// ships translations for it, else English — and stores that as the choice, so
/// the picker always shows a concrete language.

/// Storage key for the choice. Device-wide rather than per-user: the sign-in
/// screen needs a language before anyone is signed in. (The historic name
/// predates the removal of the "system default" picker option.)
const String _overrideKey = 'locale_override';

@immutable
class LocaleState {
  /// The language in use. Always a supported language code.
  final String language;

  /// False until the stored choice has been read; the app renders with the
  /// device-derived default in the meantime.
  final bool loaded;

  const LocaleState({this.language = 'en', this.loaded = false});

  /// What to hand [MaterialApp.locale].
  Locale get materialLocale => Locale(language);

  LocaleState copyWith({String? language, bool? loaded}) => LocaleState(
        language: language ?? this.language,
        loaded: loaded ?? this.loaded,
      );
}

/// The device/browser language, folded to a supported language code, or null
/// when this build has no translations for it.
String? deviceLanguage() {
  for (final locale in PlatformDispatcher.instance.locales) {
    if (isSupportedLanguage(locale.languageCode)) return locale.languageCode;
  }
  return null;
}

/// Folds a stored choice (null when nothing is stored) to a language this
/// build can render. Unsupported values — a stale choice from a build that
/// shipped a language this one doesn't, or the retired "system" sentinel —
/// fall back to the device language rather than sticking.
String resolveEffectiveLocale(String? stored) {
  if (stored != null && isSupportedLanguage(stored)) return stored;
  return deviceLanguage() ?? 'en';
}

class LocaleNotifier extends StateNotifier<LocaleState> {
  final Ref _ref;

  // Render immediately with the device-derived language; the stored choice
  // arrives a frame or two later and only redraws if it differs.
  LocaleNotifier(this._ref)
      : super(LocaleState(language: resolveEffectiveLocale(null))) {
    _apply(state.language);
  }

  /// Reads the stored choice. Called once at startup. A device that has never
  /// chosen resolves the device language and stores it, so the picker always
  /// has a concrete selection from then on.
  Future<void> load() async {
    SharedPreferences? prefs;
    String? stored;
    try {
      prefs = await SharedPreferences.getInstance();
      stored = prefs.getString(_overrideKey);
    } catch (_) {
      // Storage unavailable (private browsing, first run) — the resolved
      // language still applies for this session.
    }
    final language = resolveEffectiveLocale(stored);
    state = state.copyWith(language: language, loaded: true);
    _apply(language);
    if (stored != language) {
      try {
        await prefs?.setString(_overrideKey, language);
      } catch (_) {
        // Same session-only fallback as above.
      }
    }
  }

  /// Records an explicit choice and syncs it to the account.
  Future<void> setLanguage(String language) async {
    final resolved = resolveEffectiveLocale(language);
    state = state.copyWith(language: resolved);
    _apply(resolved);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_overrideKey, resolved);
    } catch (_) {
      // The choice still applies for this session.
    }
    await syncToAccount();
  }

  /// Best-effort push of the chosen language to the account. Never throws
  /// and never blocks the UI: a failed sync only costs a wrong-language email
  /// until the next successful one.
  Future<void> syncToAccount() async {
    if (!_ref.read(authProvider).isSignedIn) return;
    try {
      final api = _ref.read(apiClientProvider);
      final user = await AccountApiService(api).updateLocale(state.language);
      _ref.read(authProvider.notifier).setUser(user);
    } catch (_) {
      // Offline or transient — retried on the next locale change or sign-in.
    }
  }

  /// Pushes [locale] into the two places that read it implicitly: the API
  /// client's `Accept-Language` header and intl's default for date/number
  /// formatting.
  void _apply(String locale) {
    _ref.read(apiClientProvider).localeTag = locale;
    Intl.defaultLocale = locale;
  }
}

final localeProvider =
    StateNotifierProvider<LocaleNotifier, LocaleState>((ref) {
  return LocaleNotifier(ref)..load();
});
