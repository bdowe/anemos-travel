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

/// The width the title row always starts after, whatever is standing in it.
///
/// [kToolbarHeight] because that is exactly what [AppBar] hands an implied
/// [BackButton] (`_kLeadingWidth`), and matching it is the entire mechanism
/// here: [AppBar] wraps whichever leading it ends up with — ours or the one it
/// implied — in a `tightFor(width:)` box of this size, so the two cases are
/// provably the same width rather than incidentally similar.
const double _leadingSlot = kToolbarHeight;

/// The rose's own size wherever this bar paints it.
///
/// 36, not the 28 it was while plated, and measured rather than guessed: the
/// rose radiates from a small hub, so most of its box is empty and its optical
/// size runs well under its layout size. At 28 the reversed cut's gold
/// intercardinals antialias away against the gradient and it reads as a thin
/// white star; 32 is the floor and 36 reads as the wind rose it is. It is also
/// what the nav rail paints, so the brand is one size wherever it appears.
const double _markSize = 36;

/// The rose's tap box, centred inside the [_leadingSlot].
///
/// [kMinTouchTarget], not the full slot: `titleSpacing: 0` puts the wordmark's
/// own target at x = 56, so a 56-wide ripple here would run flush into it and
/// the two halves of the brand would read as one smeared control.
const double _leadingTapBox = kMinTouchTarget;

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
/// **The wordmark's left edge is the same on every screen**, and that too is a
/// property of this bar rather than of any page. It did not use to be, in two
/// independent ways that added up to 108px of travel on a 390px phone: [AppBar]
/// starts the title at `titleSpacing` on a route with nothing to dismiss and at
/// `leadingWidth + titleSpacing` on one with a back button, and the rose used to
/// live *inside* the title row behind a width gate that flipped with whatever
/// actions a page happened to carry. So the rose moved out. The leading slot is
/// always [_leadingSlot] wide and only its *occupant* varies:
///
/// - the back or close button, whenever [AppBar] would imply one;
/// - the rose, when it would not;
/// - nothing, at rail widths inside the shell, where `_RailBrand` already shows
///   the rose one corner over on the same centre line (PR #406) — two roses
///   80px apart is a duplicate, not a lockup. The slot still holds its width
///   there: an empty gutter beside the rail costs nothing, and making the inset
///   conditional is how the jump would come back.
///
/// [titleSpacing] is 0 to pay for most of that, and it is not a cosmetic
/// tightening: [NavigationToolbar] charges `middleSpacing` on BOTH sides of the
/// title, so the default 16 costs 32. Reserving the slot therefore costs a tab
/// root a net 24px of title budget, not 56. Nothing separates the title from
/// [actions] now except an [IconButton]'s own padding, which measures fine.
///
/// Two things then compete for the title slot, and the priority is fixed:
///
/// 1. **The wordmark** — always present, always the same size, never
///    ellipsized. That is the whole point.
/// 2. **The page title** — [Flexible], ellipsized, dropped below
///    [_minTitleWidth].
///
/// Rung 2 barely moves on a tab root — 24px shifts the drop threshold by about
/// a phone-width hair, and Trips reads the same at 320 (dropped, as before),
/// 360 (ellipsized) and 390 (whole). On a **pushed** page it moves a long way
/// the *good* way: the rose leaving the row hands the title back the 52px it
/// used to spend, which is why trip detail now shows its trip name on a phone
/// at all. Measured in a browser against real Cinzel, not computed — the
/// numbers here are easy to get wrong and the comment is load-bearing.
///
/// The rose floats bare, as it does everywhere: this bar just takes the
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

    // Whether [AppBar] will fill the leading slot itself — the same pair of
    // conditions `AppBar.build` tests, asked one layer up so we can decide what
    // goes in the slot when the answer is no. We only ever fill a slot AppBar
    // would have left empty.
    //
    // `impliesAppBarDismissal` deliberately, not its near-twin `canPop`, which
    // also counts local history entries AppBar ignores: reading the other one
    // would let this widget suppress a back button Flutter was never going to
    // draw. The drawer term is unreachable today — nothing in the app sets
    // `Scaffold.drawer` — but a hamburger would land in exactly this slot, and
    // a leading we supplied would silently swallow it.
    final scaffold = Scaffold.maybeOf(context);
    final appBarFillsLeading =
        (ModalRoute.of(context)?.impliesAppBarDismissal ?? false) ||
            (scaffold?.hasDrawer ?? false);

    // A window question, not a slot-width one: whether the rail is on screen.
    // Width alone would be wrong — the signed-out screens (landing, auth,
    // shared trip) are wide too, and there is no rail out there to carry it.
    final railCarriesMark =
        inShell && MediaQuery.sizeOf(context).width >= kRailBreakpoint;

    return AppBar(
      // Non-null exactly when AppBar would have left this empty. That is what
      // holds the wordmark still across a navigation.
      leading: appBarFillsLeading
          ? null
          : _LeadingSlot(showMark: !railCarriesMark, onTap: onTap),
      // Stated, not left to the default: the `appBarFillsLeading ? null` above
      // only means anything while this is true.
      automaticallyImplyLeading: true,
      // Pinned rather than inherited. AppBar's own default is already
      // kToolbarHeight, so this changes nothing today — it stops a future
      // AppBarTheme.leadingWidth from moving the wordmark on 22 screens at
      // once. Note the width is not what creates the invariant: AppBar only
      // charges a leading width when there IS a leading, so passing a non-null
      // one is the load-bearing half.
      leadingWidth: _leadingSlot,
      // 0, not the default 16: the leading slot already separates the brand
      // from whatever precedes it, and on a phone those 16px are worth more as
      // title width. See [_titleEndGap] for what this costs on the other side.
      titleSpacing: 0,
      title: _BrandTitle(title: title, onTap: onTap),
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

/// What stands in the leading slot on a route [AppBar] would leave empty.
///
/// Two jobs, and the invisible one is the load-bearing one: it holds
/// [_leadingSlot] open so the title row starts at the same x here as it does
/// under a back button. The rose is simply a better thing to spend that space
/// on than a hole — and this is where the rose lives now, having been moved out
/// of the title row precisely because its presence there moved the wordmark.
class _LeadingSlot extends ConsumerWidget {
  /// False at rail widths inside the shell, where `_RailBrand` already carries
  /// the rose. The slot keeps its width either way.
  final bool showMark;

  /// The brand's tap behaviour, or null outside the shell — same value the
  /// wordmark gets, so both halves of the brand do the same thing.
  final VoidCallback? onTap;

  const _LeadingSlot({required this.showMark, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The slot's width comes from AppBar's tightFor(width: leadingWidth) box,
    // so an empty child still holds it open.
    if (!showMark) return const SizedBox.shrink();

    // markLight, not mark: this field is the teal brand gradient, where the
    // dark rose is teal-on-teal — its cardinals all but disappear and it reads
    // as a gold asterisk. Retiring the plate is what made the reversed cut
    // necessary here.
    Widget mark = const SizedBox(
      width: _leadingTapBox,
      height: _leadingTapBox,
      child: Center(child: BrandLogo.markLight(size: _markSize)),
    );

    if (onTap != null) {
      // Labelled "Home", not [AppInfo.name]: the wordmark beside it is already
      // the brand's node, and two "Anemos, button" nodes in one bar is a
      // stutter rather than a lockup. excludeSemantics drops the asset's own
      // "Anemos" label, which is the other half of that same duplicate.
      mark = Semantics(
        container: true,
        button: true,
        label: context.l10n.shellNavHome,
        excludeSemantics: true,
        child: mark,
      );

      mark = Tooltip(
        message: context.l10n.shellNavHome,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: mark,
          ),
        ),
      );
    } else {
      // Outside the shell the brand does not navigate, so this is decoration —
      // and decoration that would otherwise announce the name the wordmark
      // beside it already carries.
      mark = ExcludeSemantics(child: mark);
    }

    // The same seven-tap way into the easter egg the wordmark offers
    // (specs/konami-rickroll), and outside the tappable branch for the same
    // reason: the landing page is exactly where somebody idly prodding the
    // logo is standing, and the brand is not a button there.
    //
    // A Listener, not a GestureDetector: raw pointer events never enter the
    // gesture arena, so this cannot compete with the InkWell above for the tap.
    // Centred inside the slot AppBar tight-constrained us to, so the rose sits
    // on the same optical centre a back button would.
    return Center(
      child: Listener(
        onPointerDown: (_) => ref.read(rickRollProvider.notifier).brandTapped(),
        child: mark,
      ),
    );
  }
}

/// The app bar's title row: the wordmark, then the page's own title.
///
/// The tap target covers the brand only — tapping a page's name should not
/// navigate — which is also why `Semantics(excludeSemantics: true)` wraps just
/// the brand. Wrapping the whole row would swallow the page title from screen
/// readers and hand the title a "Home" button role it does not have.
///
/// Nothing here depends on the leading slot's occupant, which is the property
/// that makes the wordmark's left edge invariant: this row is measured and
/// positioned identically whether a back button, the rose, or nothing at all is
/// standing to its left.
class _BrandTitle extends ConsumerWidget {
  final Widget? title;
  final VoidCallback? onTap;

  const _BrandTitle({required this.title, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Measures the true title slot, so the thresholds above are stated in the
    // width the row actually gets — the tap padding sits inside this, not
    // around it.
    return LayoutBuilder(
      builder: (context, constraints) {
        // The ladder, as arithmetic on what the wordmark actually measures —
        // so it holds under a missing font or a large text-scale setting,
        // where fixed thresholds would silently start clipping.
        // Two rungs now, not three: the only question this row still asks is
        // whether a page title fits beside the word.
        final slot = constraints.maxWidth;
        final brandCost = _brandPadding + BrandWordmark.widthIn(context);

        final showTitle =
            title != null && slot >= brandCost + _separatorSlot + _minTitleWidth;

        Widget brand = const Padding(
          padding: EdgeInsets.all(AppSpacing.xs),
          child: BrandWordmark(),
        );

        // The wordmark is the literal word, so its Text node already announces
        // "Anemos"; excludeSemantics lets this one node carry both the name and
        // the button role instead of a label sitting on top of a duplicate.
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
