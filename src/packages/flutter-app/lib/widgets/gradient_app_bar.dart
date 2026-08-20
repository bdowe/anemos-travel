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

/// The mark's own size wherever this bar paints it.
///
/// 40, and measured rather than guessed. Box sizes are not comparable across
/// two different drawings, so the number to reason about is what actually
/// lands on the pixels: the Threaded Bezel's ink fills 94% of its square
/// artboard, so 40 paints a 38px mark. The bar carried 36 of the old bare
/// rose, whose ink was only 76% of its artboard — that painted 27px. The box
/// shrank and the logo grew by 38%.
///
/// 40 rather than 44, which the bezel would also survive: at 44 it paints
/// 41px into a 56px bar and the ring's tick marks come within 7px of the
/// hairline bottom border, which reads crowded rather than confident. 40 is
/// also exactly the nav rail's pinned tap box (`app_shell.dart`), so the
/// brand is one size wherever it appears AND the rail needs no overflow
/// trickery to paint it.
const double _markSize = 40;

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

/// The house app bar: flat [ColorScheme.surface] in both themes under a
/// hairline [ColorScheme.outlineVariant] bottom border. The brand rides in the
/// wordmark's ink ([AppColors.wordmarkInk]) and the rose — never in a colored
/// field. It painted [AppColors.brandGradient] until the de-gradient pass
/// unsanctioned that as the brand surface (DESIGN.md § Colors); the file and
/// class names are historical and rename in a follow-up, once the lanes
/// holding call sites still have merged. Use in place of [AppBar] so every
/// screen shares one header look.
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
/// Two things then compete for the title slot, and **the wordmark is the one
/// that yields**:
///
/// 1. **The page title** — whole, if the row can hold it whole.
/// 2. **The wordmark** — always the same size and never ellipsized, but it
///    steps out of the row when keeping it is exactly what would clip the
///    page's own name. It never yields at rail widths, where it is the bar's
///    only brand (the rose is on the rail, not in the leading slot).
///
/// That ordering is the reverse of PR #418's, and it was reversed by what the
/// old one shipped to a phone: `ANEMOS · Plan your t…`. A stub of a page name
/// tells a traveler nothing they did not already know, and on a tab root the
/// bottom bar names the tab one row down anyway.
///
/// **Measured, not thresholded.** `width < kRailBreakpoint` would strip the
/// wordmark off a 744px iPad in portrait and a 799px desktop window, both of
/// which have hundreds of pixels to spare. Measuring means nothing changes
/// anywhere there is room — which, after the 84px the leading slot and
/// `titleSpacing: 0` above hand back, is most places: at 390px a tab root now
/// fits `ANEMOS · Plan your trip` whole and the ladder never reaches rung 2.
/// What still reaches it are the long ones — a trip name, `Set up your travel
/// profile`, Spanish — and on a pushed page, where the leading slot holds a
/// back button rather than the rose, that leaves the bar carrying no brand at
/// all. Deliberate: back-button + the thing you opened is the universal mobile
/// header, and the traveler branded the app one tap ago.
///
/// Rung ordering aside, the threshold arithmetic barely moves on a tab root —
/// 24px shifts it by about a phone-width hair, and Trips reads the same at 320,
/// 360 and 390. On a **pushed** page it moves a long way the *good* way: the
/// rose leaving the row hands the title back the 52px it used to spend, which
/// is why trip detail shows its trip name on a phone at all. Measured in a
/// browser against the real wordmark face, not computed — the numbers here
/// are easy to get wrong and the comment is load-bearing.
///
/// The rose floats bare, as it does everywhere: this bar takes the dark cut
/// ([BrandLogo.mark]) — the same artwork the nav rail already paints on this
/// same neutral surface in both themes, so the brand is one artwork wherever
/// it stands on chrome. (The reversed cut now belongs to the splash's teal
/// field alone.) The white plate that used to sit behind it is retired — see
/// [BrandLogo]'s class doc for the policy and why, and re-litigate it there
/// rather than reintroducing a plate here.
class GradientAppBar extends ConsumerWidget implements PreferredSizeWidget {
  /// The page's own title. Null where the brand stands alone.
  ///
  /// Text, not a [Widget], because the ladder has to **measure** it to decide
  /// what fits — and a widget cannot be measured before it is laid out. Taking
  /// the string also puts the whole title contract in one place: this bar owns
  /// its face, its colour, its `maxLines` and its ellipsis, instead of owning
  /// half of them and trusting twenty call sites for the rest.
  final String? title;
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

  /// Cross-fade the title row when [title] appears or disappears, instead of
  /// swapping it outright.
  ///
  /// For a page that hands its title to this bar only once its own copy has
  /// scrolled away (trip detail's collapse). The two states are different
  /// WIDGETS, not one string changing — on a phone the ladder below has the
  /// wordmark yield as the title arrives — so this cannot be an opacity on
  /// the Text; both sides have to be measured and cross-faded.
  ///
  /// Opt-in, and default false, so a bar whose title never changes is
  /// byte-identical to before: an AnimatedSwitcher that never switches still
  /// inserts a Stack into every app bar in the app, and this is not worth
  /// spending on twenty screens with static titles.
  final bool animateTitle;

  const GradientAppBar({
    super.key,
    this.title,
    this.actions,
    this.centerTitle,
    this.bottom,
    this.onBrandTap,
    this.animateTitle = false,
  });

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  /// The face a page title paints in, exposed so anything that needs to
  /// *measure* one uses the exact numbers it renders with — see [titleWidthIn].
  /// Same pairing as [BrandWordmark.styleOf]/[BrandWordmark.widthIn], for the
  /// same reason: two copies of a font spec drift, and the drift shows up as a
  /// clipped header nobody can reproduce.
  ///
  /// The page title is a heading, so it takes the display face — a trip name
  /// reads the same here as it does in the header below it.
  ///
  /// Deliberately colorless: the color is applied at build
  /// (`copyWith(color: onSurface)`) because it is a theme answer, and handed
  /// to [AppBar.titleTextStyle] rather than to `AppBarTheme.titleTextStyle`
  /// because AppBar folds `foregroundColor` into the *defaults* branch only
  /// (`widget.titleTextStyle ?? appBarTheme.titleTextStyle ??
  /// defaults.titleTextStyle?.copyWith(color: foregroundColor)`) — a themed
  /// style without a color silently drops the bar's own foreground. Width
  /// measurement doesn't care about color, so [titleWidthIn] uses this const
  /// as-is.
  ///
  /// Size holds at 22 despite the face change: Marcellus sets ~9% narrower than
  /// Inter Bold, so the longest trip titles gain room here, not lose it.
  static const TextStyle titleStyle = TextStyle(
    fontFamily: AppFonts.display,
    fontWeight: FontWeight.w400,
    fontSize: 22,
    letterSpacing: 0.2,
  );

  /// How wide [text] will actually paint as a page title in [context].
  ///
  /// Measured for the same reasons [BrandWordmark.widthIn] is: Marcellus may
  /// not have loaded (widget tests fall back to a font of quite different
  /// metrics), and the traveler's text-scale setting multiplies the answer. The
  /// ladder is arithmetic on this number, so a hardcoded width would decide
  /// "it fits" for a large-text user it does not fit for.
  static double titleWidthIn(BuildContext context, String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: titleStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
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

    // railCarriesMark is passed down rather than recomputed: it is the same
    // fact the leading slot below turns on, and the ladder needs it to know
    // whether the wordmark is the bar's ONLY brand (rail widths) or has a
    // rose standing beside it.
    Widget titleRow = _BrandTitle(
        title: title, onTap: onTap, railCarriesMark: railCarriesMark);

    if (animateTitle) {
      titleRow = AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        // Opacity alone. AnimatedSwitcher's default pairs the fade with a
        // scale, which on a 22px inscriptional serif reads as a wobble.
        transitionBuilder: (child, animation) =>
            FadeTransition(opacity: animation, child: child),
        // The default layout stacks children CENTRED, which would slide the
        // row horizontally for the length of the transition — and the whole
        // point of this bar is that the title row's left edge does not move.
        layoutBuilder: (current, previous) => Stack(
          alignment: AlignmentDirectional.centerStart,
          children: [...previous, if (current != null) current],
        ),
        // Keyed on PRESENCE, not on the string: this animates the title
        // arriving and leaving, and a page that renames itself in place still
        // just repaints.
        child: KeyedSubtree(key: ValueKey(title != null), child: titleRow),
      );
    }

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
      title: titleRow,
      actions: actions,
      centerTitle: centerTitle ?? false,
      bottom: bottom,
      // The flat chrome bar: surface in BOTH themes (dark mode is the same
      // build with brightness flipped — no more teal-in-dark exception), with
      // a hairline bottom border doing the separating. Elevation is zeroed and
      // the tint pinned transparent so separation stays an explicit color
      // choice (the No-Tint Rule) — never a scroll side effect.
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      // Rationale on [titleStyle] itself, which is also what the ladder
      // measures against; the color joins here because it is the theme's
      // answer, not the style's.
      titleTextStyle: titleStyle.copyWith(color: scheme.onSurface),
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

    // The dark cut, exactly as the nav rail paints it: the field is the
    // neutral surface now, where the reversed cut would wash out. One artwork
    // on all chrome, in both themes — the rail is the precedent.
    Widget mark = const SizedBox(
      width: _leadingTapBox,
      height: _leadingTapBox,
      child: Center(child: BrandLogo.mark(size: _markSize)),
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
  final String? title;
  final VoidCallback? onTap;

  /// Whether the rail is showing the rose, which is the one case where this
  /// row's wordmark is the bar's ONLY brand — so the one case where it does
  /// not step aside for a page title.
  final bool railCarriesMark;

  const _BrandTitle(
      {required this.title,
      required this.onTap,
      required this.railCarriesMark});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Measures the true title slot, so the thresholds above are stated in the
    // width the row actually gets — the tap padding sits inside this, not
    // around it.
    return LayoutBuilder(
      builder: (context, constraints) {
        // The ladder, as arithmetic on what the wordmark and the title
        // actually measure — so it holds under a missing font or a large
        // text-scale setting, where fixed thresholds would silently start
        // clipping. Two rungs, and the wordmark is the one that yields.
        final slot = constraints.maxWidth;
        final brandCost = _brandPadding + BrandWordmark.widthIn(context);
        final titleWidth = title == null
            ? 0.0
            : GradientAppBar.titleWidthIn(context, title!);

        // What the title gets with the word beside it, and what it gets with
        // the row to itself.
        final roomBesideWordmark = slot - brandCost - _separatorSlot;

        final bool showWordmark, showTitle;
        if (title == null) {
          // Home and Landing: the brand IS the title, so nothing competes.
          showWordmark = true;
          showTitle = false;
        } else if (roomBesideWordmark >= titleWidth) {
          // Room for both — which, after the leading slot handed back 84px, is
          // most bars including a 390px tab root. Nothing yields when nothing
          // has to, so this is also every width at or above the rail.
          showWordmark = true;
          showTitle = true;
        } else if (railCarriesMark) {
          // The rail has the rose, so the word is this bar's only brand and
          // cannot leave. Ellipsize the title as before, and drop it below the
          // floor. Unreachable in practice — a rail-width bar has the room —
          // but stating it is what keeps #418's promise true by construction
          // rather than by luck.
          showWordmark = true;
          showTitle = roomBesideWordmark >= _minTitleWidth;
        } else if (slot - _brandPadding >= _minTitleWidth) {
          // The wordmark steps out so the page's own name can be read. On a
          // tab root the rose is still in the leading slot; on a pushed page
          // the back button is, and the bar carries no brand — see the class
          // doc, that is the deliberate half of this.
          showWordmark = false;
          showTitle = true;
        } else {
          // Not even a stub fits. Fall back to the brand alone and let the
          // FittedBox below absorb the squeeze.
          showWordmark = true;
          showTitle = false;
        }

        // The wordmark takes the brand ink, not the bar's onSurface
        // foreground: on the neutral field the ink IS where the teal
        // survives (Harbor Dark in light, scheme primary in dark).
        Widget brand = Padding(
          padding: const EdgeInsets.all(AppSpacing.xs),
          child: BrandWordmark(
            color: AppColors.wordmarkInk(Theme.of(context).colorScheme),
          ),
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
            // Both drop together: the interpunct pairs the brand with the page,
            // and with no brand in the row it is a bullet in front of a
            // sentence.
            if (showWordmark) ...[brand, const _BrandSeparator()],
            // Flexible, so a title the ladder admitted but cannot fit whole —
            // an unbounded trip name — ellipsizes instead of overflowing.
            Flexible(
              child: Text(
                title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
