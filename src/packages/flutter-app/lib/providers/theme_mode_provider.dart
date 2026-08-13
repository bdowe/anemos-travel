import 'package:flutter/material.dart' show ThemeMode, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's light/dark appearance, and the single place it is decided
/// (specs/dark-mode).
///
/// Structural mirror of `locale_provider.dart`, with one deliberate
/// divergence: locale resolves "follow the device" to a concrete language
/// once, because the server states the language on every request and renders
/// emails from it. Appearance has no server consumer, so `ThemeMode.system`
/// stays a live mode — `MaterialApp.themeMode` tracks OS appearance changes
/// as they happen — and nothing syncs to the account.

/// Storage key for the choice. Device-wide rather than per-user for the same
/// reason as the locale: the landing and sign-in screens render before anyone
/// is signed in.
const String _themeModeKey = 'theme_mode';

@immutable
class ThemeModeState {
  /// The chosen mode. [ThemeMode.system] until the user picks otherwise.
  final ThemeMode mode;

  /// False until the stored choice has been read; the app follows the system
  /// in the meantime.
  final bool loaded;

  const ThemeModeState({this.mode = ThemeMode.system, this.loaded = false});

  ThemeModeState copyWith({ThemeMode? mode, bool? loaded}) => ThemeModeState(
        mode: mode ?? this.mode,
        loaded: loaded ?? this.loaded,
      );
}

/// Folds a stored value (null when nothing is stored) to a [ThemeMode].
/// Unknown values — hand-edited storage, or a choice written by a build that
/// knows modes this one doesn't — fall back to following the system rather
/// than guessing a brightness.
ThemeMode parseStoredThemeMode(String? stored) => switch (stored) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

/// The string stored for [mode]; inverse of [parseStoredThemeMode]. Explicit
/// strings rather than enum indices, so stored choices survive any reordering
/// of [ThemeMode].
String storedThemeModeValue(ThemeMode mode) => switch (mode) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => 'system',
    };

class ThemeModeNotifier extends StateNotifier<ThemeModeState> {
  // Render immediately following the system; the stored choice arrives a
  // frame or two later and only redraws if it differs.
  ThemeModeNotifier() : super(const ThemeModeState());

  /// Reads the stored choice. Called once at startup. Unlike the locale there
  /// is no write-back here: "system" is the absence of a choice, not a
  /// sentinel to resolve, and storing it would turn the default into a
  /// decision.
  Future<void> load() async {
    String? stored;
    try {
      final prefs = await SharedPreferences.getInstance();
      stored = prefs.getString(_themeModeKey);
    } catch (_) {
      // Storage unavailable (private browsing, first run) — follow the
      // system for this session.
    }
    state = state.copyWith(mode: parseStoredThemeMode(stored), loaded: true);
  }

  /// Records an explicit choice. State first so the redraw is instant; the
  /// write is best-effort.
  Future<void> setMode(ThemeMode mode) async {
    state = state.copyWith(mode: mode);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_themeModeKey, storedThemeModeValue(mode));
    } catch (_) {
      // The choice still applies for this session.
    }
  }
}

final themeModeProvider =
    StateNotifierProvider<ThemeModeNotifier, ThemeModeState>((ref) {
  return ThemeModeNotifier()..load();
});
