import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/constants/app_info.dart';
import 'package:travel_route_planner/navigation/shell_scope.dart';
import 'package:travel_route_planner/theme/app_colors.dart';
import 'package:travel_route_planner/theme/app_theme.dart';
import 'package:travel_route_planner/widgets/brand_logo.dart';
import 'package:travel_route_planner/widgets/gradient_app_bar.dart';

import 'support/l10n_test_app.dart';

/// The ANEMOS wordmark has to be on screen on every page — that is the whole
/// point of moving the brand into [GradientAppBar], and this is the test that
/// keeps it true.
///
/// It exercises the shared app bar directly rather than pumping twenty
/// screens, which is affordable precisely *because* the brand lives in one
/// place now: every screen that uses the house app bar is covered by covering
/// the house app bar. The matrix is the shapes real screens produce — brand
/// alone (Home, Landing) vs. brand + page title, across the width range, with
/// the action counts that actually squeeze the title slot (trip detail's five
/// icons being the worst case in the app).
///
/// **The promise, in three statements:**
///
/// 1. With **no page title** (Home, Landing) the wordmark is present at every
///    width, **neither truncated nor scaled down**. A brand that survives as
///    "ANEM…" or as illegibly small type has not survived.
/// 2. At **rail widths**, beside a title, the same holds — in every locale and
///    at every text scale. The rail has the rose, so the word is the bar's only
///    brand there and never steps aside.
/// 3. **Below** rail widths, beside a title, the wordmark is whole **or
///    absent**: it yields the row when keeping it is what would clip the page's
///    own name. What the bar must never do is show half of it.
///
/// Statement 3 reverses the ordering PR #418 shipped, and it was reversed by
/// what the old one produced on a phone: `ANEMOS · Plan your t…`.
///
/// The yield is **measured, not thresholded** — see `the wordmark yields on
/// measurement, never on a breakpoint`, the test that fails if somebody
/// rewrites the ladder as `width < 800`.
///
/// One caveat that shapes what can be asserted here: widget tests render in a
/// fallback face with quite different metrics from Marcellus/Cinzel (a page
/// title measures ~2.2x its browser width), so *which* branch a given width
/// lands in diverges from production. Assertions below are therefore on the
/// invariant, never on "the wordmark is present at width N" for a narrow N —
/// the browser pass owns that. Same reason [_fallbackFontScalesAt] exists.
///
/// The action counts are a ceiling, not decoration. Five icons fit beside the
/// wordmark at rail widths and nowhere near it on a phone — which is why trip
/// detail folds everything but health into the overflow below 800px. Add a
/// fourth narrow action anywhere and [_narrowActionCounts] is what fails.
const _widths = <double>[320, 360, 390, 700, 800, 1200];
const _narrowActionCounts = <int>[0, 2, 3];
const _wideActionCounts = <int>[0, 2, 5];

/// Below every real device width. The ladder runs out of room here and the
/// FittedBox backstop in gradient_app_bar.dart takes over: the word still
/// renders whole, just smaller. Covered separately and deliberately, so the
/// strict matrix above keeps meaning what it says.
const double _subPhoneWidth = 230;

/// The matrix cells the FALLBACK test font cannot hold, listed rather than
/// hidden — if this set ever grows, that is a width regression, not a font
/// artifact, and the diff should have to say so.
///
/// The widget-test fallback face runs ~35% wider than Cinzel, and at this one
/// cell that difference is what tips the word into the [FittedBox]: it paints
/// at ~0.94. **Checked in a browser rather than argued from arithmetic** — at
/// 320px, on both Trips and trip detail, the real Cinzel wordmark paints 83px
/// of ink, exactly what it paints at 390, so nothing scales on a real device.
/// The page title is dropped at that width, which it was before this change
/// too.
///
/// It is also why the large-text case lands in this cell and nowhere else: the
/// backstop scales a 1.6x wordmark down to the slot, and the slot is wider than
/// the unscaled *Cinzel* wordmark but narrower than the unscaled fallback one.
// `final`, not `const`: records have no primitive equality, so a const Set of
// them will not compile.
final _fallbackFontScalesAt = <(double, int)>{(320.0, 3)};

Future<void> _pumpBar(
  WidgetTester tester, {
  String? title,
  int actions = 0,
  required double width,
  bool inShell = true,
  bool pushed = false,
  bool fullscreenDialog = false,
  Locale? locale,
  double textScale = 1.0,
}) async {
  // physicalSize, not setSurfaceSize: the bar gates the mark on MediaQuery
  // width, which setSurfaceSize does not update.
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  Widget page = Scaffold(
    appBar: GradientAppBar(
      title: title,
      actions: [
        for (var i = 0; i < actions; i++)
          IconButton(icon: const Icon(Icons.star), onPressed: () {}),
      ],
    ),
    body: const SizedBox.shrink(),
  );
  if (inShell) page = ShellScope(child: page);

  final content = page;

  // A real second route when [pushed], because `impliesAppBarDismissal` is
  // literally "is there an active route below me" — nothing short of a push
  // makes Flutter build the 56px button this file is now about. Whether the
  // route can be dismissed is the ONE difference between a tab root and a
  // pushed screen, and it is the difference this bar exists to absorb.
  final navKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        navigatorKey: navKey,
        localizationsDelegates: testLocalizationsDelegates,
        supportedLocales: const [Locale('en'), Locale('es')],
        locale: locale,
        theme: AppTheme.light,
        // The text-scale override wraps the NAVIGATOR, not `home`: a pushed
        // route is home's sibling, not its descendant, so an override inside
        // `home` would silently not reach the case under test.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        // An empty page under the push, so no finder in this file can pick up
        // a second copy of the bar.
        home: pushed ? const Scaffold(body: SizedBox.shrink()) : content,
      ),
    ),
  );
  if (pushed) {
    navKey.currentState!.push(MaterialPageRoute<void>(
      fullscreenDialog: fullscreenDialog,
      builder: (_) => content,
    ));
  }
  await tester.pumpAndSettle();
}

/// The wordmark's width with all the room in the world — the baseline every
/// constrained case is held to.
Future<double> _naturalWidth(WidgetTester tester,
    {double textScale = 1.0}) async {
  await _pumpBar(tester, width: 1200, inShell: false, textScale: textScale);
  return tester.getSize(find.text(AppInfo.name)).width;
}

/// Present, and laid out at its full natural width — i.e. never ellipsized or
/// clipped. Says nothing about scale.
void _expectWordmarkWhole(WidgetTester tester, double natural, String where) {
  final wordmark = find.text(AppInfo.name);
  expect(wordmark, findsOneWidget, reason: 'no wordmark at all: $where');
  expect(tester.getSize(wordmark).width, moreOrLessEquals(natural, epsilon: 0.5),
      reason: 'wordmark laid out narrower than natural — truncated: $where');
  expect(tester.takeException(), isNull, reason: 'overflow or throw: $where');
}

/// How far the [FittedBox] backstop is allowed to have scaled the word down.
/// Whole-but-shrunk is the correct trade where the slot genuinely runs out;
/// whole-but-illegible is not, so the floor is asserted rather than assumed.
void _expectScaledNoWorseThan(
    WidgetTester tester, double natural, double floor, String where) {
  final wordmark = find.text(AppInfo.name);
  final painted =
      tester.getBottomRight(wordmark).dx - tester.getTopLeft(wordmark).dx;
  expect(painted, greaterThan(natural * floor),
      reason: 'scaled past $floor of natural: $where');
}

/// Whole, or gone — never half. The invariant on the phone side of the ladder,
/// where the word may legitimately have stepped out of the row so the page's
/// own name could be read.
void _expectWordmarkWholeOrAbsent(
    WidgetTester tester, double natural, String where) {
  if (find.text(AppInfo.name).evaluate().isEmpty) {
    expect(tester.takeException(), isNull, reason: 'overflow or throw: $where');
    return;
  }
  _expectWordmarkWhole(tester, natural, where);
}

/// Wherever the title row starts — the wordmark when it is there, the page
/// title when the wordmark has yielded. Used to assert the row's left edge is
/// invariant across a push, which is [_leadingSlot]'s whole job and is a
/// separate question from which element happens to occupy it.
double _rowLeft(WidgetTester tester, String title) {
  final wordmark = find.text(AppInfo.name);
  return wordmark.evaluate().isNotEmpty
      ? tester.getTopLeft(wordmark).dx
      : tester.getTopLeft(find.text(title)).dx;
}

/// The full promise: whole *and* painted at full size.
void _expectWordmarkFullSize(
    WidgetTester tester, double natural, String where) {
  _expectWordmarkWhole(tester, natural, where);

  // getSize is the render box's own (untransformed) size; the difference of
  // the two corner offsets is the PAINTED extent, because localToGlobal
  // applies ancestor transforms. Comparing the two is what catches the
  // FittedBox backstop in gradient_app_bar.dart actually engaging.
  final wordmark = find.text(AppInfo.name);
  final painted =
      tester.getBottomRight(wordmark).dx - tester.getTopLeft(wordmark).dx;
  expect(painted, moreOrLessEquals(natural, epsilon: 0.5),
      reason: 'wordmark painted smaller than natural — scaled down: $where');
}

void main() {
  testWidgets('the wordmark survives every width, with and without a title',
      (tester) async {
    final natural = await _naturalWidth(tester);

    for (final width in _widths) {
      final counts = width >= 800 ? _wideActionCounts : _narrowActionCounts;
      for (final actions in counts) {
        // No title: nothing competes, so the strongest form of the promise
        // holds — present, whole, full size (statement 1).
        final where = 'w=$width actions=$actions';
        await _pumpBar(tester, actions: actions, width: width);
        if (_fallbackFontScalesAt.contains((width, actions))) {
          _expectWordmarkWhole(tester, natural, where);
          _expectScaledNoWorseThan(tester, natural, 0.9, where);
        } else {
          _expectWordmarkFullSize(tester, natural, where);
        }

        // With a title: full size at rail widths (statement 2), whole-or-gone
        // below them (statement 3).
        await _pumpBar(tester,
            title: 'Greece 2026', actions: actions, width: width);
        if (width >= 800) {
          _expectWordmarkFullSize(tester, natural, 'titled, $where');
        } else {
          _expectWordmarkWholeOrAbsent(tester, natural, 'titled, $where');
        }
      }
    }
  });

  testWidgets('the wordmark starts at the same x with and without a back '
      'button — the brand does not move when you open a screen', (tester) async {
    // The invariant the leading slot exists to hold, and the one nothing in
    // this suite pinned before: `_pumpBar` never pushed a route, so the whole
    // ladder was only ever verified with the slot empty. Opening a trip used to
    // slide the wordmark 108px right.
    for (final width in _widths) {
      final counts = width >= 800 ? _wideActionCounts : _narrowActionCounts;
      for (final actions in counts) {
        for (final inShell in [true, false]) {
          final where = 'w=$width actions=$actions inShell=$inShell';

          await _pumpBar(tester,
              title: 'Greece 2026',
              actions: actions,
              width: width,
              inShell: inShell);
          // The row's left edge, not specifically the wordmark's: on a narrow
          // titled bar the word may have yielded the row to the title. Both
          // sides of this comparison get the same title-row width — that is
          // what the reserved slot buys — so both take the same ladder branch
          // and the two reads are of the same element.
          final atRoot = _rowLeft(tester, 'Greece 2026');

          await _pumpBar(tester,
              title: 'Greece 2026',
              actions: actions,
              width: width,
              inShell: inShell,
              pushed: true);
          // Without this the test would still pass if the back button simply
          // stopped being drawn, which is the opposite of the fix.
          expect(find.byType(BackButton), findsOneWidget,
              reason: 'no back button to be anchored against: $where');

          expect(_rowLeft(tester, 'Greece 2026'),
              moreOrLessEquals(atRoot, epsilon: 0.5),
              reason: 'the brand moved on push: $where');
        }
      }
    }
  });

  testWidgets('a pushed page keeps the framework\'s own dismissal button',
      (tester) async {
    // The slot is filled by AppBar, not by us, so back-vs-close stays its
    // decision: trip_map_screen is a fullscreenDialog and must keep its ✕.
    await _pumpBar(tester, width: 390, pushed: true);
    expect(find.byType(BackButton), findsOneWidget);
    expect(find.byType(BrandLogo), findsNothing,
        reason: 'the rose must not squat in the dismissal slot');

    await _pumpBar(tester, width: 390, pushed: true, fullscreenDialog: true);
    expect(find.byType(CloseButton), findsOneWidget,
        reason: 'a fullscreenDialog takes the ✕, and that choice is not ours');
  });

  testWidgets('outside the shell too — the signed-out pages are pages',
      (tester) async {
    final natural = await _naturalWidth(tester);

    for (final width in _widths) {
      final where = 'outside shell, w=$width';
      await _pumpBar(tester,
          title: 'Connect app', width: width, inShell: false);
      if (width >= 800) {
        _expectWordmarkFullSize(tester, natural, where);
      } else {
        _expectWordmarkWholeOrAbsent(tester, natural, where);
      }
      // Outside the shell there is no rail, so the rose is in the leading slot
      // on every one of these — the brand is on screen even where the word
      // yielded.
      expect(find.byType(BrandLogo), findsOneWidget, reason: where);
    }
  });

  testWidgets('and in Spanish, whose titles run longer', (tester) async {
    final natural = await _naturalWidth(tester);

    for (final width in _widths) {
      await _pumpBar(tester,
          // The longest app-bar title the app ships (quizTitle, es).
          title: 'Configura tu perfil de viaje',
          actions: 2,
          width: width,
          locale: const Locale('es'));
      if (width >= 800) {
        _expectWordmarkFullSize(tester, natural, 'es, w=$width');
      } else {
        _expectWordmarkWholeOrAbsent(tester, natural, 'es, w=$width');
      }
    }
  });

  testWidgets('a large text-scale setting does not clip it', (tester) async {
    // The reason the ladder measures the wordmark instead of comparing the
    // slot against a constant: accessibility text scaling grows the word but
    // not a hardcoded threshold, so the bar would quietly start clipping for
    // exactly the travelers least able to read a clipped word.
    //
    // The promise at 1.6x is not "full size" — the tightest bar genuinely has
    // no room for a 1.6x wordmark. It is: never clipped, and never rendered
    // SMALLER than the default-scale wordmark. Turning text size up must not
    // make the brand shrink.
    const scale = 1.6;
    final unscaled = await _naturalWidth(tester);
    final natural = await _naturalWidth(tester, textScale: scale);

    for (final width in _widths) {
      final counts = width >= 800 ? _wideActionCounts : _narrowActionCounts;
      for (final actions in counts) {
        final where = 'textScale=$scale w=$width actions=$actions';
        await _pumpBar(tester,
            title: 'Greece 2026',
            actions: actions,
            width: width,
            textScale: scale);
        _expectWordmarkWholeOrAbsent(tester, natural, where);

        // Where the word yielded the row to the title there is nothing left to
        // measure — a scale that grows the word is exactly what makes it yield,
        // and yielding whole is the correct outcome, not a clip.
        if (find.text(AppInfo.name).evaluate().isEmpty) continue;

        if (_fallbackFontScalesAt.contains((width, actions))) {
          // The backstop scales the 1.6x word down to the slot, and this one
          // cell's slot is narrower than the FALLBACK font's unscaled wordmark
          // — though wider than Cinzel's, so the promise below holds on a real
          // device. Keep the legibility floor rather than nothing at all.
          _expectScaledNoWorseThan(tester, unscaled, 0.9, where);
          continue;
        }

        final wordmark = find.text(AppInfo.name);
        final painted =
            tester.getBottomRight(wordmark).dx - tester.getTopLeft(wordmark).dx;
        expect(painted, greaterThanOrEqualTo(unscaled - 0.5),
            reason: 'large-text setting made the brand smaller: $where');
      }
    }
  });

  testWidgets('below phone widths it shrinks to fit rather than clipping',
      (tester) async {
    final natural = await _naturalWidth(tester);

    await _pumpBar(tester, actions: 2, width: _subPhoneWidth);
    // Whole, but not full size — this is the backstop, and it is the correct
    // trade at a width no device has: a release build does not stripe a
    // RenderFlex overflow, it silently cuts the glyphs off.
    _expectWordmarkWhole(tester, natural, 'sub-phone');
    final painted = tester.getBottomRight(find.text(AppInfo.name)).dx -
        tester.getTopLeft(find.text(AppInfo.name)).dx;
    expect(painted, lessThan(natural));
    expect(painted, greaterThan(natural * 0.5),
        reason: 'scaled past legibility');
  });

  testWidgets('the wordmark is what yields, and the page name is what stays',
      (tester) async {
    // Wide: both on screen, brand first.
    await _pumpBar(tester, title: 'Greece 2026', width: 1200);
    expect(find.text('Greece 2026'), findsOneWidget);
    expect(tester.getTopLeft(find.text(AppInfo.name)).dx,
        lessThan(tester.getTopLeft(find.text('Greece 2026')).dx));

    // Squeezed — trip detail's icon row on the smallest phone. Under #418 the
    // title went and `ANEMOS` stayed, so the traveler got a header naming the
    // app they had open rather than the trip they were looking at. Now it is
    // the other way round, and the rose in the leading slot keeps the brand on
    // screen on a tab root.
    await _pumpBar(tester, title: 'Greece 2026', actions: 3, width: 320);
    expect(find.text('Greece 2026'), findsOneWidget,
        reason: 'the page name is what a phone header is for');
    expect(find.text(AppInfo.name), findsNothing,
        reason: 'the wordmark is what yields on a squeezed phone bar');
    expect(find.byType(BrandLogo), findsOneWidget,
        reason: 'a tab root still shows the rose in its leading slot');
  });

  testWidgets('the wordmark yields on measurement, never on a breakpoint',
      (tester) async {
    // The regression guard for the cheap version of this fix. A narrow bar is
    // not automatically a cramped one: an iPad in portrait (744) and a
    // half-width desktop window (799) are both below kRailBreakpoint and both
    // have hundreds of pixels to spare, so gating on the breakpoint would
    // strip the wordmark off them for nothing.
    //
    // Deliberately paired with the squeeze case above — same title, same
    // locale, differing only in room. If the two stop disagreeing, the ladder
    // has become a threshold.
    for (final width in [744.0, 799.0]) {
      await _pumpBar(tester, title: 'Greece 2026', actions: 1, width: width);
      expect(find.text(AppInfo.name), findsOneWidget,
          reason: 'wordmark dropped at $width, which has room to spare');
      expect(find.text('Greece 2026'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('a phone hands the page name the wordmark\'s room',
      (tester) async {
    // Brian's screenshot, as an assertion. The bug was never that the title was
    // absent — it was 126px of `Plan your t…`, which cleared _minTitleWidth
    // comfortably and still read as broken chrome. The fix is that the word's
    // pixels go to the title, so that is what is asserted: the title starts at
    // the row's left edge, with no room for a word in front of it.
    //
    // GEOMETRY rather than "the string renders whole", because a widget test
    // renders in a fallback face where every glyph is a full em: 'Plan your
    // trip' measures ~311px here against ~143px of Marcellus in a browser. A
    // whole-string assertion at a real phone width would be testing the test
    // font. The real string at the real width is the browser pass's job.
    const title = 'Plan your trip';

    await _pumpBar(tester, title: title, actions: 1, width: 375);
    expect(find.text(title), findsOneWidget);
    expect(find.text(AppInfo.name), findsNothing);
    expect(tester.takeException(), isNull);

    // The row starts at the leading slot's edge, so the title's left is the
    // slot width plus its own Flexible's zero padding — i.e. it did not begin
    // a wordmark further in.
    expect(tester.getTopLeft(find.text(title)).dx,
        lessThan(kToolbarHeight + await _naturalWidth(tester)),
        reason: 'something wordmark-sized is still sitting in front of it');
  });

  testWidgets('a short page name renders whole beside the wordmark',
      (tester) async {
    // The other half of the pair above: the ladder admits a title only when it
    // fits WHOLE, so a short one keeps both. Short enough that even the test
    // font's em-per-glyph metrics fit at 375.
    const title = 'Greece 26';

    await _pumpBar(tester, title: title, width: 4000, inShell: false);
    final natural = tester.getSize(find.text(title)).width;

    await _pumpBar(tester, title: title, actions: 1, width: 375);
    expect(tester.getSize(find.text(title)).width,
        moreOrLessEquals(natural, epsilon: 0.5),
        reason: 'ellipsized despite fitting — the ladder is not measuring');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the rose lives in the leading slot and no longer yields to '
      'width', (tester) async {
    // It used to be rung 3 of the title row's ladder, dropped whenever the row
    // got tight — i.e. exactly when the bar looked most unbranded, and its
    // coming and going is half of the 108px the wordmark used to travel. In a
    // slot the title row cannot spend, it simply stays.
    for (final width in [_subPhoneWidth, 320.0, 360.0, 700.0]) {
      await _pumpBar(tester, actions: 3, width: width);
      final rose = find.byType(BrandLogo);
      expect(rose, findsOneWidget, reason: 'no rose at w=$width');
      expect(tester.getCenter(rose).dx,
          moreOrLessEquals(kToolbarHeight / 2, epsilon: 0.5),
          reason: 'the rose left the leading slot at w=$width');
      expect(tester.getTopLeft(find.text(AppInfo.name)).dx,
          greaterThanOrEqualTo(kToolbarHeight),
          reason: 'the wordmark reached back into the slot at w=$width');
    }
  });

  testWidgets('the bar floats the DARK mark on its neutral surface',
      (tester) async {
    // The bar's field is the neutral surface (the de-gradient pass, doc
    // v1.4), where the reversed white/teal-100 cut would wash out — the
    // exact inverse of the teal-on-teal problem that cut solved on the old
    // gradient. Nothing sits behind the rose (plate policy v3), so the cut
    // is load-bearing: swap this back to markLight and the brand vanishes
    // into the header. The rail pins the same artwork; the splash keeps the
    // reversed cut on its sanctioned teal field (splash_screen_test).
    await _pumpBar(tester, width: 700);

    final image = tester.widget<Image>(
      find.descendant(of: find.byType(BrandLogo), matching: find.byType(Image)),
    );
    expect(
      (image.image as AssetImage).assetName,
      'assets/images/anemos_mark.png',
    );
  });

  testWidgets('the bar is flat surface under a hairline, in both themes',
      (tester) async {
    // The de-gradient doctrine, pinned: a surface field in light AND dark
    // (the teal-in-dark exception is retired), separation by hairline
    // rather than elevation, and the wordmark carrying the brand ink
    // instead of the bar's foreground. Self-contained pump because
    // _pumpBar deliberately fixes AppTheme.light.
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      tester.view.physicalSize = const Size(700, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: testLocalizationsDelegates,
            supportedLocales: const [Locale('en'), Locale('es')],
            theme: theme,
            home: ShellScope(
              child: Scaffold(
                appBar: const GradientAppBar(),
                body: const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final bar = tester.widget<AppBar>(find.byType(AppBar));
      final scheme = theme.colorScheme;
      expect(bar.backgroundColor, scheme.surface,
          reason: 'the bar is surface in ${scheme.brightness}');
      expect(bar.shape, isA<Border>());
      expect((bar.shape as Border).bottom.color, scheme.outlineVariant,
          reason: 'separation is the hairline, not elevation');
      expect(bar.elevation, 0);

      final wordmark = tester.widget<Text>(find.text(AppInfo.name));
      expect(wordmark.style?.color, AppColors.wordmarkInk(scheme),
          reason: 'the wordmark carries the brand ink in ${scheme.brightness}');
    }
  });

  testWidgets('at rail widths the leading slot empties — but keeps its width',
      (tester) async {
    await _pumpBar(tester, width: 1200);
    expect(find.byType(BrandLogo), findsNothing,
        reason: 'two roses 80px apart is a duplicate, not a lockup');
    expect(find.text(AppInfo.name), findsOneWidget);
    final withRail = tester.getTopLeft(find.text(AppInfo.name)).dx;

    // The empty case is the inset, not an omission: drop the box and the
    // wordmark slides left the moment the window crosses kRailBreakpoint.
    await _pumpBar(tester, width: 700);
    expect(tester.getTopLeft(find.text(AppInfo.name)).dx,
        moreOrLessEquals(withRail, epsilon: 0.5),
        reason: 'the inset must hold even where the rose does not');

    // ...and the rail rule applies only when there IS a rail. The signed-out
    // pages are wide too, and dropping the mark there leaves it nowhere.
    await _pumpBar(tester, width: 1200, inShell: false);
    expect(find.byType(BrandLogo), findsOneWidget);
  });

  testWidgets('the brand links home inside the shell and is inert outside it',
      (tester) async {
    await _pumpBar(tester, width: 700);
    expect(
      find.ancestor(
          of: find.text(AppInfo.name), matching: find.byType(InkWell)),
      findsOneWidget,
      reason: 'logo-links-home, and exactly one target over the whole lockup',
    );

    await _pumpBar(tester, width: 700, inShell: false);
    expect(
      find.ancestor(
          of: find.text(AppInfo.name), matching: find.byType(InkWell)),
      findsNothing,
      reason: 'a "Home" tooltip that goes nowhere is a dead affordance',
    );
  });

  testWidgets('a page title stays readable to a screen reader', (tester) async {
    // The brand carries excludeSemantics (the mark and the word would
    // otherwise announce "Anemos" twice), so the title must sit outside it.
    final handle = tester.ensureSemantics();
    await _pumpBar(tester, title: 'Notifications', width: 1200);

    expect(find.bySemanticsLabel('Notifications'), findsOneWidget);
    expect(find.bySemanticsLabel(AppInfo.name), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the brand is two nodes now, and only one of them says "Anemos"',
      (tester) async {
    // Splitting the lockup across two AppBar slots is what makes the wordmark
    // sit still, and the risk it introduces is a stutter: the rose's own image
    // label is "Anemos" too, so an unlabelled slot would announce the product
    // name twice and bury the only thing about the control worth knowing.
    final handle = tester.ensureSemantics();
    await _pumpBar(tester, title: 'Notifications', width: 700);

    expect(find.bySemanticsLabel(AppInfo.name), findsOneWidget,
        reason: 'the rose must not announce the product name a second time');
    expect(find.bySemanticsLabel('Home'), findsOneWidget,
        reason: 'the rose is named by what it does');
    expect(find.bySemanticsLabel('Notifications'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('outside the shell the rose is decoration, not a node',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpBar(tester, width: 700, inShell: false);

    expect(find.bySemanticsLabel(AppInfo.name), findsOneWidget);
    expect(find.bySemanticsLabel('Home'), findsNothing,
        reason: 'a "Home" node that goes nowhere is a dead affordance');
    handle.dispose();
  });

  testWidgets('the page title drops at the same width pushed or not',
      (tester) async {
    // The other half of the invariant, and the one worth stating separately
    // because it is what the reserved slot BUYS. The title's drop threshold
    // used to depend on the back button — a pushed page paid 56px of leading
    // that a tab root did not — so trip detail lost its trip name at widths
    // where Trips still showed "My Trips". Now the two agree at every width.
    //
    // Deliberately relative rather than a hardcoded width: the exact
    // threshold moves with the font (the test's fallback face runs ~35% wider
    // than Cinzel), but "the same on both" does not, so this keeps meaning the
    // same thing where a pinned number would only be measuring the fallback.
    for (final width in _widths) {
      final counts = width >= 800 ? _wideActionCounts : _narrowActionCounts;
      for (final actions in counts) {
        await _pumpBar(tester,
            title: 'Greece 2026', actions: actions, width: width);
        final atRoot = find.text('Greece 2026').evaluate().length;

        await _pumpBar(tester,
            title: 'Greece 2026',
            actions: actions,
            width: width,
            pushed: true);
        expect(find.text('Greece 2026').evaluate().length, atRoot,
            reason: 'the title survives a back button differently: '
                'w=$width actions=$actions');
      }
    }
  });
}
