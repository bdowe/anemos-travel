import 'package:flutter/material.dart';
import '../models/local_recommendation.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import 'add_to_trip_sheet.dart';

/// A single locally-sourced recommendation: the place, the local's pull-quote,
/// their actionable tip, and attribution (face + name + credibility). This is the
/// "legit info you can't google" surface, so the human behind it is front and
/// center. Styled to sit beside itinerary and event rows.
class LocalRecCard extends StatelessWidget {
  final LocalRecommendation rec;

  /// When set, the card shows an "Add to trip" action (signed-in users only —
  /// pass null for anonymous sessions).
  final VoidCallback? onAddToTrip;

  const LocalRecCard({super.key, required this.rec, this.onAddToTrip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = AppColors.toolLocal;
    final subtitle = [
      if (rec.neighborhood.isNotEmpty) rec.neighborhood,
      if (rec.category.isNotEmpty) rec.category,
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Place name + type badge.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(Icons.verified, size: 20, color: accent),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        rec.name,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            // The local's verbatim pull-quote.
            if (rec.quote.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.only(left: AppSpacing.md),
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: accent, width: 3),
                  ),
                ),
                child: Text(
                  '“${rec.quote}”',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ],
            // The actionable tip.
            if (rec.tip.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lightbulb_outline, size: 16, color: accent),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: Text(
                      rec.tip,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ],
            // Attribution: the human behind the recommendation.
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: accent.withValues(alpha: 0.15),
                  // Bound the decode to the 28px avatar slot (DPR-scaled) —
                  // the source photo is full-size and would otherwise decode
                  // at native resolution for a 28px circle.
                  foregroundImage: rec.sourcePhotoUrl.isNotEmpty
                      ? ResizeImage(
                          NetworkImage(rec.sourcePhotoUrl),
                          width: (28 * MediaQuery.devicePixelRatioOf(context))
                              .round(),
                        )
                      : null,
                  child: Text(
                    rec.sourceName.isNotEmpty
                        ? rec.sourceName.characters.first.toUpperCase()
                        : '?',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: accent, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    rec.creditLine,
                    style: theme.textTheme.labelMedium?.copyWith(
                        color: accent, fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (onAddToTrip != null)
                  AddToTripButton(onPressed: onAddToTrip!, color: accent),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
