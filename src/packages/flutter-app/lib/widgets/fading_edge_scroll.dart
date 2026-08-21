import 'package:flutter/material.dart';

import '../theme/spacing.dart';

/// How much of each edge fades, as a fraction of the viewport, leading
/// first. The whole rule lives here rather than inside the widget's state so
/// it can be read — and pinned — without rasterizing a gradient: which edge
/// fades and when is the entire contract.
///
/// Zero on an edge that has nothing past it. A rail resting at either end,
/// or one whose content fits, gets no fade there, because a fade means
/// "there is more this way" and must not say so when there isn't.
///
/// Capped at 0.4 a side so the two can never meet and wash out the middle of
/// a narrow rail.
@visibleForTesting
(double, double) fadingEdgeFractions({
  required double pixels,
  required double minExtent,
  required double maxExtent,
  required double viewport,
  required double fadeWidth,
}) {
  if (viewport <= 0) return (0, 0);
  // Sub-pixel slop, so a rail resting exactly at either end doesn't flicker
  // its fade on a fractional offset.
  const epsilon = 1.0;
  final f = (fadeWidth / viewport).clamp(0.0, 0.4);
  return (
    pixels > minExtent + epsilon ? f : 0.0,
    pixels < maxExtent - epsilon ? f : 0.0,
  );
}

/// Wraps a scroll view and dissolves whichever edge still has content past
/// it, so a rail that continues off-screen says so instead of ending on a
/// hard cut that reads like the last card.
///
/// It fades to TRANSPARENT rather than painting a gradient of the page
/// colour over the content: the page behind shows through, so the effect is
/// correct in both themes and on any surface the rail is dropped onto,
/// without the widget having to know which one it is sitting on.
///
/// The edges are computed from the scroll position, never assumed. A rail
/// whose cards all fit fades neither edge; one scrolled to the end stops
/// fading the end. A permanent trailing fade would promise more to see at
/// precisely the moment there is none left — the same reason
/// `BookingFilterBar` listens to its offset rather than painting a constant
/// gradient.
///
/// The mask stays in the tree at every offset and only its GRADIENT changes.
/// Swapping the [ShaderMask] in and out instead re-parents the scroll view,
/// which rebuilds it and drops the [ScrollController]'s position — the trap
/// `BookingFilterBar` documents, and the reason [builder] hands the caller a
/// controller rather than taking a finished child.
class FadingEdgeScroll extends StatefulWidget {
  /// Builds the scroll view, which MUST take the [ScrollController] it is
  /// handed — the fade is derived from that controller's position.
  final Widget Function(BuildContext context, ScrollController controller)
      builder;

  /// How wide each fade runs, in logical pixels. Resolved against the
  /// viewport at paint time, so a narrow window gets a proportionate hint
  /// rather than a wash over half its content.
  final double fadeWidth;

  /// Two ladder steps, and it is the smaller half of that pair that decides
  /// it: at [AppSpacing.xxl] alone the dissolve over a 230px card is present
  /// but easy to miss, which is the complaint this widget answers rather
  /// than a setting of it. Rendered against the real card rhythm at 24 / 32 /
  /// 56 / 80 — 80 erases the cropped card, 56 reads as cropped.
  static const double defaultFadeWidth = AppSpacing.xxl + AppSpacing.xl;

  const FadingEdgeScroll({
    super.key,
    required this.builder,
    this.fadeWidth = defaultFadeWidth,
  });

  @override
  State<FadingEdgeScroll> createState() => _FadingEdgeScrollState();
}

class _FadingEdgeScrollState extends State<FadingEdgeScroll> {
  final ScrollController _controller = ScrollController();

  /// The two fades as fractions of the viewport, leading first. A record, so
  /// an unchanged pair is structurally equal and the notifier stays quiet —
  /// this is written on every scroll frame.
  final ValueNotifier<(double, double)> _edges =
      ValueNotifier<(double, double)>((0, 0));

  @override
  void initState() {
    super.initState();
    _controller.addListener(_sync);
    // First layout may land before any notification arrives; without this a
    // rail that never gets scrolled could sit with no trailing fade, which
    // is the one state this widget exists to prevent.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sync();
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_sync);
    _controller.dispose();
    _edges.dispose();
    super.dispose();
  }

  void _sync() {
    if (!_controller.hasClients) {
      _edges.value = (0, 0);
      return;
    }
    final p = _controller.position;
    if (!p.hasContentDimensions || !p.hasViewportDimension) {
      _edges.value = (0, 0);
      return;
    }
    _edges.value = fadingEdgeFractions(
      pixels: p.pixels,
      minExtent: p.minScrollExtent,
      maxExtent: p.maxScrollExtent,
      viewport: p.viewportDimension,
      fadeWidth: widget.fadeWidth,
    );
  }

  /// Opaque through the middle, transparent at whichever ends are fading.
  /// Both lists stay the same length and the stops stay non-decreasing for
  /// every combination, since [f] is capped below 0.5.
  static List<Color> _colors(double lead, double trail) => [
        if (lead > 0) Colors.transparent,
        Colors.black,
        Colors.black,
        if (trail > 0) Colors.transparent,
      ];

  static List<double> _stops(double lead, double trail) => [
        0,
        if (lead > 0) lead,
        if (trail > 0) 1 - trail,
        1,
      ];

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    return NotificationListener<ScrollMetricsNotification>(
      // Fires when the extent changes WITHOUT a scroll — first layout, a
      // window resize, a text-scale bump, a rail whose items arrive late.
      // Listening to the controller alone would leave the trailing fade
      // missing until the first drag, which is exactly the moment it has
      // stopped being useful.
      onNotification: (_) {
        _sync();
        return false;
      },
      child: ValueListenableBuilder<(double, double)>(
        valueListenable: _edges,
        // The scroll view is built ONCE and passed through as `child`, so a
        // fade change repaints the mask without rebuilding the rail.
        child: widget.builder(context, _controller),
        builder: (context, edges, child) {
          final (lead, trail) = edges;
          return ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) => LinearGradient(
              begin: AlignmentDirectional.centerStart,
              end: AlignmentDirectional.centerEnd,
              colors: _colors(lead, trail),
              stops: _stops(lead, trail),
            ).createShader(rect, textDirection: direction),
            child: child,
          );
        },
      ),
    );
  }
}
