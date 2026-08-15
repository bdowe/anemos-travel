import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import '../l10n/l10n.dart';
import '../models/local_guide.dart';
import '../models/local_recommendation.dart';
import '../providers/auth_provider.dart';
import '../providers/local_provider.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../widgets/add_to_trip_sheet.dart';
import '../widgets/page_container.dart';
import '../widgets/app_map.dart';
import '../widgets/empty_state.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/local_rec_card.dart';

/// One narrative local guide: hero image, the local's byline, the story itself,
/// then the guide's pins in narrative order (as [LocalRecCard]s) and a small map
/// of every pin that has coordinates. Reached from the "Local intel" section of
/// a trip; [guide] is the list row, which carries the source attribution the
/// detail endpoint's guide object omits.
class LocalGuideDetailScreen extends ConsumerWidget {
  final LocalGuide guide;

  const LocalGuideDetailScreen({super.key, required this.guide});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final detail = ref.watch(localGuideDetailProvider(guide.id));

    return Scaffold(
      appBar: GradientAppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.menu_book, size: 20),
            const SizedBox(width: AppSpacing.sm),
            Flexible(
              child: Text(
                l10n.guideDetailTitle,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => EmptyState(
          icon: Icons.menu_book,
          title: l10n.guideDetailErrorTitle,
          message: l10n.guideDetailErrorMessage,
          actions: [
            FilledButton.icon(
              onPressed: () =>
                  ref.invalidate(localGuideDetailProvider(guide.id)),
              icon: const Icon(Icons.refresh),
              label: Text(l10n.commonRetry),
            ),
          ],
        ),
        data: (data) => _GuideBody(
          // The detail row is canonical for the narrative; the list row fills
          // in the attribution fields the detail join omits.
          guide: data.guide,
          fallback: guide,
          pins: data.recommendations,
          theme: theme,
          onRefresh: () async =>
              ref.invalidate(localGuideDetailProvider(guide.id)),
          // Add-to-trip needs an account (guides browse stays public).
          onAddPin: ref.watch(authProvider).isSignedIn
              ? (pin) => showAddToTripSheet(
                  context,
                  AddToTripPayload.fromLocalRec(pin, source: 'guide_pin'),
                )
              : null,
        ),
      ),
    );
  }
}

class _GuideBody extends StatelessWidget {
  final LocalGuide guide;
  final LocalGuide fallback;
  final List<LocalRecommendation> pins;
  final ThemeData theme;
  final Future<void> Function() onRefresh;
  final void Function(LocalRecommendation pin)? onAddPin;

  const _GuideBody({
    required this.guide,
    required this.fallback,
    required this.pins,
    required this.theme,
    required this.onRefresh,
    this.onAddPin,
  });

  String _pick(String primary, String secondary) =>
      primary.isNotEmpty ? primary : secondary;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final accent = AppColors.toolLocal;
    final title = _pick(guide.title, fallback.title);
    final body = _pick(guide.body, fallback.body);
    final heroUrl = _pick(guide.heroImageUrl, fallback.heroImageUrl);
    final sourceName = _pick(guide.sourceName, fallback.sourceName);
    final sourcePhotoUrl = _pick(guide.sourcePhotoUrl, fallback.sourcePhotoUrl);
    final placeLine = [
      _pick(guide.neighborhood, fallback.neighborhood),
      _pick(guide.city, fallback.city),
    ].where((s) => s.isNotEmpty).join(' · ');
    final mapped = pins
        .where((p) => p.latitude != null && p.longitude != null)
        .toList();

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        // Always scrollable so pull-to-refresh works on short guides.
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          // Centered 700px reading column on wide layouts (declutter series);
          // the ListView stays full-width so wheel/scrollbar work in gutters.
          PageContainer(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (heroUrl.isNotEmpty) ...[
                  _HeroImage(url: heroUrl),
                  const SizedBox(height: AppSpacing.lg),
                ],
                Text(
                  title,
                  style: theme.textTheme.headlineSmall,
                ),
                if (placeLine.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    placeLine,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                // The local behind the guide — same face + name treatment as the
                // recommendation cards, so attribution reads consistently.
                if (sourceName.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: accent.withValues(alpha: 0.15),
                        // Bound the decode to the 32px avatar slot
                        // (DPR-scaled) — the source photo is full-size.
                        foregroundImage: sourcePhotoUrl.isNotEmpty
                            ? ResizeImage(
                                NetworkImage(sourcePhotoUrl),
                                width: (32 *
                                        MediaQuery.devicePixelRatioOf(
                                            context))
                                    .round(),
                              )
                            : null,
                        child: Text(
                          sourceName.characters.first.toUpperCase(),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          l10n.guideDetailByline(sourceName),
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: accent,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Icon(Icons.verified, size: 18, color: accent),
                    ],
                  ),
                ],
                if (body.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    body,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                  ),
                ],
                if (pins.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xl),
                  // Accent mini-header, matching trip detail's "Local intel"
                  // and SourceLinksCard so the local-accent headers read as one
                  // family (labelLarge / w600 / accent).
                  Row(
                    children: [
                      Icon(Icons.place, size: 16, color: accent),
                      const SizedBox(width: 6),
                      Text(
                        l10n.guideDetailPlacesTitle,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: accent,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        '${pins.length}',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  if (mapped.isNotEmpty) ...[
                    _GuideMap(pins: mapped),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  for (final pin in pins)
                    LocalRecCard(
                      rec: pin,
                      onAddToTrip: onAddPin == null
                          ? null
                          : () => onAddPin!(pin),
                    ),
                ] else ...[
                  const SizedBox(height: AppSpacing.xl),
                  EmptyState(
                    icon: Icons.place,
                    title: l10n.guideDetailNoPinsTitle,
                    message: l10n.guideDetailNoPinsMessage,
                    iconColor: accent.withValues(alpha: 0.5),
                  ),
                ],
                const SizedBox(height: AppSpacing.xl),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The guide's hero photo, rounded like a card; falls back to a branded
/// placeholder block if the image fails to load.
class _HeroImage extends StatelessWidget {
  final String url;

  const _HeroImage({required this.url});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: AppRadius.mdAll,
      child: SizedBox(
        height: 200,
        width: double.infinity,
        // LayoutBuilder gives the actual slot width (full-width inside the
        // 700px-capped PageContainer) so the decode is bounded to what is
        // painted (DPR-scaled) rather than the photo's native resolution.
        child: LayoutBuilder(
          builder: (context, constraints) => Image.network(
            url,
            fit: BoxFit.cover,
            cacheWidth: constraints.maxWidth.isFinite
                ? (constraints.maxWidth *
                        MediaQuery.devicePixelRatioOf(context))
                    .round()
                : null,
            errorBuilder: (context, _, __) => Container(
              decoration: BoxDecoration(gradient: AppColors.brandGradient),
              alignment: Alignment.center,
              child: const Icon(
                Icons.photo_outlined,
                size: 40,
                color: Colors.white70,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A small satellite map of the guide's mapped pins, numbered in narrative
/// order. TripMap is keyed to ItineraryItem (positions, categories, route
/// line), so this stays a purpose-built lightweight map on the same shared
/// basemap, with the same scroll-wheel opt-out (the map lives in a ListView).
class _GuideMap extends StatefulWidget {
  final List<LocalRecommendation> pins;

  const _GuideMap({required this.pins});

  @override
  State<_GuideMap> createState() => _GuideMapState();
}

class _GuideMapState extends State<_GuideMap> {
  final MapController _controller = MapController();

  /// Width from the previous layout, to catch resizes (see the
  /// LayoutBuilder in [build]).
  double? _lastMapWidth;

  void _zoomBy(double delta) {
    try {
      _controller.move(
        _controller.camera.center,
        _controller.camera.zoom + delta,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final points = [
      for (final p in widget.pins) LatLng(p.latitude!, p.longitude!),
    ];

    const interaction = InteractionOptions(
      flags: InteractiveFlag.all & ~InteractiveFlag.scrollWheelZoom,
    );

    return ClipRRect(
      borderRadius: AppRadius.lgAll,
      child: SizedBox(
        height: 240,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Zoom floor so the zoom-out button can't shrink the single world
            // narrower than the map box (background bars); see appMapMinZoomFor.
            final minZoom = appMapMinZoomFor(constraints.maxWidth);

            // flutter_map adopts a changed minZoom but never re-clamps the live
            // zoom, so after a resize nudge the camera back over the floor
            // (moveRaw re-applies the camera constraint too; no-op otherwise).
            if (_lastMapWidth != null &&
                _lastMapWidth != constraints.maxWidth) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                try {
                  final camera = _controller.camera;
                  _controller.move(
                    camera.center,
                    math.max(camera.zoom, minZoom),
                  );
                } catch (_) {}
              });
            }
            _lastMapWidth = constraints.maxWidth;

            final options = points.length == 1
                ? appMapOptions(
                    initialCenter: points.first,
                    initialZoom: 13,
                    minZoom: minZoom,
                    interactionOptions: interaction,
                  )
                : appMapOptions(
                    initialCameraFit: AppCameraFitBounds(
                      bounds: LatLngBounds.fromPoints(points),
                      padding: const EdgeInsets.all(32),
                    ),
                    minZoom: minZoom,
                    interactionOptions: interaction,
                  );

            return Stack(
              children: [
                FlutterMap(
                  mapController: _controller,
                  options: options,
                  children: [
                    ...appMapTileLayers(context),
                    MarkerLayer(
                      markers: [
                        for (var i = 0; i < points.length; i++)
                          Marker(
                            point: points[i],
                            width: 24,
                            height: 24,
                            child: _GuidePin(label: '${i + 1}'),
                          ),
                      ],
                    ),
                    appMapAttribution(),
                  ],
                ),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MapControlButton(
                        icon: Icons.add,
                        tooltip: context.l10n.mapZoomIn,
                        onTap: () => _zoomBy(1),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      MapControlButton(
                        icon: Icons.remove,
                        tooltip: context.l10n.mapZoomOut,
                        onTap: () => _zoomBy(-1),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A numbered, local-accent map pin matching the trip map's pin look.
class _GuidePin extends StatelessWidget {
  final String label;

  const _GuidePin({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.toolLocal,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
