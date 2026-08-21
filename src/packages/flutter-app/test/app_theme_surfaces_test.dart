import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/theme/app_colors.dart';
import 'package:travel_route_planner/theme/app_theme.dart';

// The Aegean canvases replaced M3's seed-derived neutrals, so the contrast
// the scheme used to guarantee is now ours to prove. DESIGN.md states a
// tightest pair; this re-measures every pair rather than trusting it.

/// WCAG relative luminance.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) +
      0.7152 * channel(c.g) +
      0.0722 * channel(c.b);
}

double _contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Every tone a widget can legitimately put text on.
List<(String, Color)> _fields(SurfaceCanvas c) => [
      ('surface', c.surface),
      ('surfaceDim', c.surfaceDim),
      ('surfaceBright', c.surfaceBright),
      ('containerLowest', c.containerLowest),
      ('containerLow', c.containerLow),
      ('container', c.container),
      ('containerHigh', c.containerHigh),
      ('containerHighest', c.containerHighest),
    ];

void main() {
  group('every surface tone carries both inks at AA', () {
    for (final (mode, canvas) in [
      ('dark', AppColors.aegeanNight),
      ('light', AppColors.aegeanPaper),
    ]) {
      test(mode, () {
        for (final (name, field) in _fields(canvas)) {
          expect(
            _contrast(canvas.onSurface, field),
            greaterThanOrEqualTo(4.5),
            reason: '$mode onSurface on $name is body text',
          );
          expect(
            _contrast(canvas.onSurfaceVariant, field),
            greaterThanOrEqualTo(4.5),
            reason: '$mode onSurfaceVariant on $name is body text too — it '
                'carries secondary copy, not decoration',
          );
        }
      });
    }
  });

  test('the ladder steps one way without a flat rung', () {
    // A card reads as raised because of the INTERVAL between rungs, so a
    // duplicate or inverted step is a silently invisible surface.
    //
    // The two canvases step in OPPOSITE directions, and that is M3, not a
    // mistake: in dark a higher container is lighter, in light it is darker
    // (containerLowest is plain white). Asserting "rises" in both is what
    // this test did on its first pass, and light failed it correctly.
    for (final (mode, canvas, sign) in [
      ('dark', AppColors.aegeanNight, 1),
      ('light', AppColors.aegeanPaper, -1),
    ]) {
      final rungs = [
        canvas.containerLowest,
        canvas.containerLow,
        canvas.container,
        canvas.containerHigh,
        canvas.containerHighest,
      ];
      for (var i = 1; i < rungs.length; i++) {
        final step = (_luminance(rungs[i]) - _luminance(rungs[i - 1])) * sign;
        expect(step, greaterThan(0),
            reason: '$mode rung $i must step away from rung ${i - 1}');
      }
    }
  });

  test('the two canvases are one design in two keys, not an inversion', () {
    // Same hue both ways: the light canvas is not the dark one flipped, but
    // it is not a different family either.
    double hue(Color c) => HSLColor.fromColor(c).hue;
    expect(hue(AppColors.aegeanNight.surface),
        closeTo(hue(AppColors.aegeanPaper.surface), 12));
    // ...and near white the chroma has to come off, or the page reads blue
    // rather than cool.
    expect(HSLColor.fromColor(AppColors.aegeanPaper.surface).saturation,
        lessThan(HSLColor.fromColor(AppColors.aegeanNight.surface).saturation));
  });

  test('the canvas is what the theme actually paints', () {
    for (final (theme, canvas) in [
      (AppTheme.dark, AppColors.aegeanNight),
      (AppTheme.light, AppColors.aegeanPaper),
    ]) {
      final s = theme.colorScheme;
      expect(s.surface, canvas.surface);
      expect(s.surfaceContainerHigh, canvas.containerHigh);
      expect(s.onSurface, canvas.onSurface);
      expect(s.outlineVariant, canvas.outlineVariant);
    }
    // Dark cards take the explicit tonal step, because the surface tint that
    // would otherwise separate them is off everywhere.
    expect(AppTheme.dark.cardTheme.color,
        AppColors.aegeanNight.containerHigh);
  });

  test('teal still seeds every role — the canvas took surfaces only', () {
    // The split the whole change rests on: blue is what you act ON, teal is
    // what you act WITH. A regression here would be the button going blue.
    final dark = AppTheme.dark.colorScheme;
    final light = AppTheme.light.colorScheme;
    for (final (mode, primary, field) in [
      ('dark', dark.primary, dark.surface),
      ('light', light.primary, light.surface),
    ]) {
      final h = HSLColor.fromColor(primary).hue;
      expect(h, greaterThan(140),
          reason: '$mode primary must stay in the teal family');
      expect(h, lessThan(190),
          reason: '$mode primary must not drift into the canvas blue');
      expect(_contrast(primary, field), greaterThanOrEqualTo(3.0),
          reason: '$mode primary is the action — it has to be findable on '
              'its own page');
    }
  });
}
