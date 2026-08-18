import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The traveler's explicit choice about the trip map's home-airport overlay
/// (the flight_takeoff pin plus its dashed journey legs): true = show,
/// false = hide, null = no choice made this session. Surfaces resolve the
/// null through [homeOverlayVisible], so the overlay defaults on where the
/// map has room for the whole journey (wide, pinned layouts) and off where
/// the leg home would crowd the destinations out of frame (phones).
///
/// App-wide rather than per-trip: this is a framing preference ("do I want
/// the hop home in frame"), not trip data — the same scope as
/// themeModeProvider, and the scope a stored device key would have. A
/// provider rather than widget state so the inline card and the full-screen
/// map read ONE choice live in both directions, and so tests can drive it
/// directly (the rickRollProvider rationale).
///
/// Session-only, like dailySpendSettingsProvider: the choice resets on
/// restart so the per-form-factor default re-asserts (a phone's map always
/// reopens with tight city framing). To persist instead, follow the
/// theme_mode_provider pattern — a load() plus a best-effort
/// shared_preferences write in [HomeOverlayChoiceNotifier.setShown]; the
/// call sites would not change.
class HomeOverlayChoiceNotifier extends StateNotifier<bool?> {
  HomeOverlayChoiceNotifier() : super(null);

  /// Records an explicit choice (a toggle tap passes the inverse of the
  /// visibility it was displaying).
  void setShown(bool shown) => state = shown;
}

final homeOverlayChoiceProvider =
    StateNotifierProvider<HomeOverlayChoiceNotifier, bool?>(
        (ref) => HomeOverlayChoiceNotifier());

/// Effective home-overlay visibility for one map surface: the explicit
/// [choice] when one has been made, else the form-factor default — shown on
/// wide layouts, hidden on phones. The default is the absence of a choice:
/// null is never written back as a decision. [wideLayout] is the surface's
/// own layout question — `_mapPinned` (body width) on the inline trip-detail
/// card, the window-width rail idiom on the full-screen map.
bool homeOverlayVisible({required bool? choice, required bool wideLayout}) =>
    choice ?? wideLayout;
