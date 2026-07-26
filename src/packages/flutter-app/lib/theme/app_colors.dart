import 'package:flutter/material.dart';

/// Brand and category colors in one place. The teal family is the spine of the
/// app (the Material 3 scheme is seeded from `Colors.teal.shade700`); the
/// gradients below are the exact pair the app bar, hero, and recent-trip card
/// were each declaring inline.
abstract final class AppColors {
  // Brand teal ramp.
  static final Color brand = Colors.teal.shade700;
  static final Color brandLight = Colors.teal.shade600;
  static final Color brandDark = Colors.teal.shade900;
  static final Color brandTint = Colors.teal.shade50;

  /// Top-left → bottom-right teal gradient used by the app bar and recent-trip
  /// card.
  static LinearGradient get brandGradient => LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [brandLight, brandDark],
      );

  /// Scrim for image heroes: darkest in the lower-left where text/buttons sit,
  /// lighter toward the upper-right so the photo shows through.
  static LinearGradient get heroScrim => LinearGradient(
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
        colors: [
          brandDark.withValues(alpha: 0.88),
          brandDark.withValues(alpha: 0.35),
        ],
      );

  // Semantic status pair for positive/complete states (booked checkmarks,
  // Planned pills, published counts) — the exact green pair screens were
  // re-declaring inline before the polish wave.
  static Color get successContainer => Colors.green.withValues(alpha: 0.15);
  static Color get onSuccessContainer => Colors.green.shade800;

  // Semantic status pair for attention/pending states (review counts, draft
  // badges) — the matching amber pair.
  static Color get warningContainer => Colors.amber.withValues(alpha: 0.20);
  static Color get onWarningContainer => Colors.amber.shade900;

  /// Accent color for an itinerary place by its category. `scheme` supplies the
  /// theme-derived fallbacks so this stays in sync with the seed.
  static Color forCategory(String? category, ColorScheme scheme) {
    switch (category) {
      case 'restaurant':
        return Colors.deepOrange;
      case 'attraction':
        return scheme.primary;
      default:
        return scheme.secondary;
    }
  }

  // Planning-toolkit tool accents (Home screen).
  static Color get toolRoute => Colors.deepOrange.shade600;
  static Color get toolFlights => Colors.blue.shade700;
  static Color get toolAirbnb => Colors.pink.shade600;
  static Color get toolEvents => Colors.purple.shade600;
  static Color get toolFerries => Colors.cyan.shade700;
  static Color get toolLocal => Colors.amber.shade800;
}
