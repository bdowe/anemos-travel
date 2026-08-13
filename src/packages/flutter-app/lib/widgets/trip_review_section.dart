import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/trip_finding.dart';
import '../providers/trip_review_provider.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import 'collapsible_section.dart';
import 'empty_state.dart';
import 'section_header.dart';
import 'status_pill.dart';

/// The "Trip health" findings list: surfaces the read-only review from
/// `GET /trips/{id}/review` in two tiers via [partition] — "Needs attention"
/// (critical + warn, worst first, always visible) and "Suggestions" (info,
/// collapsed by default so a big trip's unbooked-row pile can't dominate).
/// Self-contained — it owns its data via [tripReviewProvider], keyed on
/// (tripId, checkHours). Rendered as the body of the trip-detail health sheet
/// (`showTripHealthSheet`), which the app-bar health icon opens.
///
/// Tapping a finding with a resolvable day deep-links the itinerary to that day
/// via [onScrollToDay]; [dayForItem] resolves an item id → day when a finding
/// carries only an item id. Both are optional (no-op when absent/unresolvable).
class TripReviewSection extends ConsumerStatefulWidget {
  final String tripId;

  /// Reads the CURRENT offline state at interaction time. A callback rather
  /// than a bool because the sheet route hosting this widget never rebuilds
  /// on the screen's connectivity setState — a captured bool would freeze
  /// the offline guard for the sheet's whole lifetime.
  final bool Function() isOffline;

  /// Scrolls the itinerary to [day]. Wired to the screen's `_scrollToDay`.
  final void Function(int day)? onScrollToDay;

  /// Resolves an itinerary item id to its day, for findings that carry an
  /// item id but no day. Returns null when the item isn't placed on a day.
  final int? Function(String itemId)? dayForItem;

  /// Applies a finding's one-tap fix. The screen owns the sheets, services and
  /// refresh, so it supplies this; when null the fix button is hidden.
  final Future<void> Function(TripFinding finding)? onApplyFix;

  const TripReviewSection({
    super.key,
    required this.tripId,
    required this.isOffline,
    this.onScrollToDay,
    this.dayForItem,
    this.onApplyFix,
  });

  /// One switch per severity keeps the two color pairs in lockstep — the
  /// container pair (finding rows and count pills on light surfaces) and the
  /// solid pair (the app-bar badge over the brand gradient, where translucent
  /// container fills vanish). A severity added here shows up on every surface
  /// at once; there is no second case-list to drift.
  static ({Color bg, Color fg, Color solidBg, Color solidFg}) _severityPalette(
      ThemeData theme, String severity) {
    switch (severity) {
      case 'critical':
        return (
          bg: theme.colorScheme.errorContainer,
          fg: theme.colorScheme.onErrorContainer,
          solidBg: theme.colorScheme.error,
          solidFg: theme.colorScheme.onError,
        );
      case 'warn':
        return (
          bg: AppColors.warningContainer,
          fg: AppColors.onWarningContainer,
          solidBg: AppColors.warningSolid,
          solidFg: AppColors.onWarningSolid,
        );
      default:
        return (
          bg: theme.colorScheme.surfaceContainerHighest,
          fg: theme.colorScheme.onSurfaceVariant,
          solidBg: AppColors.neutralSolid,
          solidFg: AppColors.onNeutralSolid,
        );
    }
  }

  /// Severity → pill colors for rows and count pills on light surfaces.
  /// Critical reads loud (red), warn amber, info neutral.
  static ({Color bg, Color fg}) severityColors(
      ThemeData theme, String severity) {
    final p = _severityPalette(theme, severity);
    return (bg: p.bg, fg: p.fg);
  }

  /// Severity → opaque colors for the app-bar count badge over the brand
  /// gradient.
  static ({Color bg, Color fg}) badgeColors(ThemeData theme, String severity) {
    final p = _severityPalette(theme, severity);
    return (bg: p.solidBg, fg: p.solidFg);
  }

  /// Splits findings into the two presentation tiers: "attention" (critical +
  /// warn, worst-first — the badge number and the always-visible sheet
  /// section) and "suggestions" (info and anything unrecognized, server order
  /// — the collapsed sheet section / neutral dot). The single
  /// severity-partition definition shared by the app-bar badge and the sheet.
  static ({List<TripFinding> attention, List<TripFinding> suggestions})
      partition(Iterable<TripFinding> findings) {
    final attention = <TripFinding>[];
    final suggestions = <TripFinding>[];
    for (final f in findings) {
      (_rankOf(f.severity) <= _severityRank['warn']! ? attention : suggestions)
          .add(f);
    }
    attention
        .sort((a, b) => _rankOf(a.severity).compareTo(_rankOf(b.severity)));
    return (attention: attention, suggestions: suggestions);
  }

  @override
  ConsumerState<TripReviewSection> createState() => _TripReviewSectionState();
}

// Severity display order (worst first) and rank for sorting.
const Map<String, int> _severityRank = {
  'critical': 0,
  'warn': 1,
  'info': 2,
};

/// Severity is a canonical API value — only its display label is translated
/// (specs/i18n-spanish); anything unrecognized falls back to the raw value.
String _severityLabel(AppLocalizations l10n, String severity) =>
    switch (severity) {
      'critical' => l10n.reviewSeverityCritical,
      'warn' => l10n.reviewSeverityWarning,
      'info' => l10n.reviewSeverityInfo,
      _ => severity,
    };

const Map<String, IconData> _categoryIcons = {
  'dates': Icons.event_outlined,
  'unscheduled': Icons.schedule_outlined,
  'packing': Icons.luggage_outlined,
  'lodging': Icons.hotel_outlined,
  'transit': Icons.directions_transit_outlined,
  'budget': Icons.account_balance_wallet_outlined,
  'bookings': Icons.confirmation_number_outlined,
};

int _rankOf(String severity) => _severityRank[severity] ?? 3;

class _TripReviewSectionState extends ConsumerState<TripReviewSection> {
  // Opt-in opening-hours check: flips the provider key to the slower variant.
  bool _checkHours = false;

  // Suggestions (info findings) start collapsed — the calm default. Ephemeral
  // per sheet open (showTripHealthSheet builds a fresh widget), but survives
  // provider refetches after a fix so the section stays open while its rows
  // decrement.
  bool _suggestionsExpanded = false;

  // A failed hours check reverted [_checkHours]; shown as an inline caption
  // by the toggle (a snackbar would render behind the sheet). Cleared on the
  // next toggle attempt.
  bool _hoursCheckFailed = false;

  TripReviewKey get _key =>
      TripReviewKey(widget.tripId, checkHours: _checkHours);

  ({Color bg, Color fg}) _severityColors(ThemeData theme, String severity) =>
      TripReviewSection.severityColors(theme, severity);

  void _onTapFinding(TripFinding finding) {
    final onScrollToDay = widget.onScrollToDay;
    if (onScrollToDay == null) return;
    int? day = finding.day;
    if (day == null && finding.itemId != null) {
      day = widget.dayForItem?.call(finding.itemId!);
    }
    if (day != null) onScrollToDay(day);
  }

  void _toggleCheckHours() {
    if (widget.isOffline()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.reviewOfflineSnack)),
      );
      return;
    }
    setState(() {
      _checkHours = !_checkHours;
      _hoursCheckFailed = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(tripReviewProvider(_key));
    final theme = Theme.of(context);
    final l10n = context.l10n;
    // A failed hours check would otherwise strand the widget on a valueless
    // provider key — inside the sheet that reads as a blank modal with no way
    // back. Revert to the base key (whose value is cached) and flag inline.
    ref.listen(tripReviewProvider(_key), (_, next) {
      if (next.hasError && !next.isLoading && _checkHours) {
        // Invalidate the failed variant so a retry refetches instead of
        // replaying the cached error (the family is not autoDispose).
        ref.invalidate(tripReviewProvider(_key));
        setState(() {
          _checkHours = false;
          _hoursCheckFailed = true;
        });
      }
    });
    // Best-effort: on error or first load with no data, render nothing rather
    // than an error state — a utility section shouldn't shout. (Offline still
    // shows the last-loaded findings — the read GET is cached by the family.)
    final findings = async.valueOrNull;
    if (findings == null) {
      // In the sheet this is reachable only via the hours-check key switch
      // (the app-bar icon gates opening on a loaded base list): keep the
      // sheet's shape — header + spinner — while the slower variant fetches,
      // never a bare drag handle.
      if (async.isLoading) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(title: l10n.reviewSectionTitle),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.xl),
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
        );
      }
      return const SizedBox.shrink();
    }

    final (:attention, :suggestions) = TripReviewSection.partition(findings);
    // Header framing follows the attention tier, not the total: warns read
    // "N to fix" in the worst severity's colors; info-only reads as a calm
    // neutral. Success-green stays reserved for the zero-findings EmptyState.
    final headerColors = _severityColors(
        theme, attention.isEmpty ? 'info' : attention.first.severity);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: l10n.reviewSectionTitle,
          action: findings.isEmpty
              ? null
              : StatusPill.custom(
                  label: attention.isEmpty
                      ? l10n.reviewHeaderSuggestionsOnly(suggestions.length)
                      : l10n.reviewHeaderAttention(attention.length),
                  background: headerColors.bg,
                  foreground: headerColors.fg,
                ),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (findings.isEmpty)
          EmptyState(
            compact: true,
            icon: Icons.check_circle_outline,
            iconColor: Colors.green,
            title: l10n.reviewEmptyTitle,
            message: l10n.reviewEmptyMessage,
          )
        else ...[
          if (attention.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Text(
                l10n.reviewNeedsAttentionHeader,
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            for (final f in attention) _buildRow(theme, f),
          ],
          if (suggestions.isNotEmpty)
            CollapsibleSection(
              title: l10n.reviewSuggestionsHeader,
              icon: Icons.lightbulb_outline,
              pill: StatusPill.custom(
                label: '${suggestions.length}',
                background: _severityColors(theme, 'info').bg,
                foreground: _severityColors(theme, 'info').fg,
              ),
              expanded: _suggestionsExpanded,
              onToggle: () => setState(
                  () => _suggestionsExpanded = !_suggestionsExpanded),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final f in suggestions) _buildRow(theme, f)],
              ),
            ),
        ],
        const SizedBox(height: AppSpacing.sm),
        _buildCheckHoursAction(theme, async.isLoading),
      ],
    );
  }

  Widget _buildRow(ThemeData theme, TripFinding finding) {
    final colors = _severityColors(theme, finding.severity);
    final icon = _categoryIcons[finding.category] ?? Icons.info_outline;
    // A finding is tappable when we can resolve it to a day to scroll to.
    final tappable = widget.onScrollToDay != null &&
        (finding.day != null ||
            (finding.itemId != null &&
                widget.dayForItem?.call(finding.itemId!) != null));
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatusPill.custom(
            label: _severityLabel(context.l10n, finding.severity),
            background: colors.bg,
            foreground: colors.fg,
          ),
          const SizedBox(width: AppSpacing.sm),
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              finding.message,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurface),
            ),
          ),
          // A fix, when present, takes the trailing slot from the chevron: its
          // own button so its tap never reaches the row's scroll InkWell.
          if (finding.fix != null && widget.onApplyFix != null)
            _buildFixButton(finding)
          else if (tappable)
            Icon(Icons.chevron_right,
                size: 18, color: theme.colorScheme.onSurfaceVariant),
        ],
      ),
    );
    if (!tappable) return row;
    return InkWell(
      key: ValueKey('finding-${finding.category}-${finding.message}'),
      onTap: () => _onTapFinding(finding),
      borderRadius: AppRadius.smAll,
      child: row,
    );
  }

  // Compact trailing "fix" affordance. Sits inside the row's InkWell when the
  // finding is also tap-to-scroll; because it's a button it wins the gesture
  // arena, so applying a fix never scrolls the itinerary.
  Widget _buildFixButton(TripFinding finding) {
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.xs),
      child: FilledButton.tonal(
        key: ValueKey('fix-${finding.fix!.action}-${finding.message}'),
        onPressed: () => widget.onApplyFix!(finding),
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: 0),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(finding.fix!.label),
      ),
    );
  }

  Widget _buildCheckHoursAction(ThemeData theme, bool loading) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AppSpacing.sm,
        children: [
          TextButton.icon(
            icon: loading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(_checkHours ? Icons.check : Icons.access_time),
            label: Text(_checkHours
                ? context.l10n.reviewHoursChecked
                : context.l10n.reviewCheckHours),
            onPressed:
                (widget.isOffline() || _checkHours) ? null : _toggleCheckHours,
          ),
          if (_hoursCheckFailed)
            Text(
              context.l10n.reviewHoursCheckFailed,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
        ],
      ),
    );
  }
}
