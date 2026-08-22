import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';
import '../models/agent_place.dart';
import '../models/event.dart';
import '../models/local_recommendation.dart';
import '../theme/app_colors.dart';
import '../models/hotel_stay.dart';
import '../theme/spacing.dart';
import 'add_to_trip_sheet.dart' show AddToTripButton;
import 'event_card.dart' show eventWhenLabel;

/// Fixed card/strip geometry: every dimension is pre-reserved so a photo
/// arriving can only repaint inside its box, never relayout the chat tail
/// (the de-jank invariant that killed the old inline cards).
const double kPlaceCardWidth = 200;
const double kPlaceCardHeight = 160;
const double kPlaceCardImageHeight = 96;

/// One recommendation rendered as a photo card in the chat strip — the
/// view-model the three sources (Google place, local pick, event) flatten
/// into. Pure data: the caller pre-builds [photoUrl] (it needs the API base)
/// and pre-localizes nothing (all fields are live data, not copy).
class PlaceCardData {
  final String title;
  final String? photoUrl;
  final String? attribution; // photographer credit, Google TOS
  final String metaLine; // category / neighborhood·category / when-label
  final double? rating; // places only → star row
  final int? priceLevel; // places only → $-signs

  /// A formatted rate ("$154/night") for the trailing half of the meta row —
  /// the slot [priceLevel]'s `$`-signs occupy on place cards. Hotels set this
  /// and leave [priceLevel] null; the two are mutually exclusive and this one
  /// wins. It is deliberately a pre-formatted STRING, not a number+currency
  /// pair: the server already decided the one currency a result set is priced
  /// in (there is no FX in this app), so the card must not be able to render
  /// a figure in a currency the rest of the result never mentioned.
  ///
  /// Null on discovery-tier hotels — the rail header, not the card, is what
  /// says prices weren't checked, because a 200x160 card with a rating has no
  /// room for a caveat and the tier is a property of the whole result set.
  final String? priceLabel;
  final IconData fallbackIcon;
  final Color accent;
  final bool localBadge; // rec-sourced cards get the verified badge
  final String? localCredit; // badge tooltip ("Eleni · Athens chef")
  final bool externalLink; // events: open-ticket glyph
  final bool metaIsAccent; // events: when-label rendered in accent

  const PlaceCardData({
    required this.title,
    this.photoUrl,
    this.attribution,
    this.metaLine = '',
    this.rating,
    this.priceLevel,
    this.priceLabel,
    required this.fallbackIcon,
    required this.accent,
    this.localBadge = false,
    this.localCredit,
    this.externalLink = false,
    this.metaIsAccent = false,
  });

  factory PlaceCardData.place(
    AgentPlace place, {
    required String? photoUrl,
    required ColorScheme scheme,
  }) {
    return PlaceCardData(
      title: place.name,
      photoUrl: photoUrl,
      attribution: place.photoAttribution,
      // The wire category is a machine slug ('coffee_shop',
      // 'point_of_interest'); shown only when there's no rating row, so at
      // least strip the underscores.
      metaLine: place.category.replaceAll('_', ' '),
      rating: place.rating,
      priceLevel: place.priceLevel,
      fallbackIcon: _categoryIcon(place.category),
      accent: AppColors.forCategory(place.category, scheme),
    );
  }

  factory PlaceCardData.localRec(
    LocalRecommendation rec, {
    required String? photoUrl,
    required Brightness brightness,
  }) {
    return PlaceCardData(
      title: rec.name,
      photoUrl: photoUrl,
      attribution: rec.photoAttribution,
      metaLine: [
        if (rec.neighborhood.isNotEmpty) rec.neighborhood,
        if (rec.category.isNotEmpty) rec.category,
      ].join(' · '),
      fallbackIcon: Icons.verified,
      accent: AppColors.toolLocal(brightness),
      localBadge: true,
      localCredit: rec.creditLine,
    );
  }

  /// Parking spots near a beach (SSE `parking`). [freeLabel] is the localized
  /// "Free (listed)" marker, shown as the accent meta line when the listing
  /// name suggests free parking — it must never claim more than "listed".
  /// Icon and accent are hardcoded: the wire category is always "parking",
  /// which the shared category mappers don't know.
  factory PlaceCardData.parking(
    AgentPlace place, {
    required String? photoUrl,
    required String freeLabel,
    required Brightness brightness,
  }) {
    return PlaceCardData(
      title: place.name,
      photoUrl: photoUrl,
      attribution: place.photoAttribution,
      metaLine: place.freeListed
          ? freeLabel
          : place.category.replaceAll('_', ' '),
      // The rating row would hide the free marker; keep it only on unflagged
      // cards.
      rating: place.freeListed ? null : place.rating,
      priceLevel: place.freeListed ? null : place.priceLevel,
      fallbackIcon: Icons.local_parking,
      accent: AppColors.toolParking(brightness),
      metaIsAccent: place.freeListed,
    );
  }

  factory PlaceCardData.event(
    Event event, {
    required Brightness brightness,
  }) {
    return PlaceCardData(
      title: event.name,
      photoUrl: event.imageUrl.isEmpty ? null : event.imageUrl,
      metaLine: eventWhenLabel(event),
      fallbackIcon: Icons.local_activity,
      accent: AppColors.toolEvents(brightness),
      externalLink: event.url.isNotEmpty,
      metaIsAccent: true,
    );
  }

  /// A live lodging result (specs/hotel-search). This IS what PlaceCardData
  /// describes — a search result with a rating, a photo and an accent — so
  /// unlike DestinationSuggestionCard it belongs here rather than in its own
  /// widget. [priceLabel] is null on discovery-tier stays, which carry no
  /// price at all; the rail header says why.
  factory PlaceCardData.hotel(
    HotelStay stay, {
    required String? photoUrl,
    required String? priceLabel,
    required Brightness brightness,
  }) {
    return PlaceCardData(
      title: stay.name,
      photoUrl: photoUrl,
      // Shown only when there is no rating — nearly every stay has one, so
      // this is the rare-case fallback rather than the usual line.
      metaLine: stay.address,
      rating: stay.rating,
      priceLabel: priceLabel,
      fallbackIcon:
          stay.kind == 'vacation_rental' ? Icons.house_outlined : Icons.hotel,
      accent: AppColors.toolStays(brightness),
      externalLink: stay.bookingUrl.isNotEmpty,
    );
  }

  static IconData _categoryIcon(String category) {
    switch (category) {
      case 'restaurant':
        return Icons.restaurant;
      case 'coffee_shop':
        return Icons.local_cafe;
      case 'museum':
        return Icons.museum;
      case 'park':
        return Icons.park;
      case 'shopping':
        return Icons.shopping_bag;
      case 'hotel':
        return Icons.hotel;
      default:
        return Icons.attractions;
    }
  }
}

/// A single fixed-size photo card: image (with icon-box fallback and
/// attribution overlay) over title + meta/rating row + optional Add-to-trip.
class PlacePhotoCard extends StatelessWidget {
  final PlaceCardData data;
  final VoidCallback? onTap;
  final VoidCallback? onAddToTrip;

  const PlacePhotoCard({
    super.key,
    required this.data,
    this.onTap,
    this.onAddToTrip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final fallbackBox = Container(
      color: data.accent.withValues(alpha: 0.12),
      alignment: Alignment.center,
      child: Icon(data.fallbackIcon, size: 32, color: data.accent),
    );

    return SizedBox(
      width: kPlaceCardWidth,
      height: kPlaceCardHeight,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Semantics(
            button: onTap != null,
            label: data.title,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: kPlaceCardImageHeight,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (data.photoUrl != null)
                        Image.network(
                          data.photoUrl!,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          excludeFromSemantics: true,
                          // Bound the decode to the fixed card width
                          // (DPR-scaled): /places/photo serves up to 800px
                          // for a 200×96 slot.
                          cacheWidth: (kPlaceCardWidth *
                                  MediaQuery.devicePixelRatioOf(context))
                              .round(),
                          errorBuilder: (_, __, ___) => fallbackBox,
                        )
                      else
                        fallbackBox,
                      // Photographer credit (Google TOS). A Stack sibling of
                      // the image so it also shows over the fallback — the
                      // compliance path stays unconditional.
                      if (data.photoUrl != null &&
                          (data.attribution?.isNotEmpty ?? false))
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.sm, vertical: 2),
                            decoration:
                                BoxDecoration(gradient: AppColors.heroScrim),
                            child: Text(
                              data.attribution!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontSize: 9,
                                color: Colors.white.withValues(alpha: 0.9),
                              ),
                            ),
                          ),
                        ),
                      if (data.localBadge)
                        Positioned(
                          top: AppSpacing.xs,
                          left: AppSpacing.xs,
                          child: Tooltip(
                            message: data.localCredit ?? '',
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                              ),
                              // The badge disc is white in both themes, so
                              // the glyph always takes the light shade.
                              child: Icon(Icons.verified,
                                  size: 14,
                                  color: AppColors.toolLocal(
                                      Brightness.light)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.sm, AppSpacing.xs, 0, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding:
                              const EdgeInsets.only(right: AppSpacing.sm),
                          child: Text(
                            data.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Expanded(child: _metaRow(theme)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _metaRow(ThemeData theme) {
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    Widget meta;
    if (data.rating != null) {
      meta = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star_rounded, size: 14, color: Colors.amber.shade600),
          const SizedBox(width: 2),
          Text(
            data.rating!.toStringAsFixed(1),
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          // priceLabel and priceLevel share one slot and are mutually
          // exclusive by construction (see the field doc): a real rate wins
          // over Google's $-sign bucket, and hotels never carry both.
          if (data.priceLabel != null)
            Flexible(
              child: Text(' · ${data.priceLabel}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis),
            )
          else if (data.priceLevel != null && data.priceLevel! > 0)
            Flexible(
              child: Text(' · ${'\$' * data.priceLevel!}',
                  style: muted, overflow: TextOverflow.ellipsis),
            ),
        ],
      );
    } else {
      meta = Text(
        data.metaLine,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: data.metaIsAccent
            ? theme.textTheme.labelMedium
                ?.copyWith(color: data.accent, fontWeight: FontWeight.w600)
            : muted,
      );
    }

    return Row(
      children: [
        Expanded(child: meta),
        if (data.externalLink)
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.xs),
            child: Icon(Icons.open_in_new,
                size: 14, color: theme.colorScheme.onSurfaceVariant),
          ),
        if (onAddToTrip != null)
          AddToTripButton(onPressed: onAddToTrip!, color: data.accent),
      ],
    );
  }
}

/// A labeled horizontal rail of [PlacePhotoCard]s at the chat tail: header row
/// (accent icon + count label + optional View-in-trip) over a fixed-height
/// scrolling strip. Fixed heights everywhere — image arrival can repaint but
/// never reflow the tail.
class PlacePhotoStrip extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String label;
  final VoidCallback? onViewTrip;
  final List<PlacePhotoCard> cards;

  /// Label for the trailing header action. Defaults to the chat's
  /// "View in trip"; the trip-detail events rail passes "See all", where the
  /// action opens the full list rather than navigating to a trip.
  final String? actionLabel;

  const PlacePhotoStrip({
    super.key,
    required this.icon,
    required this.accent,
    required this.label,
    this.onViewTrip,
    required this.cards,
    this.actionLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          child: Row(
            children: [
              Icon(icon, size: 16, color: accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (onViewTrip != null)
                InkWell(
                  onTap: onViewTrip,
                  borderRadius: AppRadius.smAll,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.xs, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          actionLabel ?? context.l10n.resultChipViewInTrip,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: accent, fontWeight: FontWeight.w600),
                        ),
                        Icon(Icons.chevron_right, size: 16, color: accent),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(
          // Card height + a gutter so the Card's elevation shadow isn't
          // clipped by the rail's edge.
          height: kPlaceCardHeight + AppSpacing.sm,
          // Default web/desktop ScrollBehavior excludes mouse drags, which
          // would leave off-viewport cards unreachable for mouse users —
          // enable drag-to-pan for every pointer kind.
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: PointerDeviceKind.values.toSet(),
            ),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              itemCount: cards.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(width: AppSpacing.sm),
              itemBuilder: (_, i) => cards[i],
            ),
          ),
        ),
      ],
    );
  }
}
