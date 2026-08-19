import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Drop shadows for custom (non-Card) raised surfaces. Downward-offset so they
/// imply light from above, per the wiki's depth-and-shadows guidance — a flat,
/// evenly-blurred shadow looks artificial.
abstract final class AppShadows {
  /// Soft shadow for cards/containers rendered outside the Material `Card`
  /// (which gets its shadow from `cardTheme`).
  static List<BoxShadow> get soft => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.10),
          blurRadius: 10,
          offset: const Offset(0, 3),
        ),
      ];

  /// Shadow under brand-gradient cards (hero strips, recent/live trip cards) —
  /// the brandDark pair those cards were each declaring inline.
  static List<BoxShadow> get brandCard => [
        BoxShadow(
          color: AppColors.brandDark.withValues(alpha: 0.3),
          blurRadius: 10,
          offset: const Offset(0, 4),
        ),
      ];

  /// Deeper variant for full-bleed heroes (landing).
  static List<BoxShadow> get hero => [
        BoxShadow(
          color: AppColors.brandDark.withValues(alpha: 0.4),
          blurRadius: 16,
          offset: const Offset(0, 6),
        ),
      ];

  /// Crisp drop under map pins (itinerary dots, stay/home squares, cluster
  /// bubble) — the trip_map pin family's shared value, kept below the soft
  /// banner blur so pins land sharply over satellite imagery.
  static List<BoxShadow> get pin => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.35),
          blurRadius: 4,
          offset: const Offset(0, 1),
        ),
      ];

  /// The selected pin's slightly stronger drop — the pin family above, one
  /// notch deeper, so selection reads as "lifted" without a color change.
  static List<BoxShadow> get pinSelected => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.5),
          blurRadius: 6,
          offset: const Offset(0, 1),
        ),
      ];
}
