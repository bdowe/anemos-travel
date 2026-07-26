import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/spacing.dart';

/// Coarse relative-time label for cache staleness: "just now",
/// "5 minutes ago", "2 hours ago", "3 days ago". [now] is injectable for
/// tests; precision is deliberately low — travelers need "how stale", not a
/// timestamp. Takes [l10n] because it is a plain function (no BuildContext of
/// its own) shared by several screens (specs/i18n-spanish).
String relativeTime(AppLocalizations l10n, DateTime savedAt, {DateTime? now}) {
  final d = (now ?? DateTime.now()).difference(savedAt);
  if (d.inMinutes < 1) return l10n.offlineJustNow;
  if (d.inHours < 1) return l10n.offlineMinutesAgo(d.inMinutes);
  if (d.inDays < 1) return l10n.offlineHoursAgo(d.inHours);
  return l10n.offlineDaysAgo(d.inDays);
}

/// Pinned notice shown while a screen serves a cached (read-only) copy of
/// trip data because the network is unreachable. Says when the copy was
/// saved and offers a retry of the live fetch.
class OfflineBanner extends StatelessWidget {
  final DateTime savedAt;
  final VoidCallback onRetry;

  const OfflineBanner(
      {super.key, required this.savedAt, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = context.l10n;
    return Material(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.sm, AppSpacing.sm, AppSpacing.sm),
        child: Row(
          children: [
            Icon(Icons.cloud_off, size: 18, color: scheme.onTertiaryContainer),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                l10n.offlineBannerMessage(relativeTime(l10n, savedAt)),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onTertiaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // No compact density: this is the recovery affordance on a flaky
            // connection, so it keeps the default >=48px tap target.
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: scheme.onTertiaryContainer,
              ),
              child: Text(l10n.commonRetry),
            ),
          ],
        ),
      ),
    );
  }
}
