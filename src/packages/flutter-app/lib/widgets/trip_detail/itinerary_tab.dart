// Part of the trip detail screen library — see trip_detail_screen.dart.
// Verbatim move (zero behavior change): the members below are the
// itinerary tab's city sections, day accordions, and item rows,
// lifted out of the god-screen so wave 2 can redesign them in
// isolation.
part of '../../screens/trip_detail_screen.dart';

  /// Calendar icon size and trailing gap inside the chip — consumed by both
  /// the render and the measurement ([_chipIconSpan]) so they cannot drift.
const double _chipIconSize = 14;

const double _chipIconGap = 4;

const double _chipIconSpan = _chipIconSize + _chipIconGap;

  /// Minimum gap between the range text and the nights suffix. Also the
  /// error budget for TextPainter-vs-Text measurement divergence: a chip can
  /// only spuriously ellipsize if measurement undershoots by more than this.
const double _chipInnerGap = 8;

  /// Pathological ceiling (kept from the pre-column layout): real localized
  /// chips measure well under it; absurd text scales ellipsize instead of
  /// overflowing the header row. Never scale this with the textScaler — the
  /// chip is a rigid child of the header row and a scaled cap could exceed a
  /// phone row's width.
const double _chipMaxWidth = 200;

  /// Greek islands/ports we offer ferry connectors between (mirrors the API's
  /// isGreekLocation set; kept small and local since it only gates the UI hint).
const _greekIslands = {
    'athens', 'piraeus', 'santorini', 'thira', 'fira', 'oia', 'mykonos',
    'naxos', 'paros', 'ios', 'milos', 'syros', 'tinos', 'folegandros',
    'crete', 'heraklion', 'chania', 'rethymno', 'rhodes', 'kos', 'corfu',
    'kefalonia', 'zakynthos', 'lefkada', 'skiathos', 'skopelos', 'samos',
    'chios', 'lesbos', 'mytilene', 'karpathos', 'symi', 'hydra', 'spetses',
    'aegina',
  };


/// The itinerary tab's slice of the screen's State (specs/trip-detail-extract):
/// city sections, day accordions, item rows, and their sheets. Verbatim move —
/// the members below are unchanged; only their home file changed. Extension
/// (not mixin) so the screen's members stay exactly as they were: no override
/// annotations, no abstract dependency header. The one mechanical touch: an
/// extension can't call the protected [State.setState], so three sites call
/// the screen's one-line [_rebuild] pass-through instead.
extension on _TripDetailScreenState {

  Widget _itemLeading(String? category, int position) {
    switch (category) {
      case 'restaurant':
        return const CircleAvatar(child: Icon(Icons.restaurant, size: 18));
      case 'attraction':
        return const CircleAvatar(child: Icon(Icons.attractions, size: 18));
      default:
        return CircleAvatar(child: Text('${position + 1}'));
    }
  }


  /// The group an item belongs to: its day-trip hub city when set, else its own
  /// city (the shared rule in utils/trip_legs.dart).
  String? _hubOf(ItineraryItem item) => hubOf(item);


  /// The city an item belongs to: the AI-assigned [ItineraryItem.city] when set,
  /// otherwise a best-effort parse of the formatted address (shared rule in
  /// utils/trip_legs.dart).
  String? _cityOf(ItineraryItem item) => cityOf(item);


  /// Renders a hub group's items as slivers, split into "Day N" sub-sections
  /// when items carry day numbers (day-trip batching applied within each day).
  /// Each day is a [MultiSliver] whose header pins below the city header while
  /// the day's items scroll past, then is pushed off by the next day. Legacy
  /// items with no day fall back to flat day-trip batching with no day headers.
  ///
  /// [cityKey] is the display city (weather lookup, refine target); [groupKey]
  /// identifies this run of it and prefixes the day keys, so a revisited city's
  /// two runs never share a day header (see [_buildGroups]).
  List<Widget> _buildGroupItemSlivers(String cityKey, String groupKey,
      List<ItineraryItem> items, ThemeData theme, DateTime? tripStart,
      {required bool showTonight,
      ({DateTime? start, DateTime? end})? range,
      List<int> emptyDays = const []}) {
    // City-filler suppression happens here — NOT in the derivation's
    // filtered list — so an all-filler city keeps its group (city header +
    // embedded booking rows; the slot<->group mapping indexes over the full
    // itinerary).
    items = items.where((it) => !isCityFiller(it)).toList();
    if (!items.any((it) => it.day != null)) {
      // A dayless leg renders flat, with no day headers — so it has no gaps to
      // point at. The derivation mirrors this branch and hands back an empty
      // [emptyDays] here.
      return _dayTripSectionSlivers(items, theme);
    }
    // Per-day weather (specs/weather-in-itinerary): one report per city group
    // for its date window — one API call per city per trip view, cached by the
    // family provider. Best-effort: valueOrNull stays null until it resolves
    // (and forever on failure), so nothing renders and the pinned-scroll math
    // is untouched. 'Other places' has no real city to geocode. The watch
    // itself lives in each day's chip Consumer (see _weatherChipSliver) so a
    // report resolving repaints those chips, never the whole screen.
    final weatherQuery = (cityKey != _kOtherPlaces &&
            range?.start != null &&
            range?.end != null)
        ? WeatherQuery(
            city: cityKey,
            startDate: _fmt(range!.start!),
            endDate: _fmt(range.end!),
          )
        : null;
    // Today mode: the header for today's trip day (if any) gets a visible
    // highlight; undated/past/future trips resolve to null and render as-is.
    final todayDay =
        tripDayOn(_trip?.startDate, _trip?.endDate, DateTime.now());
    final slivers = <Widget>[];
    // Running month for the narrow day labels: the month is spelled out when
    // it is the first dated day of this group and whenever it CHANGES, and
    // dropped in between. So a city reads "Sat, Aug 29 · Sun 30 · Mon 31 ·
    // Tue, Sep 1 · Wed 2" — the way a person writes a list of dates. Dropping
    // it unconditionally would leave "Sun 31 / Tue 2" genuinely ambiguous
    // across a month rollover, which is exactly where a traveler is checking.
    int? lastMonth;

    // Open days interleave with the planned ones in day order. They are
    // disjoint from the item days by construction (both come from one
    // planned-day set in TripDerivation.compute), so this merge can never
    // double-render a day; anything left over flushes after the loop.
    var nextEmpty = 0;
    void flushEmptiesBefore(int? day) {
      while (nextEmpty < emptyDays.length &&
          (day == null || emptyDays[nextEmpty] < day)) {
        final d = emptyDays[nextEmpty++];
        slivers.add(SliverToBoxAdapter(
          child: _emptyDayRow(d, '$groupKey#$d', tripStart, theme,
              isToday: d == todayDay,
              onPlan: _planDaysAction(groupKey, cityKey, [d])),
        ));
      }
    }

    var i = 0;
    while (i < items.length) {
      final day = items[i].day;
      final run = <ItineraryItem>[];
      while (i < items.length && items[i].day == day) {
        run.add(items[i]);
        i++;
      }
      if (day != null) {
        flushEmptiesBefore(day);
        final dayKey = '$groupKey#$day';
        final collapsed = _collapsedDays.contains(dayKey);
        final month = tripStart?.add(Duration(days: day - 1)).month;
        final showMonth = month == null || month != lastMonth;
        lastMonth = month;
        final header = _daySubHeader(
            day, tripStart, theme, collapsed, _runTravelMin(run), () {
          _rebuild(() {
            if (collapsed) {
              _collapsedDays.remove(dayKey);
            } else {
              _collapsedDays.add(dayKey);
            }
          });
        },
            // Refine needs the network; owners and editor co-planners both
            // get the per-day refine icon (viewers don't).
            (!_isOffline && (_trip?.canEdit ?? true))
                ? () {
                    final trip = _trip;
                    if (trip == null) return;
                    // 'Other places' is a fallback label, not a real hub —
                    // omit the city qualifier so the server matches on the
                    // day alone.
                    _openRefine(
                        trip,
                        RefineTarget.day(day,
                            city: cityKey == _kOtherPlaces ? null : cityKey));
                  }
                : null,
            headerKey: _dayHeaderKeys.putIfAbsent(dayKey, GlobalKey.new),
            isToday: day == todayDay,
            showMonth: showMonth);
        // Tonight caption (specs/happening-now): a non-pinned content row —
        // it scrolls and collapses with the section, never joining the
        // pinned chrome. [showTonight] is true for at most one group, so
        // repeated day numbers across city groups can't duplicate it.
        final trip = _trip;
        final tonight = (showTonight && day == todayDay && trip != null)
            ? _tonightCaption(theme, _derive(trip).staysOnNight(day))
            : null;
        // Weather chip for this day, if the report covers its date. Historical
        // reports carry last year's month-day, so we match on month-day. The
        // sliver exists whenever a lookup is possible and renders zero-size
        // until (unless) the report resolves and covers the day — a Consumer,
        // so the resolution repaints only this chip.
        Widget? weatherChip;
        if (weatherQuery != null && tripStart != null) {
          final md = _fmt(tripStart.add(Duration(days: day - 1))).substring(5);
          weatherChip = Consumer(
            builder: (context, ref, _) {
              final report = ref.watch(weatherByCityProvider(weatherQuery)
                  .select((a) => a.valueOrNull));
              final wd = report?.dayFor(md);
              if (wd == null) return const SizedBox.shrink();
              return _weatherChip(theme, wd, report!.isHistorical);
            },
          );
        }
        // A collapsed day pins nothing: pinning exists so a header stays
        // visible while its content scrolls beneath it, and a zero-body
        // pinned group's paintOrigin (= viewport overlap) poisons
        // MultiSliver's minPaintOrigin — the header squishes, then
        // vanishes, as the pinned chrome scrolls in. Same hazard as the
        // collapsed city groups in build.
        if (collapsed) {
          slivers.add(SliverToBoxAdapter(child: header));
        } else {
          slivers.add(MultiSliver(
            pushPinnedChildren: true,
            children: [
              SliverPinnedHeader(child: header),
              if (weatherChip != null) _boxSliver([weatherChip]),
              if (tonight != null) _boxSliver([tonight]),
              ..._dayTripSectionSlivers(run, theme),
            ],
          ));
        }
      } else {
        slivers.addAll(_dayTripSectionSlivers(run, theme));
      }
    }
    // Open days after the leg's last planned one — the common case on a spine,
    // where the middle of the stay is empty and only the arrival and move-on
    // days carry anything.
    flushEmptiesBefore(null);
    return slivers;
  }


  /// Shared width for every city-header date chip this build: max over groups
  /// of icon + range + gap + nights, measured with the exact strings and the
  /// exact style the chips render, capped at [_chipMaxWidth]. One width for
  /// all rows is what makes the chips align as columns. Compute it as a
  /// build-local alongside the groups list — never cache it in state: pinned
  /// headers rebuild from the same pass as scrolling rows, and a stale cached
  /// width would misalign them against fresh ones.
  /// The one chip text style, shared by the chip Texts and the measurement
  /// so the two cannot drift.
  TextStyle? _chipTextStyle(ThemeData theme) =>
      theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary);


  double _dateChipWidth(List<CityGroup> groups, ThemeData theme) {
    var style = _chipTextStyle(theme);
    // Text applies the boldText accessibility flag internally; TextPainter
    // does not — merge it here or measurement undershoots the rendered width.
    if (MediaQuery.boldTextOf(context)) {
      style = style?.copyWith(fontWeight: FontWeight.bold);
    }
    final tp = TextPainter(
      textDirection: Directionality.of(context),
      // The TextScaler object, not a factor: Android 14+ scaling is nonlinear.
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    );
    double measure(String s) {
      tp.text = TextSpan(text: s, style: style);
      tp.layout();
      // Whole px: a float-exact fit on the widest row would self-ellipsize.
      return tp.width.ceilToDouble();
    }

    var w = 0.0;
    for (final g in groups) {
      final chip = g.dateRange;
      if (chip == null) continue;
      var cw = _chipIconSpan + measure(chip.range);
      if (chip.nights != null) cw += _chipInnerGap + measure(chip.nights!);
      if (cw > w) w = cw;
    }
    tp.dispose();
    return w > _chipMaxWidth ? _chipMaxWidth : w;
  }


  /// City group header: name, date range, refine + collapse controls. Pinned
  /// at the top of the scroll area while its group scrolls past; the opaque
  /// Material keeps items from showing through while pinned. [cityCollapsed]
  /// comes from the caller's render branch — the one _collapsedGroups read.
  Widget _cityHeader(Trip trip, CityGroup group, ThemeData theme,
      double dateChipWidth,
      {required bool cityCollapsed}) {
    final l10n = context.l10n;
    final chipStyle = _chipTextStyle(theme);
    // Narrow drops the dates OUT of the header row and stacks them under the
    // name (see [_cityHeaderMetaLine]). The row's rigid chip is measured for
    // the widest group and can claim up to [_chipMaxWidth] of a ~300px phone
    // row, and since the label's Expanded is the only flex child it absorbs
    // the whole deficit — which is how "Prague" rendered as "Pra…". Columns
    // are what the chip buys, and a phone has no room to spend on them.
    final stackDates = _narrow && group.dateRange != null;
    final header = HoverReveal(
      builder: (context, revealed) => Material(
        color: theme.scaffoldBackgroundColor,
        child: InkWell(
          onTap: () {
            // A pure list toggle: expansion is decoupled from the map, so a
            // header tap never writes focus, never moves the camera, and
            // never touches any other group. No scroll either — the user is
            // already at the header.
            _rebuild(() {
              cityCollapsed
                  ? _collapsedGroups.remove(group.key)
                  : _collapsedGroups.add(group.key);
            });
          },
          child: Padding(
            // Narrow buys back some of the second line's height at the top,
            // where the gap between a city and the day header under it was
            // the loosest thing on the phone.
            padding: _narrow
                ? const EdgeInsets.fromLTRB(16, 12, 16, 4)
                : const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.location_on,
                        size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 6),
                    // The qualifier rides INSIDE this Expanded, never as a
                    // second flex child: a sibling Flexible would split the
                    // free space with the label and drag the chip+chevron
                    // cluster off the right edge (see the date chip's note
                    // below, PR #307). It stacks BELOW the label rather than
                    // beside it, so the label's Text keeps the outer Row as its
                    // nearest Row ancestor — the header tests navigate that
                    // ancestry to pair a city with its date chip.
                    Expanded(
                      child: _cityHeaderLabel(l10n, group, theme,
                          metaLine: stackDates
                              ? _cityHeaderMetaLine(group, chipStyle)
                              : null),
                    ),
                    if (group.dateRange != null && !stackDates)
                      // A rigid SizedBox at the per-build shared width
                      // ([_dateChipWidth]), so calendar icons, range starts,
                      // and nights suffixes form columns across rows.
                      // Deliberately NOT Flexible: a second flex child would
                      // split the free space with the label's Expanded and
                      // drag the chip+chevron cluster off the right edge
                      // (PR #307) — the inner Expanded on the range lives
                      // inside the chip's own Row, invisible to the outer
                      // flex accounting, and absorbs any deficit by
                      // ellipsizing when the shared width hits the
                      // pathological [_chipMaxWidth] cap; the nights suffix
                      // keeps its intrinsic width flush right.
                      MergeSemantics(
                        // One utterance per chip ("Aug 24 – Aug 27 · 3
                        // nights"), matching the pre-split reading order.
                        child: SizedBox(
                          width: dateChipWidth,
                          child: Row(
                            children: [
                              Icon(Icons.event,
                                  size: _chipIconSize,
                                  color: theme.colorScheme.primary),
                              const SizedBox(width: _chipIconGap),
                              Expanded(
                                child: Text(
                                  group.dateRange!.range,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: chipStyle,
                                ),
                              ),
                              if (group.dateRange!.nights != null) ...[
                                const SizedBox(width: _chipInnerGap),
                                ConstrainedBox(
                                  // Guard: at extreme accessibility scale a
                                  // nights label alone could exceed the
                                  // capped chip — bound it so it ellipsizes
                                  // instead of overflowing the inner Row.
                                  constraints: const BoxConstraints(
                                      maxWidth: _chipMaxWidth -
                                          _chipIconSpan -
                                          _chipInnerGap),
                                  child: Text(
                                    group.dateRange!.nights!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: chipStyle,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    // 'Other places' has no hub the section tool can target;
                    // refine also needs the network. Hover-revealed on
                    // pointer devices (always visible on touch) to keep the
                    // resting row quiet. canEdit/offline are screen-wide —
                    // when they drop the button they drop it on EVERY row, so
                    // the chip columns stay aligned. 'Other places' is the
                    // one per-row variance: it keeps an invisible,
                    // width-identical placeholder (same IconButton config, so
                    // density changes can't drift it) or its chip cluster
                    // would sit a button-slot right of the other rows —
                    // EXCEPT on narrow, where the dates have left the row and
                    // there is no cluster left to align. Holding ~40px of a
                    // phone row for a button nobody can see is the density
                    // this pass exists to remove.
                    if (trip.canEdit && !_isOffline)
                      group.label != _kOtherPlaces
                          ? HoverRevealed(
                              revealed: revealed,
                              child: IconButton(
                                icon: const Icon(Icons.auto_awesome, size: 16),
                                tooltip: l10n.tripRefineCity(group.label),
                                visualDensity: VisualDensity.compact,
                                color: theme.colorScheme.primary,
                                onPressed: () => _openRefine(
                                    trip, RefineTarget.city(group.label)),
                              ),
                            )
                          : _narrow
                              ? const SizedBox.shrink()
                              : ExcludeSemantics(
                                  child: IgnorePointer(
                                    child: Opacity(
                                      opacity: 0,
                                      // No tooltip: IgnorePointer blocks
                                      // hover, a ghost tooltip target would
                                      // outlive it.
                                      child: IconButton(
                                        icon: const Icon(Icons.auto_awesome,
                                            size: 16),
                                        visualDensity: VisualDensity.compact,
                                        onPressed: null,
                                      ),
                                    ),
                                  ),
                                ),
                    const SizedBox(width: 4),
                    Icon(
                      cityCollapsed ? Icons.chevron_right : Icons.expand_more,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                  ],
                ),
                // Open days, promoted (specs/shape-before-schedule): a visible,
                // labelled version of the same city refine the hover sparkle
                // above performs — one action, two affordances. It is a second
                // LINE and never a change to the Row, because the Row's widths
                // are what align the date chips into columns across cities (see
                // the ghost-placeholder note above); a button in there would
                // shift every other city's chip.
                //
                // Renders on the collapsed header too, which is exactly where
                // "2 days unplanned" earns its place.
                if (_planDaysAction(group.key, group.label, group.emptyDays)
                    case final plan?) ...[
                  const SizedBox(height: 2),
                  Padding(
                    padding: const EdgeInsets.only(left: 24),
                    child: Row(
                      children: [
                        Icon(Icons.edit_calendar_outlined,
                            size: 14, color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            l10n.tripUnplannedDays(group.emptyDays.length),
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Flexible + ellipsis for the same reason the label
                        // beside it is: Spanish at 1.3x on a 320px viewport
                        // overflowed this Row while the button was its one
                        // unflexible child.
                        Flexible(
                          child: TextButton(
                            key: ValueKey('plan-days:${group.key}'),
                            style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 8)),
                            onPressed: plan,
                            child: Text(
                              l10n.tripPlanTheseDays,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                const Divider(height: 1),
              ],
            ),
          ),
        ),
      ),
    );
    // Repaint-isolate the header: the open city's header rides pinned over
    // the scrolling list (and collapsed ones scroll with it), and the hover
    // setState + InkWell highlight must repaint this header's own layer, not
    // re-record the viewport picture. Covers pinned and collapsed branches.
    return RepaintBoundary(child: header);
  }


  /// Curated, locally-sourced recommendations for a city group — vetted picks
  /// from real locals. Renders nothing when there is no coverage for the city
  /// (empty list) or on error, so it never shows a broken/empty section.
  Widget _localIntelSliver(String label, ThemeData theme) {
    if (label == _kOtherPlaces) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverToBoxAdapter(
      child: Consumer(builder: (context, ref, _) {
        final recs =
            ref.watch(localRecsByCityProvider(label)).valueOrNull ?? [];
        final guides =
            ref.watch(localGuidesByCityProvider(label)).valueOrNull ?? [];
        if (recs.isEmpty && guides.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              // left: lines the icon up with the booking rows' kind icons,
              // which sit at 12px (BookingTodoRow's own left padding).
              padding: const EdgeInsets.only(
                  left: AppSpacing.md, top: AppSpacing.sm, bottom: AppSpacing.xs),
              child: Row(
                children: [
                  Icon(Icons.verified, size: 16, color: AppColors.toolLocal),
                  const SizedBox(width: 6),
                  Text(
                    context.l10n.tripLocalIntel,
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AppColors.toolLocal,
                    ),
                  ),
                ],
              ),
            ),
            for (final g in guides) _guideChip(g, theme),
            for (final r in recs.take(6))
              LocalRecCard(
                rec: r,
                onAddToTrip: () =>
                    _addToTrip(AddToTripPayload.fromLocalRec(r)),
              ),
          ],
        );
      }),
    );
  }


  /// A tappable "Local guide" row inside the Local intel section that opens the
  /// full narrative guide (story + ordered pins + map).
  Widget _guideChip(LocalGuide guide, ThemeData theme) {
    final accent = AppColors.toolLocal;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => pushOnce(
            context,
            MaterialPageRoute(
              builder: (_) => LocalGuideDetailScreen(guide: guide),
            )),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(Icons.menu_book, size: 20, color: accent),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.l10n.tripLocalGuideTitle(guide.title),
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (guide.sourceName.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        context.l10n.tripGuideBy(guide.sourceName),
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: accent, fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Icon(Icons.chevron_right,
                  color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }


  /// Live local-events section for a city group, looked up for the group's
  /// date window and rendered as the same horizontal poster rail the plan chat
  /// uses for these events ([PlacePhotoStrip] + [PlaceCardData.event]) — one
  /// card system, two surfaces. Returns an empty box (no sliver content) when
  /// the group has no real city/dates to query. Wrapped in a [Consumer] so
  /// only this section rebuilds as the async lookup resolves.
  ///
  /// [range] is the group's VISIBLE range — the window the city header chip
  /// shows the traveler. It has to be: a section headed "Events while you're
  /// here" that queried a different window than the one on screen is what made
  /// a Sep 1–4 Berlin leg show five events, all on Sep 4.
  Widget _eventsSliver(
    Trip trip,
    String label,
    ({DateTime? start, DateTime? end})? range,
    ThemeData theme,
  ) {
    if (label == _kOtherPlaces ||
        range?.start == null ||
        range?.end == null) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final query = EventsQuery(
      city: label,
      startDate: _fmt(range!.start!),
      endDate: _fmt(range.end!),
    );
    return SliverToBoxAdapter(
      child: Consumer(builder: (context, ref, _) {
        final async = ref.watch(eventsByCityProvider(query));
        return async.when(
          loading: () => Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: AppSpacing.sm),
                // Flexible, or a long city name overflows phones for the
                // few frames this spinner row is on screen.
                Flexible(
                  child: Text(context.l10n.tripFindingEvents(label),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
              ],
            ),
          ),
          // On error (e.g. provider key not set), try the Greek source-links
          // fallback rather than going silent.
          error: (_, __) => _greekEventsFallback(query, theme),
          data: (events) {
            if (events.isEmpty) return _greekEventsFallback(query, theme);
            // Day-spread, not the chronological head: on a busy first night a
            // plain take(N) fills every slot from day one and the rest of the
            // stay never appears (utils/event_picks.dart).
            final picks = spreadEventsByDay(events, limit: kEventRailCards);
            return Padding(
              // left: lines the strip's header icon up with the booking rows'
              // kind icons, which sit at 12px (BookingTodoRow's own left
              // padding) — the leading grid asserted by
              // trip_detail_booking_alignment_test.
              padding: const EdgeInsets.only(left: AppSpacing.md),
              child: PlacePhotoStrip(
                icon: Icons.local_activity,
                accent: AppColors.toolEvents,
                // Counts everything found, not the cards shown — otherwise 8
                // reads as "that's all there is". At the server's per-city cap
                // the true total is unknown, so the count says "30+".
                label: events.length >= kEventsServerCap
                    ? context.l10n
                        .tripEventsWhileHereCountCapped(events.length)
                    : context.l10n.tripEventsWhileHereCount(events.length),
                actionLabel: context.l10n.commonSeeAll,
                onViewTrip: events.length > picks.length
                    ? () => showCityEventsSheet(
                          context,
                          city: label,
                          events: events,
                          onAddToTrip: (e) =>
                              _addToTrip(AddToTripPayload.fromEvent(e)),
                        )
                    : null,
                cards: [
                  for (final e in picks)
                    PlacePhotoCard(
                      data: PlaceCardData.event(e),
                      onTap: e.url.isEmpty
                          ? null
                          : () => trackedLaunchUrl(context, e.url,
                              provider: 'ticketmaster',
                              surface: 'trip_event_card',
                              tripId: trip.id),
                      onAddToTrip: () =>
                          _addToTrip(AddToTripPayload.fromEvent(e)),
                    ),
                ],
              ),
            );
          },
        );
      }),
    );
  }


  /// When the structured events lookup is empty/errored, show curated Greek
  /// event-discovery links for Greek cities (empty for everywhere else, so this
  /// renders nothing). Keeps the section useful where Ticketmaster has no data.
  Widget _greekEventsFallback(EventsQuery query, ThemeData theme) {
    return Consumer(builder: (context, ref, _) {
      final links = ref.watch(greeceEventLinksProvider(query)).valueOrNull;
      if (links == null || links.isEmpty) return const SizedBox.shrink();
      return SourceLinksCard(
        icon: Icons.local_activity,
        accent: AppColors.toolEvents,
        title: context.l10n.tripFindEventsIn(query.city),
        links: links,
      );
    });
  }


  bool _isGreekIsland(String label) {
    final n = label.toLowerCase().trim();
    if (n.contains('greece')) return true;
    if (_greekIslands.contains(n)) return true;
    final comma = n.indexOf(',');
    if (comma > 0 && _greekIslands.contains(n.substring(0, comma).trim())) {
      return true;
    }
    return false;
  }


  /// Batches consecutive day-trip places (by town) under an indented
  /// "Day trip · <town>" sub-header so nearby towns read as excursions from the
  /// hub city rather than separate stops. Each contiguous batch (hub run or
  /// day-trip batch) renders as its own [SliverReorderableList] so items can
  /// be dragged inline within it; the within-city travel connector between
  /// adjacent tiles is folded into the row below it and travels with it.
  List<Widget> _dayTripSectionSlivers(
      List<ItineraryItem> items, ThemeData theme) {
    final slivers = <Widget>[];
    var i = 0;
    while (i < items.length) {
      final dt = items[i].dayTripFrom?.trim();
      if (dt != null && dt.isNotEmpty) {
        final town = _cityOf(items[i]) ?? context.l10n.tripDayTripFallback;
        slivers.add(_boxSliver([
          _dayTripSubHeader(town, theme, _dayTripTravelLabel(items[i])),
        ]));
        final batch = <ItineraryItem>[];
        while (i < items.length) {
          final it = items[i];
          final d = it.dayTripFrom?.trim();
          if (d != null && d.isNotEmpty && _cityOf(it) == town) {
            batch.add(it);
            i++;
          } else {
            break;
          }
        }
        slivers.add(_batchReorderableSliver(batch, 32, theme));
      } else {
        final batch = <ItineraryItem>[];
        while (i < items.length &&
            (items[i].dayTripFrom?.trim() ?? '').isEmpty) {
          batch.add(items[i]);
          i++;
        }
        slivers.add(_batchReorderableSliver(batch, 12, theme));
      }
    }
    return slivers;
  }


  /// One contiguous batch of item tiles as an inline-draggable sliver. Drag is
  /// confined to the batch, a subset of _sectionOf's boundary (items rendered
  /// apart can't be dragged past each other — the menu's "Reorder section"
  /// sheet still covers the full section).
  Widget _batchReorderableSliver(
      List<ItineraryItem> batch, double indent, ThemeData theme) {
    // Narrow first: phones reorder via the kebab (Move up/down + Reorder
    // section), so no handle is built at all — the same null-handle path
    // offline/singleton batches already take.
    final canDrag =
        !_narrow && !_readOnly && !_isOffline && batch.length > 1;
    return SliverReorderableList(
      itemCount: batch.length,
      // Unlike ReorderableListView, the sliver variant doesn't wrap the
      // dragged proxy in a Material — without one the lifted ListTile throws.
      proxyDecorator: (child, index, animation) => Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(8),
        child: child,
      ),
      onReorder: (oldIndex, newIndex) =>
          _reorderBatchInline(batch, oldIndex, newIndex),
      itemBuilder: (context, i) {
        final item = batch[i];
        final connector = i > 0
            ? _travelConnector(batch[i - 1], item, indent, theme)
            : null;
        return Column(
          key: ValueKey(item.id),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (connector != null) connector,
            _itemTile(
              item,
              indent,
              theme,
              dragHandle: canDrag
                  ? ReorderableDragStartListener(
                      index: i,
                      child: Icon(Icons.drag_indicator,
                          color: theme.colorScheme.onSurfaceVariant),
                    )
                  : null,
            ),
          ],
        );
      },
    );
  }


  /// Persists an inline drag within one rendered batch. Optimistic: the new
  /// order is spliced into the trip's item list in place so the drop doesn't
  /// snap back while the request is in flight; the silent reload then
  /// refreshes positions and travel connectors (or restores the server order
  /// after a failure).
  Future<void> _reorderBatchInline(
      List<ItineraryItem> batch, int oldIndex, int newIndex) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    final trip = _trip;
    final items = trip?.items;
    if (trip == null || items == null) return;
    if (newIndex > oldIndex) newIndex--;
    if (newIndex == oldIndex) return;
    final newOrder = List.of(batch);
    newOrder.insert(newIndex, newOrder.removeAt(oldIndex));
    final batchIds = {for (final it in batch) it.id};
    var next = 0;
    final newItems = <ItineraryItem>[
      for (final it in items)
        if (batchIds.contains(it.id)) newOrder[next++] else it,
    ];
    _rebuild(() {
      items.setAll(0, newItems);
      // NOTE: each item's `position` still holds its PRE-drag value until the
      // silent reload returns — ItineraryItem is immutable by design. The city
      // headers no longer care (TripDerivation indexes their date chips by leg,
      // not by position), which is what kept a dragged frame from showing a
      // neighbouring leg's dates.
      // CONTRACT: any in-place mutation of a derivation input MUST bump the
      // epoch. This setAll is the screen's ONE in-place write — the trip's
      // item List keeps its identity, so [_derive]'s identity checks can't
      // see the new order; the epoch bump is what invalidates the memo and
      // lets this optimistic frame render the dragged order.
      _itemOrderEpoch++;
    });
    try {
      await ref
          .read(tripsApiServiceProvider)
          .reorderItineraryItems(trip.id, [for (final it in newItems) it.id]);
      await _load(silent: true);
    } catch (e) {
      _showSnack(l10n.tripReorderFailed(friendlyError(l10n, e)));
      await _load(silent: true);
    }
  }


  /// The city header's name, with the repeat qualifier stacked beneath it when
  /// another group renders the SAME label — a revisited city, or one a bad
  /// section rewrite split in two. Without it the two headers read identically
  /// and the duplicate looks like a rendering bug. [metaLine] stacks under
  /// both on narrow (the date range — see [_cityHeaderMetaLine]).
  ///
  /// This is the ONE place that decides the stacked-label shape: everything
  /// that drops below the name joins this Column, so the name's [Text] keeps
  /// the header's outer Row as its nearest Row ancestor and the header tests
  /// can still navigate that ancestry to pair a city with its dates.
  ///
  /// With neither a qualifier nor a meta line (every ordinary trip on a
  /// desktop) this returns the bare [Text] the header has always used, so the
  /// widget tree is unchanged.
  Widget _cityHeaderLabel(
      AppLocalizations l10n, CityGroup group, ThemeData theme,
      {Widget? metaLine}) {
    final label = Text(
      groupLabelText(l10n, group.label),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
    );
    final qualifier = group.qualifier;
    if (qualifier == null && metaLine == null) return label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        label,
        if (qualifier != null)
          Text(
            qualifier,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        if (metaLine != null) metaLine,
      ],
    );
  }


  /// The narrow city header's second line: "Aug 24 – Aug 27 · 3 nights".
  ///
  /// Carries no calendar icon — the pin above it already anchors the row, and
  /// a second glyph on a phone is the noise this pass removes. The range and
  /// the nights stay TWO Texts, as they have since the chip columns landed:
  /// `tripLegNights` owns the leading "· ", so a zero-night leg drops the
  /// middot structurally rather than by a conditional in the format string.
  /// Both are Flexible so an extreme text scale ellipsizes inside the label
  /// column instead of overflowing it.
  Widget _cityHeaderMetaLine(CityGroup group, TextStyle? chipStyle) {
    final nights = group.dateRange!.nights;
    return MergeSemantics(
      // One utterance, matching the reading order the chip had.
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              group.dateRange!.range,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: chipStyle,
            ),
          ),
          if (nights != null) ...[
            const SizedBox(width: AppSpacing.xs),
            Flexible(
              child: Text(
                nights,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: chipStyle,
              ),
            ),
          ],
        ],
      ),
    );
  }


  /// A small "↓ 12 min · 4.3 km" row shown between two consecutive itinerary
  /// tiles, but only for within-city hops (same hub, truly adjacent in the
  /// itinerary order). Returns null when it shouldn't render.
  Widget? _travelConnector(ItineraryItem from, ItineraryItem to,
      double indentLeft, ThemeData theme) {
    if (to.position != from.position + 1) return null;
    if (_hubOf(from) != _hubOf(to)) return null;
    final timing = _travelByPos[from.position];
    if (timing == null || timing.travelToNextMin <= 0) return null;

    final km = timing.travelToNextKm;
    final dist = km > 0 ? ' · ${km.toStringAsFixed(1)} km' : '';
    final muted = theme.colorScheme.onSurfaceVariant;
    final icon = km > 0 && km <= 1.2
        ? Icons.directions_walk
        : Icons.directions_car_outlined;
    return Padding(
      padding: EdgeInsets.only(left: indentLeft + 28, top: 2, bottom: 2),
      child: Row(
        children: [
          Icon(icon, size: 14, color: muted),
          const SizedBox(width: 6),
          Text(
            '${_fmtTravel(timing.travelToNextMin)}$dist',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ],
      ),
    );
  }


  /// Total within-city travel time (minutes) across the consecutive legs of a
  /// day's run.
  int _runTravelMin(List<ItineraryItem> run) {
    var total = 0;
    for (var k = 0; k < run.length - 1; k++) {
      final a = run[k];
      final b = run[k + 1];
      if (b.position == a.position + 1 && _hubOf(a) == _hubOf(b)) {
        total += _travelByPos[a.position]?.travelToNextMin ?? 0;
      }
    }
    return total;
  }


  /// Travel time from the hub city to a day trip, e.g. "45 min from Paris",
  /// taken from the already-computed leg into the day trip's first stop. Null
  /// unless the preceding item is actually in the hub city (so a town-to-town
  /// or cross-city leg is never mislabeled).
  String? _dayTripTravelLabel(ItineraryItem first) {
    final hub = first.dayTripFrom?.trim();
    if (hub == null || hub.isEmpty) return null;
    ItineraryItem? prev;
    for (final it in _trip?.items ?? const <ItineraryItem>[]) {
      if (it.position == first.position - 1) prev = it;
    }
    if (prev == null) return null;
    final prevDayTrip = prev.dayTripFrom?.trim();
    if (prevDayTrip != null && prevDayTrip.isNotEmpty) return null;
    if (_hubOf(prev) != _hubOf(first)) return null;
    final timing = _travelByPos[prev.position];
    if (timing == null || timing.travelToNextMin <= 0) return null;
    return context.l10n
        .tripTravelFromHub(_fmtTravel(timing.travelToNextMin), hub);
  }


  /// Formats a travel duration: "45 min", "1h", or "1h 20m" (the shared
  /// [fmtTravel], which the derivation's map labels also use).
  String _fmtTravel(int min) => fmtTravel(context.l10n, min);


  /// Day section header: shows the calendar date (day N -> startDate + (N-1))
  /// when the trip start is known, otherwise falls back to "Day N". The opaque
  /// Material keeps items from showing through while the header is pinned —
  /// today's tint is alpha-blended onto the scaffold background (never a
  /// translucent color) for the same reason. [headerKey] gives the Today
  /// scroller a stable handle on the header's render box.
  ///
  /// [showMonth] is the caller's answer to "would dropping the month here lose
  /// anything" — see the running-month rule in [_buildGroupItemSlivers]. It
  /// only bites on narrow; a desktop row has the width to spell every date.
  /// What a day row is called: the calendar date (day N = trip start + N-1)
  /// when the trip has a start, else "Day N". ONE definition — the day header
  /// and the empty-day placeholder below it must never disagree about which
  /// date day N is, and they sit next to each other in the same list.
  ///
  /// The running-month rule lives HERE rather than at the header's call site so
  /// the placeholder cannot drift from it: both rows ask the same function what
  /// day N is called. Empty rows keep the default (month spelled out) because
  /// they are emitted by flushEmptiesBefore, which does not carry the loop's
  /// month state — a format difference on narrow, never a date difference.
  String _dayHeaderLabel(int day, DateTime? tripStart,
      {bool showMonth = true}) {
    final date = tripStart?.add(Duration(days: day - 1));
    if (date == null) return context.l10n.tripDayN(day);
    return _narrow && !showMonth ? weekdayDay(date) : _fmtDayHeader(date);
  }


  Widget _daySubHeader(
      int day,
      DateTime? tripStart,
      ThemeData theme,
      bool collapsed,
      int travelMin,
      VoidCallback onTap,
      VoidCallback? onRefine,
      {Key? headerKey,
      bool isToday = false,
      bool showMonth = true}) {
    final l10n = context.l10n;
    final label = _dayHeaderLabel(day, tripStart, showMonth: showMonth);
    final muted = theme.colorScheme.onSurfaceVariant;
    final header = HoverReveal(
      builder: (context, revealed) => Material(
        key: headerKey,
        color: isToday
            ? Color.alphaBlend(
                theme.colorScheme.primary.withValues(alpha: 0.06),
                theme.scaffoldBackgroundColor)
            : theme.scaffoldBackgroundColor,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            // Narrow drops the calendar glyph and indents to where the city
            // name (and its dates) start instead: two calendar icons stacked
            // two rows apart said less than one clean indent column does, and
            // the day is subordinate to the city, so it should read that way.
            padding: _narrow
                ? const EdgeInsets.fromLTRB(24, 8, 16, 2)
                : const EdgeInsets.fromLTRB(16, 12, 16, 2),
            child: Row(
              children: [
                if (!_narrow) ...[
                  Icon(Icons.today, size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (isToday) ...[
                        const SizedBox(width: 8),
                        StatusPill.custom(
                          label: l10n.tripToday,
                          background: theme.colorScheme.primary
                              .withValues(alpha: 0.15),
                          foreground: theme.colorScheme.primary,
                        ),
                      ],
                    ],
                  ),
                ),
                // Narrow drops the day travel-total: it is fixed-width (no
                // ellipsis) and fights the date label, and the per-leg
                // connectors below carry the same information.
                if (travelMin > 0 && !_narrow) ...[
                  Icon(Icons.directions_car_outlined, size: 14, color: muted),
                  const SizedBox(width: 4),
                  Text(
                    l10n.tripTravelTotal(_fmtTravel(travelMin)),
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                  ),
                  const SizedBox(width: 8),
                ],
                // Hover-revealed on pointer devices (always visible on
                // touch) to keep the resting row quiet.
                if (onRefine != null)
                  HoverRevealed(
                    revealed: revealed,
                    child: IconButton(
                      icon: const Icon(Icons.auto_awesome, size: 16),
                      tooltip: l10n.tripRefineThisDay,
                      visualDensity: VisualDensity.compact,
                      color: theme.colorScheme.primary,
                      onPressed: onRefine,
                    ),
                  ),
                Icon(
                  collapsed ? Icons.chevron_right : Icons.expand_more,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // Repaint-isolate like _cityHeader: open days pin their header over the
    // scrolling list; hover/InkWell repaints must stay in this layer.
    return RepaintBoundary(child: header);
  }


  /// A day inside a city leg that carries nothing — the state the two-pass
  /// planner makes normal (specs/shape-before-schedule). Before this, such a
  /// day rendered NOTHING at all: day sub-headers are derived from the items
  /// grouped under a leg, so a Rome leg spanning Sep 1-5 with places on days 1
  /// and 4 gave no sign that 2 and 3 existed.
  ///
  /// Deliberately NOT a pinned header and NOT collapsible: there is no body to
  /// pin over, and a zero-body pinned sliver poisons the surrounding
  /// MultiSliver's paint origin. Quieter than a planned day — muted glyph and
  /// label — because an open day is an invitation, not a plan.
  ///
  /// [onPlan] is null for viewers and offline, matching the day header's own
  /// refine gate; the row then renders as a plain statement of the gap.
  Widget _emptyDayRow(int day, String dayKey, DateTime? tripStart,
      ThemeData theme,
      {bool isToday = false, VoidCallback? onPlan}) {
    final l10n = context.l10n;
    final muted = theme.colorScheme.onSurfaceVariant;
    return RepaintBoundary(
      key: ValueKey('unplanned-day:$dayKey'),
      child: Material(
        // The same GlobalKey registry the day headers use, so day-jump can
        // scroll to an open day exactly as it scrolls to a planned one.
        key: _dayHeaderKeys.putIfAbsent(dayKey, GlobalKey.new),
        color: isToday
            ? Color.alphaBlend(
                theme.colorScheme.primary.withValues(alpha: 0.06),
                theme.scaffoldBackgroundColor)
            : theme.scaffoldBackgroundColor,
        child: InkWell(
          onTap: onPlan,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
            child: Row(
              children: [
                Icon(Icons.today, size: 16, color: muted),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _dayHeaderLabel(day, tripStart),
                    style: theme.textTheme.labelLarge?.copyWith(color: muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    l10n.tripDayNothingPlanned,
                    style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Spacer(),
                // A label, not a nested button: the row's own InkWell is the
                // tap target, so there is one semantics node here rather than
                // two offering the same action.
                if (onPlan != null) ...[
                  Icon(Icons.auto_awesome,
                      size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 4),
                  // Ellipsizing like the two labels beside it: Spanish at 1.3x
                  // on a 360px viewport overflowed this row by 86px while this
                  // was the one unflexible child (specs/booking-shortlist's
                  // narrow-Spanish test is what caught it).
                  Flexible(
                    child: Text(
                      l10n.tripPlanThisDay,
                      style: theme.textTheme.labelMedium
                          ?.copyWith(color: theme.colorScheme.primary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }


  /// Per-day weather chip (specs/weather-in-itinerary): hi/lo temp + a
  /// condition glyph derived from rain, rendered as a non-pinned content row
  /// under the day header (same indent/typography as [_tonightCaption]).
  /// Forecast days append the rain chance; historical reports (trip beyond the
  /// 16-day horizon) are labeled "typical", never "forecast".
  Widget _weatherChip(ThemeData theme, WeatherDay day, bool historical) {
    final muted = theme.colorScheme.onSurfaceVariant;
    final (icon, iconColor) = _weatherGlyph(theme, day);
    final hi = day.tempMaxC.round();
    final lo = day.tempMinC.round();
    final parts = <String>['$hi° / $lo°'];
    if (!historical &&
        day.precipProbability != null &&
        day.precipProbability! >= rainChanceCaptionPct) {
      parts.add(context.l10n.tripRainChance(day.precipProbability!));
    }
    return Padding(
      // Matches the Tonight caption indent (20 left, 6 top) so the chip reads
      // as a sub-row of the day header.
      padding: const EdgeInsets.fromLTRB(20, 6, 16, 0),
      child: Row(
        children: [
          Icon(icon, size: 15, color: iconColor),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              parts.join('  ·  '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
          if (historical) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                context.l10n.tripTypicalForDates,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: muted,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }


  /// Condition glyph + color from precipitation: sunny / cloud / umbrella by
  /// [rainLevel] — the client's one rain-threshold definition, shared with
  /// the what-to-wear recommendations (utils/clothing_recs.dart).
  (IconData, Color) _weatherGlyph(ThemeData theme, WeatherDay day) {
    final scheme = theme.colorScheme;
    return switch (rainLevel(day)) {
      RainLevel.likely => (Icons.umbrella, scheme.primary),
      RainLevel.some => (Icons.cloud, scheme.onSurfaceVariant),
      RainLevel.none => (Icons.wb_sunny, Colors.amber.shade700),
    };
  }


  /// "Tonight: <stay>" caption for today's day section (specs/happening-now
  /// PR 2): where the traveler sleeps tonight, checkout-exclusively. Returns
  /// null when no covering stay has a non-empty name — no filler row.
  Widget? _tonightCaption(ThemeData theme, List<Accommodation> stays) {
    final names = stays
        .map((a) => a.name.trim())
        .where((n) => n.isNotEmpty)
        .toList();
    if (names.isEmpty) return null;
    return Padding(
      // Matches the _dayTripSubHeader indent (20 left) so the caption reads
      // as a sub-row of the day, tucked tight under the header (6 top).
      padding: const EdgeInsets.fromLTRB(20, 6, 16, 0),
      child: Row(
        children: [
          Icon(Icons.hotel, size: 14, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              context.l10n.tripTonight(names.join(', ')),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }


  Widget _dayTripSubHeader(String town, ThemeData theme, String? travelLabel) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 16, 0),
        child: Row(
          children: [
            Icon(Icons.directions_bus,
                size: 16, color: theme.colorScheme.secondary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                context.l10n.tripDayTripTo(town),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.secondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (travelLabel != null) ...[
              Icon(Icons.directions_car_outlined,
                  size: 14, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                travelLabel,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      );


  /// Opens the add-to-trip picker for a browsed place (local rec / event) with
  /// this trip preselected, then refreshes in place when the add landed here.
  Future<void> _addToTrip(AddToTripPayload payload) async {
    final added =
        await showAddToTripSheet(context, payload, currentTripId: widget.tripId);
    // _refresh(), not a bare silent _load(): it serializes with any reload the
    // refine panel has in flight, so a pre-add snapshot can't land after us
    // and momentarily erase the just-added item. Armed like the chat path —
    // an add the traveler just made must be visible, folded city or not.
    if (added != null && added.id == widget.tripId) {
      _armRevealOfNewItems();
      _refresh();
    }
  }


  Widget _itemTile(ItineraryItem item, double indentLeft, ThemeData theme,
          {Widget? dragHandle}) =>
      // Selection is notifier-driven (see _selectedPosition): each tile
      // listens itself, so selecting a place rebuilds only the visible
      // tiles rather than the whole screen.
      ValueListenableBuilder<int?>(
        valueListenable: _selectedPosition,
        builder: (context, selectedPos, _) =>
            // Secondary controls (maps link, kebab, drag handle) reveal on
            // hover: opacity-only, so layout never shifts, drag geometry
            // stays stable for the reorderable list, and touch devices (no
            // mouse) keep them permanently visible. The time-of-day chip is
            // content, not a control — it stays.
            HoverReveal(
        builder: (context, revealed) => Padding(
          padding: EdgeInsets.only(left: indentLeft),
          child: ListTile(
          leading: _itemLeading(item.category, item.position),
          title: Text(item.name,
              maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: (item.address != null || item.localSourceName != null)
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (item.address != null)
                      Text(item.address!,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    // The local-source credit line: who vouched for this place
                    // (snapshot; shown for agent- and browse-added items alike).
                    if (item.localSourceName != null)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.verified,
                              size: 13, color: AppColors.toolLocal),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              context.l10n
                                  .tripRecommendedBy(item.localSourceName!),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: AppColors.toolLocal,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                  ],
                )
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.timeOfDay != null)
                _TimeOfDayChip(
                    timeOfDay: item.timeOfDay!, compact: _narrow),
              HoverRevealed(
                revealed: revealed,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // On narrow, Maps lives in the kebab and this button
                    // goes — EXCEPT for viewers, who have no kebab (gate
                    // below) and would otherwise lose their only maps
                    // access. Role-only on purpose: offline editors keep
                    // the kebab, so they keep Maps through it.
                    if (!_narrow || _readOnly)
                      IconButton(
                        icon: const Icon(Icons.map_outlined),
                        tooltip: context.l10n.tripOpenInGoogleMaps,
                        onPressed: () => _launch(_mapsUrl(item)),
                      ),
                    if (!_readOnly) _itemMenu(item),
                    if (dragHandle != null) dragHandle,
                  ],
                ),
              ),
            ],
          ),
          selected: selectedPos == item.position,
          selectedTileColor:
              theme.colorScheme.primary.withValues(alpha: 0.08),
          // The map is pinned and always on screen, so tapping an item only
          // needs to update the selection; the notifier rebuilds the map
          // card (TripMap recenters) and the visible tiles — no setState.
          onTap: () => _selectedPosition.value = item.position,
        ),
        ),
        ),
      );


  /// Per-item actions: edit, move within its section, delete (with undo).
  /// Move targets the neighbor in itinerary order but only within the same
  /// day + hub + day-trip batch, so an item can never silently jump across a
  /// section boundary — cross-day moves go through the edit sheet instead.
  Widget _itemMenu(ItineraryItem item) {
    final l10n = context.l10n;
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      tooltip: l10n.tripPlaceActions,
      onSelected: (action) {
        switch (action) {
          case 'edit':
            _editItem(item);
          case 'maps':
            _launch(_mapsUrl(item));
          case 'up':
            _moveItem(item, -1);
          case 'down':
            _moveItem(item, 1);
          case 'reorder':
            _reorderSection(item);
          case 'gcal':
            _addItemToGoogleCalendar(item);
          case 'ics':
            _addItemToAppleCalendar(item);
          case 'delete':
            _deleteItem(item);
        }
      },
      itemBuilder: (context) {
        // Computed lazily — only when the menu actually opens. At the old
        // call-time spot these three ran O(items) work per rendered tile per
        // build (specs/perf-program, Wave 4 PR1).
        final canUp = _moveNeighbor(item, -1) != null;
        final canDown = _moveNeighbor(item, 1) != null;
        final calendarRange = itemCalendarRange(_trip?.startDate, item.day);
        return [
        PopupMenuItem(
          value: 'edit',
          child: ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text(l10n.tripEdit),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        // All widths, not just narrow (where the standalone button is gone):
        // one menu shape everywhere, and the desktop hover icon is invisible
        // at rest, so a labeled entry helps discovery.
        PopupMenuItem(
          value: 'maps',
          child: ListTile(
            leading: const Icon(Icons.map_outlined),
            title: Text(l10n.tripOpenInGoogleMaps),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        if (canUp)
          PopupMenuItem(
            value: 'up',
            child: ListTile(
              leading: const Icon(Icons.arrow_upward),
              title: Text(l10n.tripMoveUp),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        if (canDown)
          PopupMenuItem(
            value: 'down',
            child: ListTile(
              leading: const Icon(Icons.arrow_downward),
              title: Text(l10n.tripMoveDown),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        if (_sectionOf(item).length > 2)
          PopupMenuItem(
            value: 'reorder',
            child: ListTile(
              leading: const Icon(Icons.drag_indicator),
              title: Text(l10n.tripReorderSection),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        if (calendarRange != null) ...[
          PopupMenuItem(
            value: 'gcal',
            child: ListTile(
              leading: const Icon(Icons.event_outlined),
              title: Text(l10n.tripAddToGoogleCalendar),
              contentPadding: EdgeInsets.zero,
            ),
          ),
          PopupMenuItem(
            value: 'ics',
            enabled: !_isOffline,
            child: ListTile(
              leading: const Icon(Icons.event_available_outlined),
              title: Text(l10n.tripAddToAppleCalendar),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text(l10n.tripRemove),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        ];
      },
    );
  }


  /// The item this one would swap with when moved by [delta] (-1 up, +1 down),
  /// or null when the move would cross a day/hub/day-trip boundary.
  ItineraryItem? _moveNeighbor(ItineraryItem item, int delta) {
    final items = _trip?.items;
    if (items == null) return null;
    final idx = items.indexWhere((i) => i.id == item.id);
    if (idx < 0) return null;
    final ni = idx + delta;
    if (ni < 0 || ni >= items.length) return null;
    final other = items[ni];
    if (other.day != item.day) return null;
    if (_hubOf(other) != _hubOf(item)) return null;
    if ((other.dayTripFrom ?? '').trim() != (item.dayTripFrom ?? '').trim()) {
      return null;
    }
    return other;
  }


  /// All items sharing [item]'s day + hub + day-trip batch, in itinerary
  /// order — the same boundary _moveNeighbor enforces, so drag reordering
  /// can never move an item across a section either.
  List<ItineraryItem> _sectionOf(ItineraryItem item) {
    final items = _trip?.items ?? const <ItineraryItem>[];
    return [
      for (final i in items)
        if (i.day == item.day &&
            _hubOf(i) == _hubOf(item) &&
            (i.dayTripFrom ?? '').trim() == (item.dayTripFrom ?? '').trim())
          i,
    ];
  }


  /// Drag-and-drop reorder for one section (specs/itinerary-item-editing
  /// follow-up). The sheet reorders locally; Save maps the section's new
  /// order back onto the full item-id permutation and submits it through the
  /// same PUT /items/order path as Move up/down.
  Future<void> _reorderSection(ItineraryItem item) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    final trip = _trip;
    if (trip == null) return;
    final section = _sectionOf(item);
    if (section.length < 2) return;

    final newOrder = await showModalBottomSheet<List<ItineraryItem>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _ReorderSectionSheet(items: section),
    );
    if (newOrder == null || !mounted) return;

    // Splice the section's new order into the full ordering: walk the trip's
    // items and replace each section member slot with the next reordered id.
    final sectionIds = section.map((i) => i.id).toSet();
    var next = 0;
    final ids = <String>[
      for (final i in trip.items ?? const <ItineraryItem>[])
        if (sectionIds.contains(i.id)) newOrder[next++].id else i.id,
    ];
    try {
      await ref
          .read(tripsApiServiceProvider)
          .reorderItineraryItems(trip.id, ids);
      await _load();
    } catch (e) {
      _showSnack(l10n.tripReorderFailed(friendlyError(l10n, e)));
      await _load();
    }
  }


  Future<void> _moveItem(ItineraryItem item, int delta) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    final trip = _trip;
    final other = _moveNeighbor(item, delta);
    if (trip == null || other == null) return;
    final ids = (trip.items ?? const <ItineraryItem>[])
        .map((i) => i.id)
        .toList();
    final a = ids.indexOf(item.id);
    final b = ids.indexOf(other.id);
    ids[a] = other.id;
    ids[b] = item.id;
    try {
      await ref
          .read(tripsApiServiceProvider)
          .reorderItineraryItems(trip.id, ids);
      await _load();
    } catch (e) {
      _showSnack(l10n.tripReorderFailed(friendlyError(l10n, e)));
      await _load();
    }
  }


  Future<void> _deleteItem(ItineraryItem item) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    final trip = _trip;
    if (trip == null) return;
    try {
      await ref
          .read(tripsApiServiceProvider)
          .deleteItineraryItem(trip.id, item.id);
    } catch (e) {
      _showSnack(l10n.tripRemoveItemFailed(item.name, friendlyError(l10n, e)));
      return;
    }
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.tripRemovedItem(item.name)),
        action: SnackBarAction(
          label: l10n.tripUndo,
          onPressed: () => _undoDelete(trip.id, item),
        ),
      ),
    );
  }


  /// Undo = re-add through the normal add endpoint; the server slots the item
  /// back at the end of its day, which is close enough to where it was.
  Future<void> _undoDelete(String tripId, ItineraryItem item) async {
    final l10n = context.l10n;
    final body = <String, dynamic>{
      'name': item.name,
      if (item.placeId != null) 'place_id': item.placeId,
      if (item.address != null) 'address': item.address,
      if (item.latitude != 0 || item.longitude != 0) ...{
        'latitude': item.latitude,
        'longitude': item.longitude,
      },
      if (item.category != null) 'category': item.category,
      if (item.timeOfDay != null) 'time_of_day': item.timeOfDay,
      if (item.city != null) 'city': item.city,
      if (item.dayTripFrom != null) 'day_trip_from': item.dayTripFrom,
      if (item.day != null) 'day': item.day,
    };
    try {
      await ref.read(tripsApiServiceProvider).addItineraryItem(tripId, body);
      await _load();
    } catch (e) {
      _showSnack(l10n.tripRestoreItemFailed(item.name, friendlyError(l10n, e)));
    }
  }


  Future<void> _editItem(ItineraryItem item) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    final changes = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _EditItineraryItemSheet(item: item),
    );
    if (changes == null || changes.isEmpty) return;
    final trip = _trip;
    if (trip == null) return;
    try {
      await ref
          .read(tripsApiServiceProvider)
          .updateItineraryItem(trip.id, item.id, changes);
      await _load();
    } catch (e) {
      _showSnack(l10n.tripUpdateItemFailed(item.name, friendlyError(l10n, e)));
    }
  }


  /// Google Maps deep link for a place: prefer place_id, then coordinates, then a
  /// name/address text search.
  String _mapsUrl(ItineraryItem it) {
    const base = 'https://www.google.com/maps/search/?api=1';
    if (it.placeId != null && it.placeId!.isNotEmpty) {
      return '$base&query=${Uri.encodeComponent(it.name)}&query_place_id=${it.placeId}';
    }
    if (it.latitude != 0 || it.longitude != 0) {
      return '$base&query=${it.latitude},${it.longitude}';
    }
    return '$base&query=${Uri.encodeComponent('${it.name} ${it.address ?? ''}'.trim())}';
  }


  /// Day-header date, e.g. "Wed, Jul 15" (weekday + month + day); Spanish
  /// reorders to "mié, 15 jul" on its own.
  String _fmtDayHeader(DateTime d) => mmmed().format(d);

}

/// Small pill showing a place's part of day (Morning/Afternoon/Evening), tinted
/// by time so a day's rhythm is scannable at a glance.
class _TimeOfDayChip extends StatelessWidget {
  final String timeOfDay;

  /// Icon-only glyph for narrow layouts; the Tooltip carries the label (and
  /// doubles as the semantics label for screen readers).
  final bool compact;

  const _TimeOfDayChip({required this.timeOfDay, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final icon = switch (timeOfDay) {
      'morning' => Icons.wb_twilight,
      'afternoon' => Icons.wb_sunny_outlined,
      'evening' => Icons.nightlight_outlined,
      _ => Icons.schedule,
    };
    final label = _timeOfDayLabel(context.l10n, timeOfDay);
    final scheme = Theme.of(context).colorScheme;
    if (compact) {
      return Tooltip(
        message: label,
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, size: 14, color: scheme.onSecondaryContainer),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: scheme.onSecondaryContainer),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}


/// Bottom sheet for editing one itinerary item. Returns a map of only the
/// changed fields (the PATCH endpoint is a partial update), or null/empty on
/// cancel or no changes.
class _EditItineraryItemSheet extends StatefulWidget {
  final ItineraryItem item;
  const _EditItineraryItemSheet({required this.item});

  @override
  State<_EditItineraryItemSheet> createState() =>
      _EditItineraryItemSheetState();
}


class _EditItineraryItemSheetState extends State<_EditItineraryItemSheet> {
  late final TextEditingController _name;
  late final TextEditingController _city;
  late final TextEditingController _day;
  String? _category;
  String? _timeOfDay;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.item.name);
    _city = TextEditingController(text: widget.item.city ?? '');
    _day = TextEditingController(text: widget.item.day?.toString() ?? '');
    _category = widget.item.category;
    _timeOfDay = widget.item.timeOfDay;
  }

  @override
  void dispose() {
    _name.dispose();
    _city.dispose();
    _day.dispose();
    super.dispose();
  }

  void _save() {
    final changes = <String, dynamic>{};
    final name = _name.text.trim();
    if (name.isNotEmpty && name != widget.item.name) changes['name'] = name;
    final city = _city.text.trim();
    if (city.isNotEmpty && city != (widget.item.city ?? '')) {
      changes['city'] = city;
    }
    final day = int.tryParse(_day.text.trim());
    if (day != null && day >= 1 && day != widget.item.day) {
      changes['day'] = day;
    }
    if (_category != null && _category != widget.item.category) {
      changes['category'] = _category;
    }
    if (_timeOfDay != null && _timeOfDay != widget.item.timeOfDay) {
      changes['time_of_day'] = _timeOfDay;
    }
    Navigator.of(context).pop(changes);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.tripEditPlace, style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _name,
            decoration: InputDecoration(
              labelText: l10n.tripFieldName,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _city,
                  decoration: InputDecoration(
                    labelText: l10n.tripFieldCity,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              SizedBox(
                width: 90,
                child: TextField(
                  controller: _day,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: l10n.tripFieldDay,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: 8,
            children: [
              for (final c in const ['attraction', 'restaurant'])
                ChoiceChip(
                  label: Text(_categoryLabel(l10n, c)),
                  selected: _category == c,
                  onSelected: (sel) =>
                      setState(() => _category = sel ? c : _category),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: 8,
            children: [
              for (final t in const ['morning', 'afternoon', 'evening'])
                ChoiceChip(
                  label: Text(_timeOfDayLabel(l10n, t)),
                  selected: _timeOfDay == t,
                  onSelected: (sel) =>
                      setState(() => _timeOfDay = sel ? t : _timeOfDay),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.commonCancel),
              ),
              const SizedBox(width: AppSpacing.sm),
              FilledButton(onPressed: _save, child: Text(l10n.commonSave)),
            ],
          ),
        ],
      ),
    );
  }
}


/// Bottom sheet with a drag-and-drop list for one itinerary section. Pops
/// with the reordered items on Save, or null on dismiss.
class _ReorderSectionSheet extends StatefulWidget {
  final List<ItineraryItem> items;
  const _ReorderSectionSheet({required this.items});

  @override
  State<_ReorderSectionSheet> createState() => _ReorderSectionSheetState();
}


class _ReorderSectionSheetState extends State<_ReorderSectionSheet> {
  late List<ItineraryItem> _items;

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.items);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.tripReorderPlaces, style: theme.textTheme.titleLarge),
          const SizedBox(height: AppSpacing.xs),
          Text(
            l10n.tripReorderHint,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpacing.md),
          Flexible(
            child: ReorderableListView.builder(
              shrinkWrap: true,
              buildDefaultDragHandles: false,
              itemCount: _items.length,
              onReorder: (oldIndex, newIndex) {
                setState(() {
                  if (newIndex > oldIndex) newIndex--;
                  final moved = _items.removeAt(oldIndex);
                  _items.insert(newIndex, moved);
                });
              },
              itemBuilder: (context, i) {
                final item = _items[i];
                return ListTile(
                  key: ValueKey(item.id),
                  dense: true,
                  leading: Text('${i + 1}',
                      style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  title: Text(item.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: ReorderableDragStartListener(
                    index: i,
                    child: const Icon(Icons.drag_indicator),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.commonCancel),
              ),
              const SizedBox(width: AppSpacing.sm),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(_items),
                child: Text(l10n.tripSaveOrder),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
