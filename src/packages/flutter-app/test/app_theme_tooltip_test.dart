import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/theme/app_shadows.dart';
import 'package:travel_route_planner/theme/app_theme.dart';
import 'package:travel_route_planner/theme/spacing.dart';

/// Pins the tooltip theme (specs/tooltip-theme): tooltips were the last
/// surface on framework defaults — a grey[700]/white pill at 90% opacity
/// whose 24px offset, measured from the trigger's CENTRE, left ~0 clearance
/// below a 48px IconButton (the composer's "Attach images" sat hard against
/// the input field). The theme states the raised-surface recipe once for
/// every tooltip in the app.
void main() {
  BoxDecoration deco(ThemeData t) =>
      t.tooltipTheme.decoration! as BoxDecoration;

  test('colors come from the scheme, in both modes', () {
    // Light: the paper surface. Dark: the explicit tonal step — the same
    // separation rule cards follow, since a drop shadow is invisible
    // against a dark canvas.
    expect(deco(AppTheme.light).color, AppTheme.light.colorScheme.surface);
    expect(deco(AppTheme.dark).color,
        AppTheme.dark.colorScheme.surfaceContainerHigh);
    // Never the framework's fixed grey.
    expect(deco(AppTheme.light).color, isNot(Colors.grey[700]));
  });

  test('small-badge radius, shared soft shadow, no tint', () {
    for (final t in [AppTheme.light, AppTheme.dark]) {
      expect(deco(t).borderRadius, AppRadius.smAll);
      expect(deco(t).boxShadow, AppShadows.soft);
    }
  });

  test('offset clears a 48px trigger', () {
    // verticalOffset is measured from the trigger's centre: 24 reaches the
    // lower edge of a 48px IconButton, so anything less leaves the pill
    // overlapping whatever sits below. Measured on screen against the
    // composer (the tightest neighbour): 19px of clear page background
    // between pill and input field, where the default left ~1px.
    for (final t in [AppTheme.light, AppTheme.dark]) {
      expect(t.tooltipTheme.verticalOffset, greaterThan(24));
    }
  });

  test('pills stay off the viewport edge', () {
    for (final t in [AppTheme.light, AppTheme.dark]) {
      expect(t.tooltipTheme.margin,
          const EdgeInsets.symmetric(horizontal: AppSpacing.md));
    }
  });
}
