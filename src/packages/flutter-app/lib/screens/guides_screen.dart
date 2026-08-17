import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../models/local_guide.dart';
import '../navigation/app_nav.dart';
import '../providers/local_provider.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../widgets/empty_state.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/page_container.dart';
import '../widgets/section_header.dart';
import 'local_guide_detail_screen.dart';

/// All published local guides, grouped by city — the "See all" target of the
/// home discover row (guides-discover-row spec follow-up).
class GuidesScreen extends ConsumerWidget {
  const GuidesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final guides = ref.watch(allGuidesProvider);

    return Scaffold(
      appBar: GradientAppBar(title: l10n.guidesTitle),
      body: guides.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => EmptyState(
          icon: Icons.cloud_off,
          title: l10n.guidesErrorTitle,
          message: l10n.guidesErrorMessage,
          actions: [
            FilledButton(
              onPressed: () => ref.invalidate(allGuidesProvider),
              child: Text(l10n.commonRetry),
            ),
          ],
        ),
        data: (all) {
          if (all.isEmpty) {
            return EmptyState(
              icon: Icons.menu_book_outlined,
              title: l10n.guidesEmptyTitle,
              message: l10n.guidesEmptyMessage,
            );
          }
          // Group by city, preserving the server's newest-first order
          // within and across groups.
          final byCity = <String, List<LocalGuide>>{};
          for (final g in all) {
            final city = g.city.isEmpty ? l10n.guidesElsewhere : g.city;
            byCity.putIfAbsent(city, () => []).add(g);
          }
          // One flat entry per visual row (header / guide tile / group
          // spacer) so ListView.builder can inflate rows lazily instead of
          // building every group's children up front.
          final rows = <({String? header, LocalGuide? guide})>[
            for (final entry in byCity.entries) ...[
              (header: entry.key, guide: null),
              for (final g in entry.value) (header: null, guide: g),
              (header: null, guide: null), // spacer after each group
            ],
          ];

          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(allGuidesProvider),
            child: ListView.builder(
              // Always scrollable so pull-to-refresh works on short lists.
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppSpacing.lg),
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final row = rows[i];
                final Widget child;
                if (row.header != null) {
                  child = Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: SectionHeader(title: row.header!),
                  );
                } else if (row.guide != null) {
                  child = _GuideListTile(guide: row.guide!);
                } else {
                  child = const SizedBox(height: AppSpacing.lg);
                }
                // PageContainer inside the scroll view (per its doc comment):
                // each row is capped at 700px while the scrollable region
                // stays full-width, so wheel/scrollbar work in the gutters.
                return PageContainer(child: child);
              },
            ),
          );
        },
      ),
    );
  }
}

class _GuideListTile extends StatelessWidget {
  final LocalGuide guide;
  const _GuideListTile({required this.guide});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppColors.toolLocal.withValues(alpha: 0.15),
          // Bound the decode to the 40px avatar slot (default CircleAvatar
          // radius 20, DPR-scaled) — the source photo is full-size.
          foregroundImage: guide.sourcePhotoUrl.isNotEmpty
              ? ResizeImage(
                  NetworkImage(guide.sourcePhotoUrl),
                  width:
                      (40 * MediaQuery.devicePixelRatioOf(context)).round(),
                )
              : null,
          child: Icon(Icons.menu_book_outlined,
              size: 18, color: AppColors.toolLocal),
        ),
        title: Text(guide.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: guide.sourceName.isEmpty
            ? null
            : Text(
                '${context.l10n.guidesByline(guide.sourceName)}'
                '${guide.neighborhood.isNotEmpty ? ' · ${guide.neighborhood}' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => pushOnce(
          context,
          MaterialPageRoute(
            builder: (_) => LocalGuideDetailScreen(guide: guide),
          ),
        ),
        titleTextStyle: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurface,
        ),
      ),
    );
  }
}
