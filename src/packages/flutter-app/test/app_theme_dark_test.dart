import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/theme/app_colors.dart';
import 'package:travel_route_planner/theme/app_theme.dart';

/// Pins the light/dark divergences in AppTheme (specs/dark-mode): the dark
/// build really is dark, inputs swap their paper fill for a tonal surface,
/// and cards separate by an explicit tonal step in dark while keeping the
/// light "light from above" drop-shadow recipe.
void main() {
  test('light and dark build the matching scheme brightness', () {
    expect(AppTheme.light.colorScheme.brightness, Brightness.light);
    expect(AppTheme.dark.colorScheme.brightness, Brightness.dark);
  });

  test('input fill: paper in light, tonal surface in dark', () {
    // Paper is a token now, not grey[50]: once the canvas went cool a warm
    // #FAFAFA sat inside every field as a visible smudge.
    expect(AppTheme.light.inputDecorationTheme.fillColor, AppColors.paperFill);
    expect(AppTheme.dark.inputDecorationTheme.fillColor,
        AppTheme.dark.colorScheme.surfaceContainerHighest);
  });

  test('cards: drop shadow separates in light, tonal step in dark', () {
    final light = AppTheme.light.cardTheme;
    final dark = AppTheme.dark.cardTheme;

    // Light keeps the default card color; dark takes an explicit step above
    // the surface, because the drop shadow that separates light cards is
    // invisible against a dark background.
    expect(light.color, isNull);
    expect(dark.color, AppTheme.dark.colorScheme.surfaceContainerHigh);
    expect(dark.shadowColor, Colors.black.withValues(alpha: 0.5));

    // The M3 elevation tint stays disabled in BOTH modes: card separation is
    // an explicit color choice, never an implicit function of elevation.
    expect(light.surfaceTintColor, Colors.transparent);
    expect(dark.surfaceTintColor, Colors.transparent);
  });
}
