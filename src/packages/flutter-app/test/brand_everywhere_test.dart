import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/constants/app_info.dart';
import 'package:travel_route_planner/navigation/shell_scope.dart';
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
/// Two things are asserted everywhere, and they are the promise: the wordmark
/// is **present**, and it is **neither truncated nor scaled down**. A brand
/// that survives as "ANEM…" or as illegibly small type has not survived.
///
/// The action counts are a ceiling, not decoration. Five icons fit beside the
/// wordmark at rail widths and nowhere near it on a phone — which is why trip
/// detail folds two of its five into the overflow below 800px. Add a fourth
/// narrow action anywhere and [_narrowActionCounts] is what fails.
const _widths = <double>[320, 360, 390, 700, 800, 1200];
const _narrowActionCounts = <int>[0, 2, 3];
const _wideActionCounts = <int>[0, 2, 5];

/// Below every real device width. The ladder runs out of room here and the
/// FittedBox backstop in gradient_app_bar.dart takes over: the word still
/// renders whole, just smaller. Covered separately and deliberately, so the
/// strict matrix above keeps meaning what it says.
const double _subPhoneWidth = 230;

Future<void> _pumpBar(
  WidgetTester tester, {
  Widget? title,
  int actions = 0,
  required double width,
  bool inShell = true,
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
  await tester.pumpWidget(
    ProviderScope(
      child: localizedTestApp(
        locale: locale,
        theme: AppTheme.light,
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: content,
          ),
        ),
      ),
    ),
  );
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
        for (final title in [null, const Text('Greece 2026')]) {
          await _pumpBar(tester, title: title, actions: actions, width: width);
          _expectWordmarkFullSize(tester, natural,
              'w=$width actions=$actions title=${title == null ? 'none' : 'yes'}');
        }
      }
    }
  });

  testWidgets('outside the shell too — the signed-out pages are pages',
      (tester) async {
    final natural = await _naturalWidth(tester);

    for (final width in _widths) {
      await _pumpBar(tester,
          title: const Text('Connect app'), width: width, inShell: false);
      _expectWordmarkFullSize(tester, natural, 'outside shell, w=$width');
    }
  });

  testWidgets('and in Spanish, whose titles run longer', (tester) async {
    final natural = await _naturalWidth(tester);

    for (final width in _widths) {
      await _pumpBar(tester,
          // The longest app-bar title the app ships (quizTitle, es).
          title: const Text('Configura tu perfil de viaje'),
          actions: 2,
          width: width,
          locale: const Locale('es'));
      _expectWordmarkFullSize(tester, natural, 'es, w=$width');
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
            title: const Text('Greece 2026'),
            actions: actions,
            width: width,
            textScale: scale);
        _expectWordmarkWhole(tester, natural, where);

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

  testWidgets('the page title is what yields — ellipsized, then dropped',
      (tester) async {
    // Wide: both on screen, brand first.
    await _pumpBar(tester, title: const Text('Greece 2026'), width: 1200);
    expect(find.text('Greece 2026'), findsOneWidget);
    expect(tester.getTopLeft(find.text(AppInfo.name)).dx,
        lessThan(tester.getTopLeft(find.text('Greece 2026')).dx));

    // Squeezed to nothing: the title goes, the brand stays. Trip detail on
    // the smallest phone is the real shape here, and it repeats its title in
    // the body one line down.
    await _pumpBar(tester,
        title: const Text('Greece 2026'), actions: 3, width: 320);
    expect(find.text('Greece 2026'), findsNothing);
    expect(find.text(AppInfo.name), findsOneWidget);
  });

  testWidgets('the mark yields before the wordmark does', (tester) async {
    // Roomy phone bar: plated mark and wordmark together.
    await _pumpBar(tester, width: 700);
    expect(find.byType(BrandLogo), findsOneWidget);
    expect(find.text(AppInfo.name), findsOneWidget);

    // Squeezed — trip detail's three icons on the smallest phone. The mark
    // goes first; the word is what has to remain.
    await _pumpBar(tester, actions: 3, width: 320);
    expect(find.byType(BrandLogo), findsNothing);
    expect(find.text(AppInfo.name), findsOneWidget);
  });

  testWidgets('at rail widths the bar drops the mark — the rail has it',
      (tester) async {
    await _pumpBar(tester, width: 1200);
    expect(find.byType(BrandLogo), findsNothing,
        reason: 'two roses 80px apart is a duplicate, not a lockup');
    expect(find.text(AppInfo.name), findsOneWidget);

    // ...but only when there IS a rail. The signed-out pages are wide too,
    // and dropping the mark there leaves it nowhere.
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
    await _pumpBar(tester, title: const Text('Notifications'), width: 1200);

    expect(find.bySemanticsLabel('Notifications'), findsOneWidget);
    expect(find.bySemanticsLabel(AppInfo.name), findsOneWidget);
    handle.dispose();
  });
}
