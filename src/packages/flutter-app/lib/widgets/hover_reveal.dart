import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Exposes whether a row's secondary controls should show: true while the
/// pointer hovers the row, and ALWAYS true when no mouse is connected, so
/// touch devices keep their controls permanently visible and lose nothing.
///
/// Consumers must hide controls with plain `Opacity` + `IgnorePointer`
/// (never `Visibility`, never `AnimatedOpacity`): opacity preserves layout,
/// so trailing widths don't jump on hover, drag handles keep stable geometry
/// for reorderable lists, and widget-test finders still see the icons. The
/// INSTANT 0/1 swap is a hard perf requirement, not polish: a mid-fade
/// fractional opacity forces a saveLayer per row per frame on CanvasKit, and
/// with a fade every row crossing under a parked cursor during a scroll
/// starts one — the overlapping fades were the trip-detail progressive
/// scroll-slowdown bug.
class HoverReveal extends StatefulWidget {
  final Widget Function(BuildContext context, bool revealed) builder;

  const HoverReveal({super.key, required this.builder});

  @override
  State<HoverReveal> createState() => _HoverRevealState();
}

class _HoverRevealState extends State<HoverReveal> {
  bool _hovered = false;

  // Same signal Scrollbar uses to decide desktop-ness: MouseTracker is a
  // ChangeNotifier whose mouseIsConnected flips when a mouse (dis)appears.
  MouseTracker get _tracker => RendererBinding.instance.mouseTracker;

  @override
  void initState() {
    super.initState();
    _tracker.addListener(_onMouseTrackerChanged);
  }

  @override
  void dispose() {
    _tracker.removeListener(_onMouseTrackerChanged);
    super.dispose();
  }

  void _onMouseTrackerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final revealed = _hovered || !_tracker.mouseIsConnected;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: widget.builder(context, revealed),
    );
  }
}

/// The standard wrapper for a hover-revealed control: instantly invisible and
/// pointer-ignoring while hidden, but keeps its layout slot (see
/// [HoverReveal] for why layout must be preserved and why the swap must be
/// an instant 0/1 — never an animated fade).
class HoverRevealed extends StatelessWidget {
  final bool revealed;
  final Widget child;

  const HoverRevealed({super.key, required this.revealed, required this.child});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !revealed,
      child: Opacity(
        opacity: revealed ? 1 : 0,
        child: child,
      ),
    );
  }
}
