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

  // Landing dark-canvas family (specs/landing-redesign). The signed-out
  // landing page commits to the dark brand look regardless of theme mode, so
  // its surfaces are named here rather than borrowed from the dark scheme —
  // the dark cardTheme's neutral grey fights the teal canvas.
  /// Deep teal page field behind every landing section.
  static final Color landingCanvas = Color.lerp(brandDark, Colors.black, 0.55)!;

  /// Glass card fill on [landingCanvas] (the feature grid's cards).
  static final Color landingCard = Colors.white.withValues(alpha: 0.06);

  // The glass ladder: every raised fill on the canvas is white at a named
  // strength — card 6% < wellFaint 8% < field 10% < well 12% — so a new
  // landing surface picks a rung instead of minting another alpha.
  /// Recessed well on [landingCanvas] (the how-it-works step circles).
  static final Color landingWellFaint = Colors.white.withValues(alpha: 0.08);

  /// Input fill on [landingCanvas] (the hero prompt field).
  static final Color landingField = Colors.white.withValues(alpha: 0.10);

  /// Raised well on [landingCanvas] (prefill chips, feature-icon chips).
  static final Color landingWell = Colors.white.withValues(alpha: 0.12);

  /// Hairline borders on [landingCanvas].
  static final Color landingHairline = Colors.white.withValues(alpha: 0.14);

  // The ink ladder: white text and strokes on the canvas, again by role, so
  // the landing's whole dark-canvas system reads from this one block.
  /// Disabled control fill on [landingCanvas] (the hero submit at rest).
  static final Color landingInkDisabled = Colors.white.withValues(alpha: 0.35);

  /// Faint ink — placeholder/hint text on [landingCanvas].
  static final Color landingInkFaint = Colors.white.withValues(alpha: 0.6);

  /// Muted ink — secondary copy and focus strokes on [landingCanvas].
  static final Color landingInkMuted = Colors.white.withValues(alpha: 0.7);

  /// Strong ink — emphasized secondary copy on [landingCanvas] (hero
  /// subtitle).
  static final Color landingInkStrong = Colors.white.withValues(alpha: 0.85);

  /// Bottom band of the landing hero: dissolves the photo into
  /// [landingCanvas] instead of ending on a hard edge.
  static LinearGradient get landingHeroBlend => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [landingCanvas.withValues(alpha: 0), landingCanvas],
      );

  /// Translucent dark scrim behind text and controls overlaid on satellite
  /// imagery — the map day chips, TripMap's segment labels, and the map
  /// control buttons all share this one value so the over-map family can't
  /// drift apart again.
  static final Color mapScrim = Colors.black.withValues(alpha: 0.6);

  // Semantic status pair for positive/complete states (booked checkmarks,
  // Planned pills, published counts) — the exact green pair screens were
  // re-declaring inline before the polish wave.
  static Color get successContainer => Colors.green.withValues(alpha: 0.15);
  static Color get onSuccessContainer => Colors.green.shade800;

  // Semantic status pair for attention/pending states (review counts, draft
  // badges) — the matching amber pair.
  static Color get warningContainer => Colors.amber.withValues(alpha: 0.20);
  static Color get onWarningContainer => Colors.amber.shade900;

  // Solid counterparts to the container pairs, for chrome drawn over the
  // brand gradient (the app-bar health badge): the alpha container colors
  // disappear against the teal, so on-gradient badges need an opaque fill.
  // The neutral pair is the no-active-severity fallback.
  static Color get warningSolid => Colors.amber.shade600;
  static Color get onWarningSolid => Colors.black87;
  static Color get neutralSolid => Colors.white;
  static Color get onNeutralSolid => brandDark;

  // Status-strip marks (the Health pane's 90-day uptime history,
  // specs/uptime-history). Solid and brightness-aware: the container pairs
  // above are 15-20% alpha — right for a pill on a card, invisible as a 3px
  // bar — and their shade800/900 foregrounds go muddy on a dark surface.
  // These are MARKS, picked per brightness: mid shades on paper, lighter
  // shades on dark where saturated darks sink into the background. "No data"
  // is deliberately absent: it takes colorScheme.outlineVariant, the
  // recessive role, so absence can never read as a fourth severity.
  static Color upMark(Brightness b) =>
      b == Brightness.dark ? Colors.green.shade400 : Colors.green.shade600;
  static Color degradedMark(Brightness b) =>
      b == Brightness.dark ? Colors.amber.shade400 : Colors.amber.shade700;
  static Color downMark(Brightness b) =>
      b == Brightness.dark ? Colors.red.shade400 : Colors.red.shade600;

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
  /// Lodging accent — stay pins on the map and the chat's hotel rail. Named
  /// toolAirbnb until search_hotels arrived; the app links to Booking.com and
  /// surfaces hotels and vacation rentals from several sources, so a colour
  /// named after one provider was a stale name, not a meaning.
  static Color get toolStays => Colors.pink.shade600;
  static Color get toolEvents => Colors.purple.shade600;
  static Color get toolFerries => Colors.cyan.shade700;
  static Color get toolLocal => Colors.amber.shade800;
  // Blue-grey reads as the universal "P" signage family; distinct from
  // toolFlights blue and toolFerries cyan.
  static Color get toolParking => Colors.blueGrey.shade700;
}
