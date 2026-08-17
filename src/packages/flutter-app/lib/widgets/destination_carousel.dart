import 'dart:async';
import 'dart:math' show min;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';

import '../theme/spacing.dart';
import 'destination_suggestion_card.dart';
import 'random_suggestions.dart' show ResolvedSuggestion;

/// How wide one card is allowed to get. Past this the photo stops reading as
/// an invitation and starts reading as a banner, and the two-line prompt
/// stranded under it looks lost.
const double kSuggestionCardMaxWidth = 360;

/// How long a destination stays on screen before the carousel moves on.
const Duration _kDwell = Duration(seconds: 5);

/// One slide.
const Duration _kSlide = Duration(milliseconds: 450);

/// The shuffled destination pool as a one-card-per-page carousel that advances
/// itself.
///
/// This replaces the wrapped two-across grid the empty state shipped with.
/// That grid's rationale — "a horizontal rail would hide picks behind a scroll
/// the empty state gives no reason to try" — is true of a rail that sits
/// still, and stops being true of one that moves: the traveler is shown the
/// whole pool without being asked to go looking for it. It is also SHORTER
/// than the grid it replaces (~220px against ~288px at phone width), so the
/// composer moves up rather than off the screen.
///
/// Auto-advance is suppressed in three cases, each for its own reason:
///
///  * **A hidden tab.** `AppShell` keeps every tab mounted in an `IndexedStack`
///    and freezes hidden ones with `TickerMode` — but `TickerMode` stops
///    *tickers*, and this is a `Timer`. Without the explicit
///    `TickerMode.of(context)` gate below (the app's first) the Plan tab would
///    keep sliding while the traveler is on Trips.
///  * **Reduced motion / a screen reader.** Content that moves on its own is
///    hostile to both; the carousel stays swipeable either way. This is the
///    app's first reduced-motion handling.
///  * **A drag.** Once the traveler has taken hold of the cards, they keep
///    them for the rest of this mount — a carousel must never yank a card out
///    from under a thumb. A fresh chat remounts the empty state and restarts
///    it, which is the same lifetime that re-shuffles the pool.
///
/// The advance is deliberately a `Timer` rather than a repeating
/// `AnimationController`: a controller that never stops schedules frames
/// forever, which would hang `pumpAndSettle` in every test that pumps the
/// Plan tab. A `Timer` schedules no frames, and cancelling it in [dispose]
/// satisfies the pending-timer check.
class DestinationSuggestionCarousel extends StatefulWidget {
  final List<ResolvedSuggestion> prompts;
  final void Function(String prompt) onSelect;

  const DestinationSuggestionCarousel({
    super.key,
    required this.prompts,
    required this.onSelect,
  });

  @override
  State<DestinationSuggestionCarousel> createState() =>
      _DestinationSuggestionCarouselState();
}

class _DestinationSuggestionCarouselState
    extends State<DestinationSuggestionCarousel> {
  /// Pages run in both directions without end and the builder takes the index
  /// modulo the pool, so wrapping past the last destination is one forward
  /// slide instead of an eleven-page sweep backwards. Starting a whole number
  /// of laps in means the first page shown is still shuffle position 0.
  static const int _laps = 1000;

  late final PageController _controller;
  late int _page;
  Timer? _timer;

  /// Set once the traveler drags; never cleared for this mount.
  bool _tookOver = false;

  int get _count => widget.prompts.length;

  @override
  void initState() {
    super.initState();
    _page = _count * _laps;
    _controller = PageController(initialPage: _page);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // TickerMode.of and the MediaQuery reads register dependencies, so tabbing
    // away or turning on reduced motion re-runs this and stops the timer.
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _syncTimer() {
    final wanted = !_tookOver &&
        _count > 1 &&
        TickerMode.of(context) &&
        !MediaQuery.disableAnimationsOf(context) &&
        !MediaQuery.accessibleNavigationOf(context);
    if (wanted == (_timer != null)) return;
    _timer?.cancel();
    _timer = wanted ? Timer.periodic(_kDwell, (_) => _advance()) : null;
  }

  void _advance() {
    if (!mounted || !_controller.hasClients) return;
    _controller.nextPage(duration: _kSlide, curve: Curves.easeInOut);
  }

  bool _onScrollStart(ScrollStartNotification notification) {
    // A programmatic slide reports no drag details; only a real gesture does.
    if (notification.dragDetails != null && !_tookOver) {
      _tookOver = true;
      _syncTimer();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = min(constraints.maxWidth, kSuggestionCardMaxWidth);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: width,
              height: DestinationSuggestionCard.heightFor(width),
              child: NotificationListener<ScrollStartNotification>(
                onNotification: _onScrollStart,
                // Without this a mouse cannot drag the pages on web/desktop,
                // the same reason the chat's photo strips set it.
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(
                    dragDevices: PointerDeviceKind.values.toSet(),
                  ),
                  child: PageView.builder(
                    controller: _controller,
                    onPageChanged: (page) => setState(() => _page = page),
                    itemBuilder: (context, index) {
                      final p = widget.prompts[index % _count];
                      return DestinationSuggestionCard(
                        prompt: p.text,
                        asset: p.asset,
                        credit: p.credit,
                        width: width,
                        onTap: () => widget.onSelect(p.text),
                      );
                    },
                  ),
                ),
              ),
            ),
            if (_count > 1) ...[
              const SizedBox(height: AppSpacing.sm),
              _Dots(count: _count, active: _page % _count),
            ],
          ],
        );
      },
    );
  }
}

/// Position indicator only — the card itself is the labelled button, so these
/// are excluded from semantics rather than announced as twelve more targets.
class _Dots extends StatelessWidget {
  final int count;
  final int active;

  const _Dots({required this.count, required this.active});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            AnimatedContainer(
              duration: _kSlide,
              curve: Curves.easeInOut,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == active ? 16 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: i == active
                    ? scheme.primary
                    : scheme.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
        ],
      ),
    );
  }
}
