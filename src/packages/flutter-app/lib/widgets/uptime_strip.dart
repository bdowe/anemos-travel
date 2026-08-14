import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../l10n/l10n.dart';
import '../models/ops_uptime.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../utils/date_formats.dart';

/// One status-page row for the Health pane (specs/uptime-history): a label +
/// pill header, a strip of one bar per day, and a caption trio
/// ("90 days ago — 99.36 % uptime — Today") whose middle swaps to the
/// selected day's detail under tap/scrub or arrow keys.
///
/// A sibling of [DailyCountChart], not an extension of it: that painter is
/// single-hue by written doctrine (bars encode magnitude, color never changes
/// meaning) and is built around a value axis; this one encodes a CATEGORY per
/// day in hue — here color IS the meaning — and has no scale. Only the slot
/// geometry is shared, copied verbatim from daily_count_chart.dart.
///
/// No-reflow rules: the canvas is a fixed [kMinTouchTarget] tall in every
/// state (severity raises the MARK inside it, never the widget), and the
/// caption's middle slot is one ellipsized line — an outage landing on
/// refresh can never move the pane below it.
///
/// [days] must be dense — exactly one entry per day of the window, oldest
/// first — which is what the server sends (the client never synthesizes a
/// day; a `no_data` bucket is the server's own statement of absence).
class UptimeStrip extends StatefulWidget {
  final String label;
  final List<UptimeDay> days;

  /// Window percentage over observed seconds, null when nothing was observed.
  final double? uptimePct;
  final int observedDays;

  /// When monitoring first began — captions an unobserved window honestly.
  final DateTime? monitoringSince;

  /// The status pill rendered after the label (built by the pane, which owns
  /// the status→color convention).
  final Widget? pill;

  const UptimeStrip({
    super.key,
    required this.label,
    required this.days,
    this.uptimePct,
    this.observedDays = 0,
    this.monitoringSince,
    this.pill,
  });

  @override
  State<UptimeStrip> createState() => _UptimeStripState();
}

class _UptimeStripState extends State<UptimeStrip> {
  int? _selected;
  bool _focused = false;
  final FocusNode _focusNode = FocusNode(debugLabel: 'UptimeStrip');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  void _selectIndex(int i) {
    if (i != _selected) setState(() => _selected = i);
  }

  void _select(Offset local, double width) {
    final n = widget.days.length;
    if (n == 0 || width <= 0) return;
    _selectIndex(((local.dx / (width / n)).floor()).clamp(0, n - 1));
  }

  void _step(int delta) {
    final n = widget.days.length;
    if (n == 0) return;
    // Arrows start at Today and walk backwards — the direction the question
    // is asked in ("when did it last break?").
    final base = _selected ?? n;
    _selectIndex((base + delta).clamp(0, n - 1));
  }

  void _clear() {
    if (_selected != null) setState(() => _selected = null);
  }

  /// "99.36" in English, "99,36" in Spanish — decimal separator follows the
  /// app language via Intl.defaultLocale (the money_format.dart pattern).
  static String _pct(double v) =>
      NumberFormat.decimalPatternDigits(decimalDigits: 2).format(v);

  /// Coarse single-unit duration ("2h", "41m", "30s") for the day detail.
  static String _dur(int seconds) {
    if (seconds >= 3600) return '${seconds ~/ 3600}h';
    if (seconds >= 60) return '${seconds ~/ 60}m';
    return '${seconds}s';
  }

  String _reasonLabel(AppLocalizations l10n, String code) => switch (code) {
        'db_unreachable' => l10n.healthUptimeReasonDbUnreachable,
        'process_down' => l10n.healthUptimeReasonProcessDown,
        'ai_failing' => l10n.healthUptimeReasonAiFailing,
        'backups_stale' => l10n.healthUptimeReasonBackupsStale,
        _ => code, // a code the server adds tomorrow renders, never throws
      };

  String _dayDate(UptimeDay d) {
    final parsed = OpsUptime.utcDay(d.day);
    return parsed == null ? d.day : mmmd().format(parsed);
  }

  /// The selected day's caption: "Aug 3 · 97.2 % · database unreachable · 2h".
  String _dayCaption(AppLocalizations l10n, UptimeDay d) {
    final date = _dayDate(d);
    final pct = d.uptimePct;
    if (!d.hasData || pct == null) return l10n.healthUptimeDayNoData(date);
    final parts = [date, l10n.healthUptimeSummary(_pct(pct))];
    if (d.downS > 0) {
      parts.addAll(d.reasonCodes.map((c) => _reasonLabel(l10n, c)));
      parts.add(l10n.healthUptimeDown(_dur(d.downS)));
    } else {
      parts.add(l10n.healthUptimeNoIncidents);
    }
    return parts.join(' · ');
  }

  /// The resting caption: window percentage, partial-coverage note, or the
  /// honest no-history statement — never an invented 0 % or 100 %.
  String _summaryCaption(AppLocalizations l10n) {
    final pct = widget.uptimePct;
    if (pct == null) {
      final since = widget.monitoringSince;
      return since == null
          ? l10n.healthUptimeNoHistory
          : l10n.healthUptimeMonitoringSince(mmmd().format(since.toUtc()));
    }
    if (widget.observedDays < widget.days.length) {
      return l10n.healthUptimeSummaryPartial(
          _pct(pct), widget.observedDays);
    }
    return l10n.healthUptimeSummary(_pct(pct));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final days = widget.days;
    final selected = (_selected != null && _selected! < days.length)
        ? days[_selected!]
        : null;
    final captionStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    final middle = selected != null
        ? Text(
            _dayCaption(l10n, selected),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: captionStyle?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          )
        : Text(
            _summaryCaption(l10n),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: captionStyle,
          );

    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge,
                ),
              ),
              if (widget.pill != null) ...[
                const SizedBox(width: AppSpacing.sm),
                widget.pill!,
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Semantics(
            // One node for the whole strip: the 90 bars are never exposed
            // individually (a 90-node soup reads worse than nothing).
            label: '${widget.label}: ${_summaryCaption(l10n)}',
            value: selected == null ? null : _dayCaption(l10n, selected),
            hint: l10n.healthUptimeKeyboardHint,
            child: CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                    _step(-1),
                const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                    _step(1),
                const SingleActivator(LogicalKeyboardKey.home): () =>
                    _selectIndex(0),
                const SingleActivator(LogicalKeyboardKey.end): () =>
                    _selectIndex(days.length - 1),
                const SingleActivator(LogicalKeyboardKey.escape): _clear,
              },
              child: Focus(
                focusNode: _focusNode,
                onFocusChange: (f) => setState(() => _focused = f),
                child: LayoutBuilder(
                  builder: (context, constraints) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // The BAND is the target, not the bar: land anywhere and
                    // scrub; the caption reads out under the finger, so a
                    // 3px bar never needs to be hit precisely.
                    onTapDown: (d) {
                      _focusNode.requestFocus();
                      _select(d.localPosition, constraints.maxWidth);
                    },
                    onHorizontalDragUpdate: (d) =>
                        _select(d.localPosition, constraints.maxWidth),
                    child: CustomPaint(
                      size: Size(constraints.maxWidth, kMinTouchTarget),
                      painter: _UptimeStripPainter(
                        days: days,
                        selected: _selected,
                        focused: _focused,
                        up: AppColors.upMark(theme.brightness),
                        degraded: AppColors.degradedMark(theme.brightness),
                        down: AppColors.downMark(theme.brightness),
                        noData: theme.colorScheme.outlineVariant,
                        focusRing: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              if (days.isNotEmpty)
                Text(l10n.healthUptimeDaysAgo(days.length), style: captionStyle),
              const Spacer(),
              Flexible(flex: 3, child: middle),
              const Spacer(),
              if (days.length > 1)
                Text(l10n.healthUptimeToday, style: captionStyle),
            ],
          ),
        ],
      ),
    );
  }
}

class _UptimeStripPainter extends CustomPainter {
  final List<UptimeDay> days;
  final int? selected;
  final bool focused;
  final Color up;
  final Color degraded;
  final Color down;
  final Color noData;
  final Color focusRing;

  _UptimeStripPainter({
    required this.days,
    required this.selected,
    required this.focused,
    required this.up,
    required this.degraded,
    required this.down,
    required this.noData,
    required this.focusRing,
  });

  // Mark heights inside the fixed kMinTouchTarget-tall canvas. Severity
  // RAISES the mark, so an outage survives grayscale and red/green color
  // blindness — and the room is reserved up front, so a bad day landing on
  // refresh never reflows the pane. no_data sits at the up height: absence
  // must read as quiet, not as a severity.
  static const _hUp = 24.0;
  static const _hDegraded = 28.0;
  static const _hDown = 32.0;
  static const _maxBar = 12.0;

  @override
  void paint(Canvas canvas, Size size) {
    final n = days.length;
    if (n == 0 || size.width <= 0) return;

    // Slot geometry, same rule as DailyCountChart: 2px gaps until slots are
    // too narrow to afford them, then 1px, then none. 90 days across a 668px
    // desktop pane is a 7.4px slot → 5.4px bars; a 360px phone (328px of
    // content) is 3.6px → 2.6px. Bars cap at 12 (not the chart's 24): a
    // status strip with a short window must not become fat blocks.
    final slot = size.width / n;
    final gap = slot >= 4 ? 2.0 : (slot >= 2 ? 1.0 : 0.0);
    final barW = math.min(_maxBar, math.max(1.0, slot - gap));
    final radius = Radius.circular(math.min(2.0, barW / 2));
    final cy = size.height / 2;

    for (var i = 0; i < n; i++) {
      final (color, h) = _mark(days[i].state);
      // Selection DIMS the others; the selected bar keeps its color, because
      // here color IS the meaning (the mirror image of DailyCountChart's
      // never-recolor rule).
      final paint = Paint()
        ..color = (selected != null && selected != i)
            ? color.withValues(alpha: 0.35)
            : color;
      final left = i * slot + (slot - barW) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, cy - h / 2, barW, h),
          radius,
        ),
        paint,
      );
    }

    if (focused) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          const Radius.circular(AppRadius.sm),
        ).deflate(1),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = focusRing,
      );
    }
  }

  (Color, double) _mark(String state) => switch (state) {
        'up' => (up, _hUp),
        'degraded' => (degraded, _hDegraded),
        'down' => (down, _hDown),
        _ => (noData, _hUp), // no_data, and anything the server adds later
      };

  @override
  bool shouldRepaint(_UptimeStripPainter old) =>
      old.days != days ||
      old.selected != selected ||
      old.focused != focused ||
      old.up != up ||
      old.degraded != degraded ||
      old.down != down ||
      old.noData != noData;
}
