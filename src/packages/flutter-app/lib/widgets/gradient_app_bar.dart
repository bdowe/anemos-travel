import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/app_info.dart';
import '../l10n/l10n.dart';
import '../navigation/app_nav.dart';
import '../navigation/shell_scope.dart';
import '../providers/easter_egg_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../theme/spacing.dart';
import 'brand_logo.dart';

/// The rose, and the gap before the wordmark.
///
/// 36, not the 28 it was while plated, and measured rather than guessed: the
/// rose radiates from a small hub, so most of its box is empty and its optical
/// size runs well under its layout size. At 28 the reversed cut's gold
/// intercardinals antialias away against the gradient and it reads as a thin
/// white star; 32 is the floor and 36 reads as the wind rose it is. It is also
/// what the nav rail paints, so the brand is one size wherever it appears.
///
/// The arithmetic lands back on the plated cost exactly — 28 + the badge's two
/// 8px flanks + an 8px gap was also 52 — so retiring the plate moved no width
/// threshold in the ladder below.
const double _markSlot = 36 + AppSpacing.lg;

/// The brand's tap padding, which is [AppSpacing.xs] on every side.
const double _brandPadding = AppSpacing.xs * 2;

/// The interpunct and its gaps. Only ever decides whether the *title* fits,
/// so an approximation of the glyph is fine where the wordmark's is not.
const double _separatorSlot = AppSpacing.sm * 2 + 8;

/// How much page title is worth putting on screen at all. Below this there is
/// nothing left to ellipsize down to, so the title is dropped and the brand
/// takes the slot. The screens where that bites repeat their title in the
/// body — trip detail does, deliberately.
const double _minTitleWidth = 56;

/// App bar painted with [AppColors.brandGradient] — the same teal pair used by
/// the home hero banner. Use in place of [AppBar] so every screen shares one
/// header look.
///
/// **This bar carries the brand.** Every screen that uses it shows the ANEMOS
/// wordmark without doing anything, and no future screen can forget to: the
/// wordmark is a property of the house app bar, not a convention each screen
/// re-implements (`docs/zen.md` — explicit over implicit). Pass [title] for the
/// page's own name; it renders after the brand as `ANEMOS · Page title`. Pass
/// nothing where the brand *is* the title (Home, Landing).
///
/// Three things compete for the title slot, and the priority is fixed:
///
/// 1. **The wordmark** — always present, always the same size, never
///    ellipsized. That is the whole point.
/// 2. **The page title** — [Flexible], ellipsized, dropped below
///    [_titleMinWidth].
/// 3. **The mark** — dropped first, and always absent at rail widths, where
///    `_RailBrand` already shows the rose one corner over on the same centre
///    line (PR #406). Two roses 80px apart is a duplicate, not a lockup.
///
/// The rose floats bare here, as it does everywhere: this bar just takes the
/// reversed cut ([BrandLogo.markLight]) because its field is the teal gradient
/// and the dark artwork would be teal-on-teal. The white plate that used to
/// sit behind it is retired — see [BrandLogo]'s class doc for the policy and
/// why, and re-litigate it there rather than reintroducing a plate here.
class GradientAppBar extends ConsumerWidget implements PreferredSizeWidget {
  /// The page's own title. Null where the brand stands alone.
  final Widget? title;
  final List<Widget>? actions;

  /// Defaults to false: the brand is left-anchored, so the whole title row is
  /// too. (The app-wide [AppBarTheme] centres titles; this deliberately wins.)
  final bool? centerTitle;

  /// A [TabBar] or similar, as on [AppBar.bottom].
  final PreferredSizeWidget? bottom;

  /// Overrides what tapping the brand does. Home passes one to add its
  /// scroll-to-top; everything else inside the shell goes [goHome], and
  /// everything outside it is not tappable at all — see [ShellScope].
  final VoidCallback? onBrandTap;

  const GradientAppBar({
    super.key,
    this.title,
    this.actions,
    this.centerTitle,
    this.bottom,
    this.onBrandTap,
  });

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inShell = ShellScope.of(context);
    final onTap = onBrandTap ?? (inShell ? () => goHome(ref) : null);

    return AppBar(
      title: _BrandTitle(title: title, onTap: onTap, inShell: inShell),
      actions: actions,
      centerTitle: centerTitle ?? false,
      bottom: bottom,
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      // The page title is a heading, so it takes the display face — a trip
      // name reads the same here as it does in the header below it.
      //
      // Set here rather than on AppBarTheme.titleTextStyle because AppBar
      // folds foregroundColor into the *defaults* branch only
      // (`widget.titleTextStyle ?? appBarTheme.titleTextStyle ??
      // defaults.titleTextStyle?.copyWith(color: foregroundColor)`): a themed
      // style without a color would quietly paint every title onSurface —
      // dark text on the teal gradient. Hence the explicit white.
      //
      // Size holds at 22 despite the face change: Marcellus sets ~9% narrower
      // than Inter Bold, so the longest trip titles gain room here, not lose
      // it.
      titleTextStyle: const TextStyle(
        fontFamily: AppFonts.display,
        fontWeight: FontWeight.w400,
        fontSize: 22,
        letterSpacing: 0.2,
        color: Colors.white,
      ),
      flexibleSpace: Container(
        decoration: BoxDecoration(gradient: AppColors.brandGradient),
      ),
    );
  }
}

/// The app bar's title row: the brand, then the page's own title.
///
/// The tap target covers the brand only — tapping a page's name should not
/// navigate — which is also why `Semantics(excludeSemantics: true)` wraps just
/// the brand. Wrapping the whole row would swallow the page title from screen
/// readers and hand the title a "Home" button role it does not have.
class _BrandTitle extends ConsumerWidget {
  final Widget? title;
  final VoidCallback? onTap;

  /// Whether this bar is inside the persistent shell — which is what decides
  /// if there is a rail out there to carry the mark. Window width alone would
  /// be wrong: the signed-out screens (landing, auth, shared trip) are wide
  /// too, and dropping the mark there leaves it nowhere.
  final bool inShell;

  const _BrandTitle(
      {required this.title, required this.onTap, required this.inShell});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Measures the true title slot, so the thresholds above are stated in the
    // width the row actually gets — the tap padding sits inside this, not
    // around it.
    return LayoutBuilder(
      builder: (context, constraints) {
        // Same measurement the shell uses to decide rail-vs-bar, not the slot
        // width: whether the rail is on screen is a window question.
        final railCarriesMark =
            inShell && MediaQuery.sizeOf(context).width >= kRailBreakpoint;

        // The ladder, as arithmetic on what the wordmark actually measures —
        // so it holds under a missing font or a large text-scale setting,
        // where fixed thresholds would silently start clipping.
        final slot = constraints.maxWidth;
        final brandCost = _brandPadding + BrandWordmark.widthIn(context);
        final titleCost = _separatorSlot + _minTitleWidth;

        final showTitle = title != null && slot >= brandCost + titleCost;
        final showMark = !railCarriesMark &&
            slot >= brandCost + _markSlot + (showTitle ? titleCost : 0);

        Widget brand = Padding(
          padding: const EdgeInsets.all(AppSpacing.xs),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showMark) ...const [
                // markLight, not mark: this field is the teal brand gradient,
                // where the dark rose is teal-on-teal — its cardinals all but
                // disappear and it reads as a gold asterisk. Retiring the
                // plate is what made the reversed cut necessary here.
                BrandLogo.markLight(size: 36),
                SizedBox(width: AppSpacing.lg),
              ],
              const BrandWordmark(),
            ],
          ),
        );

        // The mark's Image already carries the "Anemos" semantic label and the
        // wordmark is the literal word, so without excludeSemantics a screen
        // reader announces this twice.
        //
        // container: true makes this a semantics boundary. Without it the
        // brand's annotations merge with the page title beside it into one
        // node — announced as a run-on "Anemos Notifications" that also
        // claims the brand's button role on behalf of the title.
        brand = Semantics(
          container: true,
          button: onTap != null,
          label: AppInfo.name,
          excludeSemantics: true,
          child: brand,
        );

        if (onTap != null) {
          brand = Tooltip(
            message: context.l10n.shellNavHome,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
                borderRadius: AppRadius.mdAll,
                child: brand,
              ),
            ),
          );
        }

        // The touch way into the easter egg (specs/konami-rickroll): seven
        // taps in quick succession. Deliberately OUTSIDE the `onTap != null`
        // branch — the brand is not tappable on the signed-out screens, and
        // the landing page is exactly where somebody idly prodding the logo
        // is standing.
        //
        // A Listener, not a GestureDetector: raw pointer events never enter
        // the gesture arena, so this cannot compete with the InkWell above
        // for the tap (nested recognizers resolve to the innermost, and the
        // outer one would simply never fire). It adds no ripple, no tap
        // target and no semantics, so the brand looks and reads exactly as it
        // did — including on the screens where it is not a button.
        brand = Listener(
          onPointerDown: (_) =>
              ref.read(rickRollProvider.notifier).brandTapped(),
          child: brand,
        );

        if (!showTitle) {
          // Nothing left to compete with, so this is the one place a squeeze
          // can be absorbed: scale rather than clip. In release builds a
          // RenderFlex overflow does not stripe, it silently cuts glyphs off —
          // and a truncated wordmark is the exact failure this widget exists
          // to prevent. The ladder above is supposed to make this unreachable;
          // brand_everywhere_test asserts it stays that way.
          return SizedBox(
            width: constraints.maxWidth,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: brand,
            ),
          );
        }

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            brand,
            const _BrandSeparator(),
            // The 20 screens that pass a bare Text keep ellipsizing correctly
            // without any of them being edited.
            Flexible(
              child: DefaultTextStyle.merge(
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                child: title!,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The interpunct between the brand and the page title, dimmed so the pairing
/// reads as "brand, then page" rather than as two equal headings.
class _BrandSeparator extends StatelessWidget {
  const _BrandSeparator();

  @override
  Widget build(BuildContext context) {
    final color = DefaultTextStyle.of(context).style.color;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: ExcludeSemantics(
        child: Text(
          '·',
          style: TextStyle(color: color?.withValues(alpha: 0.55)),
        ),
      ),
    );
  }
}
