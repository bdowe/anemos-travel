import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sliver_tools/sliver_tools.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/gradient_app_bar.dart';
import '../l10n/l10n.dart';
import '../models/trip.dart';
import '../models/itinerary_item.dart';
import '../models/accommodation.dart';
import '../models/booking_todo.dart';
import '../models/local_guide.dart';
import '../models/location.dart';
import '../models/location_timing.dart';
import '../models/route_request.dart';
import '../models/trip_segment.dart';
import '../providers/accommodations_provider.dart';
import '../providers/analytics_provider.dart';
import '../providers/transport_provider.dart';
import '../providers/trips_provider.dart';
import '../providers/recent_trip_provider.dart';
import '../utils/errors.dart';
import '../providers/booking_todos_provider.dart';
import '../providers/preferences_provider.dart';
import '../providers/api_client_provider.dart';
import '../providers/plan_provider.dart';
import '../providers/events_provider.dart';
import '../providers/weather_provider.dart';
import '../models/weather.dart';
import '../providers/ferries_provider.dart';
import '../providers/local_provider.dart';
import '../providers/shared_with_me_provider.dart';
import '../providers/trip_cache_provider.dart';
import '../providers/trip_review_provider.dart';
import '../providers/checklist_provider.dart';
import '../providers/budget_provider.dart';
import '../models/trip_finding.dart';
import '../models/budget.dart';
import '../navigation/app_nav.dart';
import '../services/trip_cache.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../utils/calendar_links.dart';
import '../utils/clothing_recs.dart';
import '../utils/date_formats.dart';
import '../utils/leg_parity.dart';
import '../utils/money_format.dart';
import '../utils/share_link.dart';
import '../utils/tracked_launch.dart';
import '../utils/trip_days.dart';
import '../utils/trip_format.dart';
import '../utils/trip_legs.dart';
import '../widgets/add_itinerary_item_dialog.dart';
import '../widgets/add_to_trip_sheet.dart';
import '../widgets/app_map.dart';
import '../widgets/booking_detail_row.dart';
import '../widgets/booking_sheets.dart';
import '../widgets/booking_todo_card.dart';
import '../widgets/budget_section.dart';
import '../widgets/checklist_section.dart';
import '../widgets/collapsible_section.dart';
import '../widgets/trip_review_section.dart';
import '../widgets/empty_state.dart';
import '../widgets/choice_chip_row.dart';
import '../widgets/event_card.dart';
import '../widgets/hover_reveal.dart';
import '../widgets/local_rec_card.dart';
import '../widgets/map_day_chips.dart';
import '../widgets/offline_banner.dart';
import '../widgets/source_links_card.dart';
import '../widgets/status_pill.dart';
import '../widgets/trip_map.dart';
import '../widgets/trip_refine_panel.dart';
import '../widgets/wear_recs.dart';
import 'flight_search_screen.dart';
import 'local_guide_detail_screen.dart';
import 'trip_detail_derivation.dart';
import 'trip_map_screen.dart';
import '../utils/snack.dart';

/// A geographic coordinate used to resolve an itinerary place to its nearest
/// bookable airport when the place name has no IATA match.
typedef _Coord = ({double lat, double lng});

/// Canonical group key for items whose locality can't be resolved. It keys the
/// collapse/header registries and gates refine/events/local sections, so it is
/// NEVER translated — only its display label is (specs/i18n-spanish). Now
/// canonically defined next to the shared leg split (utils/trip_legs.dart).
const _kOtherPlaces = kOtherPlacesLabel;

// The city-group/date-chip/booking-slot shapes ([CityGroup], [LegDateChip],
// [BookingSlot], [GroupedBookings]) and the label/filler helpers now live in
// trip_detail_derivation.dart with the pipeline that builds them.

// Canonical API values. These are sent to the server (or matched against
// server data), so they are NEVER translated — only their display labels are.
// 'local', 'unbooked', and 'bookings' are client-only lenses: locals' picks
// (items with a local_source_name credit), left-to-book booking rows, and the
// trip-wide all-bookings list (destination-filterable).
const _itemFilters = [
  'all',
  'attraction',
  'restaurant',
  'local',
  'unbooked',
  'bookings',
];

String _filterLabel(AppLocalizations l10n, String value) => switch (value) {
      'all' => l10n.tripFilterAll,
      'attraction' => l10n.tripFilterAttractions,
      'restaurant' => l10n.tripFilterRestaurants,
      'local' => l10n.tripFilterLocalPicks,
      'unbooked' => l10n.tripFilterUnbooked,
      'bookings' => l10n.tripBookingsLensFilterLabel,
      _ => value,
    };

String _categoryLabel(AppLocalizations l10n, String value) => switch (value) {
      'attraction' => l10n.tripCategoryAttraction,
      'restaurant' => l10n.tripCategoryRestaurant,
      _ => value,
    };

String _timeOfDayLabel(AppLocalizations l10n, String value) => switch (value) {
      'morning' => l10n.tripTimeMorning,
      'afternoon' => l10n.tripTimeAfternoon,
      'evening' => l10n.tripTimeEvening,
      _ => value,
    };

class TripDetailScreen extends ConsumerStatefulWidget {
  final String tripId;
  const TripDetailScreen({super.key, required this.tripId});

  @override
  ConsumerState<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends ConsumerState<TripDetailScreen>
    with WidgetsBindingObserver {
  Trip? _trip;
  bool _loading = true;
  String? _error;
  // Non-null while _trip is a cached copy served because the network was
  // unreachable (value = when the copy was saved). The screen is read-only
  // in this mode; a successful live load clears it.
  DateTime? _offlineSince;
  // In-page AI refinement panel (side dock on wide layouts, bottom sheet on
  // narrow ones); null target while closed.
  bool _panelOpen = false;
  RefineTarget? _refineTarget;
  String _itemFilter = 'all'; // one of _itemFilters
  // Destination chip selection inside the 'bookings' lens (null = All).
  // Reset on every lens change so the lens always opens at All; clamped in
  // _bookingsLensBody against the current leg labels (edits can stale it).
  String? _bookingsLensDestination;
  // Map day-chip selection; null = All (specs/today-mode). A ValueNotifier
  // so a day-chip tap rebuilds only the map card's ListenableBuilder, never
  // the whole screen. May hold a stale out-of-range day after an edit
  // shrinks the trip — readers clamp via _clampedDay (read-side, so build
  // never mutates state).
  final ValueNotifier<int?> _selectedDay = ValueNotifier<int?>(null);
  // Whether the map renders as the wide layout's pinned header (true) or the
  // phone layout's scroll-away tap-to-expand card (false). Assigned each
  // build from the body width; also feeds the Today-scroll chrome math.
  bool _mapPinned = true;
  // Body-width narrow flag (< kRailBreakpoint), assigned by the root
  // LayoutBuilder in build so the APP BAR and the body agree — MediaQuery
  // would report the window, which is ~81px wider than the body when the
  // nav rail shows (window 800-880 = wide window, narrow body). Strictly
  // < 800: the 800px test surface must stay on the desktop path.
  bool _narrow = false;
  // Today mode (specs/today-mode): the itinerary auto-scrolls to today's day
  // header at most once per screen visit, and only from loud load paths.
  final ScrollController _scroll = ScrollController();
  bool _autoScrolledToday = false;
  // Day set by a loud load, consumed by the first build that has the scroll
  // view on screen (the load's own setState still shows the loading spinner,
  // so the scroll can't be kicked off from there).
  int? _pendingTodayScroll;
  // Stable identities for the pinned headers so the Today scroller can find
  // their render objects. Days share the `'$cityKey#$day'` scheme with
  // _collapsedDays; cities are keyed by run key (group.key) like
  // _expandedCities.
  final Map<String, GlobalKey> _dayHeaderKeys = {};
  final Map<String, GlobalKey> _cityHeaderKeys = {};
  // Position of the place focused via a map pin / list tap. A ValueNotifier
  // consumed by the map card's ListenableBuilder and each item tile, so
  // selecting a place rebuilds the map subtree + visible tiles — never the
  // whole screen, and (via TripMap's marker cache) never re-clusters.
  final ValueNotifier<int?> _selectedPosition = ValueNotifier<int?>(null);
  List<BookingTodo> _bookingTodos = [];
  // Mutable copies of the trip's stays/segments, like _bookingTodos, so the
  // booked checkboxes can flip optimistically without rebuilding the
  // immutable Trip. Legacy draft (auto=true) rows still arrive in payloads;
  // every consumer filters on !auto.
  List<Accommodation> _stays = [];
  List<TripSegment> _segments = [];
  // City groups the user opened, keyed by run key (group.key, `#2`-suffixed
  // on revisits): empty => all collapsed, the default view (place + dates
  // headers only). A sole group is seeded open once (_citySeedConsumed) so a
  // one-city trip isn't an empty screen; late-arriving groups (refine adds a
  // city mid-session) start collapsed by absence. Days stay inverted —
  // _collapsedDays empty => open within an expanded group, keyed
  // "<cityKey>#<day>" since day numbers repeat across cities.
  final Set<String> _expandedCities = {};
  final Set<String> _collapsedDays = {};
  bool _citySeedConsumed = false;
  // Trailing sections (Packing/Budget/Trip health) render as collapsed
  // one-line summaries; this holds the ones the user opened. Session-only,
  // like the city/day sets, and held HERE (not in the section widgets) so
  // expansion survives silent refreshes and the offline-banner reparent.
  final Set<String> _expandedSections = {};
  String?
      _homeAirport; // traveler's saved home airport (IATA), for outbound/return flights
  // todo_key -> flight leg, so a transport booking item can open Find Flights
  // prefilled. Coords resolve an endpoint to its nearest airport when the city
  // label has no IATA match (e.g. a village like Imerovigli -> Santorini/JTR).
  Map<String,
          ({
            String origin,
            String destination,
            String? date,
            _Coord? originCoord,
            _Coord? destCoord
          })> _flightLegs =
      {};
  // todo_key -> ferry leg (Greek port<->port), so the booking item opens the
  // Ferryhopper search for that route instead of a flight.
  Map<String, ({String origin, String destination, String? date})> _ferryLegs =
      {};
  // Per-leg travel timings keyed by the source item's position (the leg leaving
  // that item, to the next item in itinerary order). Empty until computed and on
  // any failure — travel times are an enhancement and never block the itinerary.
  Map<int, LocationTiming> _travelByPos = {};

  // ── Derivation memo (specs/perf-program, Wave 4 PR1) ──────────────────
  // The whole per-build pipeline (filtered items, city groups, leg ranges,
  // date chips, booking slots, map inputs) lives in TripDerivation
  // (trip_detail_derivation.dart), computed once per input signature.

  TripDerivation? _cachedDerivation;

  /// Bumped by any IN-PLACE mutation of a derivation input, which
  /// [_derive]'s identity checks cannot see. `_reorderBatchInline` is the
  /// only such site; every other mutation path replaces its input objects
  /// wholesale, so identity alone invalidates the memo.
  int _itemOrderEpoch = 0;

  /// THE access point for derived trip state — build and the non-build
  /// readers (todo derivation, pin taps, scroll math, full-screen map) all
  /// go through here, so they can never disagree. Returns the cached
  /// derivation when the input signature still [TripDerivation.matches];
  /// recomputes and caches otherwise. No explicit invalidation calls exist
  /// anywhere — see [_itemOrderEpoch] for the one non-identity signal.
  TripDerivation _derive(Trip trip) {
    final l10n = context.l10n;
    final cached = _cachedDerivation;
    if (cached != null &&
        cached.matches(
          trip: trip,
          bookingTodos: _bookingTodos,
          stays: _stays,
          segments: _segments,
          travelByPos: _travelByPos,
          itemFilter: _itemFilter,
          l10n: l10n,
          itemOrderEpoch: _itemOrderEpoch,
        )) {
      return cached;
    }
    return _cachedDerivation = TripDerivation.compute(
      trip: trip,
      bookingTodos: _bookingTodos,
      stays: _stays,
      segments: _segments,
      travelByPos: _travelByPos,
      itemFilter: _itemFilter,
      l10n: l10n,
      itemOrderEpoch: _itemOrderEpoch,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusPoll?.cancel();
    _scroll.dispose();
    _selectedDay.dispose();
    _selectedPosition.dispose();
    super.dispose();
  }

  // ── Freshness polling (specs/shared-trip-freshness) ───────────────────
  // Shared trips poll the cheap /status endpoint and silently refresh when
  // someone else edited. Only runs foregrounded, online, on shared trips.

  Timer? _statusPoll;
  static const _statusPollInterval = Duration(seconds: 25);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _syncStatusPolling();
      _statusTick(); // catch up on edits made while backgrounded
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _statusPoll?.cancel();
      _statusPoll = null;
    }
  }

  /// (Re)starts or stops the poll timer to match the loaded trip. Owners
  /// poll when the trip has co-planners (`shared`); editors and viewer
  /// follows always.
  void _syncStatusPolling() {
    final trip = _trip;
    final want = trip != null &&
        !_isOffline &&
        (!trip.isOwner || (trip.shared ?? false));
    if (want) {
      _statusPoll ??=
          Timer.periodic(_statusPollInterval, (_) => _statusTick());
    } else {
      _statusPoll?.cancel();
      _statusPoll = null;
    }
  }

  Future<void> _statusTick() async {
    final trip = _trip;
    // Skip while the refine panel streams (its trip_updated events already
    // drive _refresh) or a refresh is in flight.
    if (trip == null || _isOffline || _panelOpen || _refreshFuture != null) {
      return;
    }
    try {
      final status =
          await ref.read(tripsApiServiceProvider).getTripStatus(trip.id);
      if (!mounted) return;
      final loaded = DateTime.tryParse(trip.updatedAt);
      if (loaded != null && status.updatedAt.isAfter(loaded)) {
        await _refresh();
      }
    } catch (_) {
      // Background poll: never surface errors or flip offline mode.
    }
  }

  Future<void> _load({bool silent = false}) async {
    // Silent mode refreshes an already-displayed trip in place — no
    // full-screen spinner, no error page — so the refine panel (and the
    // conversation streaming inside it) stays mounted. First load always
    // takes the loud path.
    final quiet = silent && _trip != null;
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final trip =
          await ref.read(tripsApiServiceProvider).getTrip(widget.tripId);
      if (mounted) {
        // Transition telemetry (specs/server-leg-dates): daily dogfooding is
        // the parity monitor for the server legs payload vs the local
        // derivation this screen still renders. Zero expected volume;
        // fire-and-forget; deleted with the fallback at stage 6a.
        final parityDiffs = legParityMismatches(trip);
        if (parityDiffs.isNotEmpty) {
          unawaited(ref.read(analyticsApiServiceProvider).recordLegsParityMismatch(
              tripId: trip.id, details: parityDiffs));
        }
        // Write-through for offline viewing; fire-and-forget (never throws)
        // so the online path is unaffected.
        unawaited(ref.read(tripCacheProvider).writeTrip(trip));
        setState(() {
          _trip = trip;
          _bookingTodos = trip.bookingTodos ?? [];
          _stays = trip.accommodations ?? [];
          _segments = trip.segments ?? [];
          _offlineSince = null; // live data — leave offline mode if we were in it
          // Today mode fires only from loud loads — never from a silent
          // refresh, which shares this success path (PR #51/#53 invariants).
          if (!silent) _maybeAutoScrollToday(trip);
        });
        // Remember this as the most recently viewed trip (home screen tile).
        ref.read(recentTripProvider.notifier).record(
              trip.id,
              trip.title,
              dateRange: tripDateRange(trip.startDate, trip.endDate),
              status: trip.status,
            );
      }
      // The travel-time computation needs only the trip, while the booking-todo
      // sync must wait for the home airport from preferences (the checklist
      // derives the outbound and return flights from it; no-op / null for
      // anonymous sessions). Run the two chains concurrently and join, so
      // _load's completion, error, and offline semantics are unchanged — both
      // helpers self-guard with mounted checks and swallow their own errors.
      Future<void> syncTodosAfterPrefs() async {
        await ref.read(preferencesProvider.notifier).loadIfNeeded();
        _homeAirport = ref.read(preferencesProvider).prefs?.homeAirport;
        if (mounted && (trip.items ?? const []).isNotEmpty) {
          await _syncBookingTodos(trip);
        }
      }

      await Future.wait([
        if (mounted && (trip.items ?? const []).isNotEmpty)
          _computeTravelTimes(trip),
        syncTodosAfterPrefs(),
      ]);
    } catch (e) {
      // Loud path + network-level failure: fall back to the cached copy and
      // render it read-only. HTTP errors (403/404/500) never reach here —
      // isNetworkError excludes them — so a revoked or deleted trip can't
      // resurrect from a stale copy.
      if (mounted && !quiet && TripCache.isNetworkError(e)) {
        final cached = await ref.read(tripCacheProvider).readTrip(widget.tripId);
        if (cached != null && mounted) {
          setState(() {
            _trip = cached.trip;
            _bookingTodos = cached.trip.bookingTodos ?? [];
            _stays = cached.trip.accommodations ?? [];
            _segments = cached.trip.segments ?? [];
            _offlineSince = cached.savedAt;
            _error = null;
            // Opening a live trip while offline is Today mode's prime use
            // case — the cached copy scrolls to today just like a live load.
            if (!silent) _maybeAutoScrollToday(cached.trip);
          });
          return; // finally still clears _loading
        }
      }
      // Quiet path + network-level failure on the trip already on screen
      // (pull-to-refresh while offline): flip into offline mode — banner +
      // mutation guards — instead of completing the indicator silently with
      // edits still armed. The on-screen trip is at least as fresh as the
      // cache (every successful load writes through), so keep it; only the
      // offline state changes. Skipped while the refine panel is open: its
      // quiet refreshes are driven by trip_updated events on a live SSE
      // stream, so declaring the app offline mid-conversation would
      // contradict the working connection and strand the panel (which is
      // never allowed to observe offline mode — see _openRefine). Quiet
      // NON-network failures stay fully silent: a transient server error
      // during a streaming turn must not flash error UI (PR #51/#53).
      if (mounted &&
          quiet &&
          !_panelOpen &&
          _trip?.id == widget.tripId &&
          TripCache.isNetworkError(e)) {
        final cached =
            await ref.read(tripCacheProvider).readTrip(widget.tripId);
        if (mounted) {
          // The cache entry's timestamp is when the on-screen data was
          // fetched (write-through); fall back to "now" on a cache miss.
          setState(() => _offlineSince = cached?.savedAt ?? DateTime.now());
        }
        return;
      }
      if (mounted && !quiet) setState(() => _error = e.toString());
    } finally {
      if (mounted && !quiet) setState(() => _loading = false);
      if (mounted) _syncStatusPolling();
    }
  }

  bool get _isOffline => _offlineSince != null;

  /// Viewer follows (access == 'viewer') see the trip without any edit
  /// affordances — the server 404s their mutations anyway.
  bool get _readOnly => !(_trip?.canEdit ?? true);

  /// Belt-and-braces offline gate at the top of every mutation method. The
  /// primary affordances are also visually disabled/hidden while offline;
  /// this covers deep entry points (item menus, todo cards, per-day refine
  /// icons) without touching their widget subtrees.
  bool _guardOffline() {
    if (!_isOffline) return false;
    _showSnack(context.l10n.tripOfflineGuard);
    return true;
  }

  bool _refreshQueued = false;
  Future<void>? _refreshFuture;

  /// Silent in-place reload with trailing coalescing. The server can emit
  /// several `trip_updated` events in one streaming turn; a bump that lands
  /// mid-fetch queues exactly one more pass so the final state always
  /// reflects the last patch. Concurrent user-driven `_load()` calls
  /// (add/edit/delete flows) are a pre-existing last-write-wins race and are
  /// not handled here.
  Future<void> _refresh() {
    final inFlight = _refreshFuture;
    if (inFlight != null) {
      _refreshQueued = true;
      return inFlight;
    }
    final future = () async {
      do {
        _refreshQueued = false;
        await _load(silent: true);
      } while (mounted && _refreshQueued);
      _refreshFuture = null;
    }();
    _refreshFuture = future;
    return future;
  }

  // ── Today mode (specs/today-mode) ─────────────────────────────────────

  /// Content width cap on wide layouts. Applied as a computed symmetric
  /// horizontal gutter substituted for the 16px sliver padding — never as a
  /// wrapper OUTSIDE the body LayoutBuilder, whose maxWidth feeds the
  /// map-pinning and refine-dock breakpoints (a constraining wrapper would
  /// starve them and the map would never pin).
  static const double _contentMaxWidth = 900;

  // ── City-header date-chip columns ─────────────────────────────────────
  // Every header's chip renders inside one shared width measured per build
  // ([_dateChipWidth]), so calendar icons, range starts, and nights suffixes
  // form columns across rows.

  /// Calendar icon size and trailing gap inside the chip — consumed by both
  /// the render and the measurement ([_chipIconSpan]) so they cannot drift.
  static const double _chipIconSize = 14;
  static const double _chipIconGap = 4;
  static const double _chipIconSpan = _chipIconSize + _chipIconGap;

  /// Minimum gap between the range text and the nights suffix. Also the
  /// error budget for TextPainter-vs-Text measurement divergence: a chip can
  /// only spuriously ellipsize if measurement undershoots by more than this.
  static const double _chipInnerGap = 8;

  /// Pathological ceiling (kept from the pre-column layout): real localized
  /// chips measure well under it; absurd text scales ellipsize instead of
  /// overflowing the header row. Never scale this with the textScaler — the
  /// chip is a rigid child of the header row and a scaled cap could exceed a
  /// phone row's width.
  static const double _chipMaxWidth = 200;

  /// Pinned-header heights, shared by the build method and the Today scroll
  /// math so the two can never drift apart.
  static const double _mapHeaderHeight =
      12 + 340 + 12; // top gap + map + bottom gap
  /// Map card height on phones, where the map scrolls away instead of
  /// pinning (a preview — the full-screen map is one tap away).
  static const double _mapHeightNarrow = 180;
  // Itinerary title row (36) + bottom padding (8) + breathing room (4); the
  // category filter lives in a popup menu inside the title row, so the
  // header is one fixed-height row whether or not the trip has items.
  static const double _listHeaderHeight = 48;

  /// Combined height of the chrome pinned above the itinerary slivers: the
  /// map header (when it renders AND is pinned — on phones the map scrolls
  /// away, so it never rests above a target header) plus the itinerary
  /// title header.
  double _pinnedChrome(Trip trip) {
    final mapShown = _derive(trip).mapShown;
    return ((_mapPinned && mapShown) ? _mapHeaderHeight : 0) +
        _listHeaderHeight;
  }

  /// Measured height of the pinned city header above [dayKey]'s section
  /// (0 when it isn't laid out yet).
  double _cityHeaderHeight(String dayKey) {
    final cityKey = dayKey.substring(0, dayKey.lastIndexOf('#'));
    final box = _cityHeaderKeys[cityKey]?.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size.height : 0;
  }

  /// One-shot Today trigger, called inside the setState of the loud load
  /// paths (live success and cached-offline fallback) so the map's today
  /// chip preselection lands in the same frame as the trip. Never called
  /// from silent refreshes; a no-op once fired, while the refine panel is
  /// open, or when the trip is undated/past/future or has no day tags.
  void _maybeAutoScrollToday(Trip trip) {
    if (_autoScrolledToday || _panelOpen) return;
    final today = tripDayOn(trip.startDate, trip.endDate, DateTime.now());
    if (today == null) return;
    if (!(trip.items ?? const <ItineraryItem>[]).any((i) => i.day != null)) {
      return;
    }
    _autoScrolledToday = true;
    _selectedDay.value = today; // map day-chip preselect
    // The scroll itself waits for the first build that actually shows the
    // scroll view: this setState still renders the loading spinner (the
    // loud path clears _loading later, in its finally), so a post-frame
    // callback scheduled here could fire before the CustomScrollView exists.
    _pendingTodayScroll = today;
  }

  /// Scrolls the itinerary so [day]'s header rests just below the pinned
  /// chrome (map + title + city header). Missing headers fall back to the
  /// nearest prior day, then the nearest following; a collapsed city/day is
  /// expanded first, and a bookings lens (which swaps the city groups out
  /// entirely, so no day header could ever build) is exited back to the full
  /// itinerary — the Today chip and health day-links read as "show me that
  /// day". Pure view work — safe offline and with the panel open.
  void _scrollToDay(int day) {
    final dayKey = _resolveDayHeaderKey(day);
    if (dayKey == null) return;
    final cityKey = dayKey.substring(0, dayKey.lastIndexOf('#'));
    final inBookingsLens =
        _itemFilter == 'unbooked' || _itemFilter == 'bookings';
    if (inBookingsLens ||
        !_expandedCities.contains(cityKey) ||
        _collapsedDays.contains(dayKey)) {
      setState(() {
        if (inBookingsLens) {
          _itemFilter = 'all';
          _bookingsLensDestination = null;
        }
        _expandedCities.add(cityKey);
        _collapsedDays.remove(dayKey);
      });
      // Continue once the expanded section has laid out.
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _scrollToDayHeader(dayKey));
      return;
    }
    _scrollToDayHeader(dayKey);
  }

  /// The registry key of the day header [day] should scroll to: the first
  /// (build-order) header for that exact day, else the nearest prior day
  /// with a header, else the nearest following. Candidates come from the
  /// derivation's [TripDerivation.liveDayKeys] — the current groups,
  /// collapsed ones included (still reachable because [_scrollToDay] expands
  /// them first) — so days removed by an edit can never linger as phantom
  /// targets.
  String? _resolveDayHeaderKey(int day) {
    final trip = _trip;
    if (trip == null) return null;
    String? prior;
    String? next;
    int? priorDay;
    int? nextDay;
    for (final key in _derive(trip).liveDayKeys) {
      final hashAt = key.lastIndexOf('#');
      final d = int.tryParse(key.substring(hashAt + 1));
      if (d == null) continue;
      if (d == day) return key;
      if (d < day && (priorDay == null || d > priorDay)) {
        priorDay = d;
        prior = key;
      }
      if (d > day && (nextDay == null || d < nextDay)) {
        nextDay = d;
        next = key;
      }
    }
    return prior ?? next;
  }

  /// Offset-reveal scroll to [dayKey]'s header (specs/today-mode plan.md,
  /// D1): `ensureVisible` is unreliable under SliverPinnedHeader /
  /// MultiSliver, so compute the reveal offset, subtract everything pinned
  /// above the header's resting slot, animate, then run exactly one
  /// correction pass against the header's actual on-screen position.
  Future<void> _scrollToDayHeader(String dayKey) async {
    final trip = _trip;
    if (!mounted || trip == null || !_scroll.hasClients) return;
    final target = _dayHeaderKeys[dayKey]?.currentContext?.findRenderObject();
    if (target == null || !target.attached) return;
    final viewport = RenderAbstractViewport.maybeOf(target);
    if (viewport == null) return;
    final resting = _pinnedChrome(trip) + _cityHeaderHeight(dayKey);
    final reveal = viewport.getOffsetToReveal(target, 0).offset - resting;
    final offset = reveal.clamp(0.0, _scroll.position.maxScrollExtent);
    await _scroll.animateTo(offset,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic);
    if (!mounted || !_scroll.hasClients) return;
    // One correction pass (no loops chasing layout): late-built slivers can
    // shift the estimate, so measure where the header actually landed and
    // jump the residual. A header pinned in its slot measures exactly at
    // the desired dy, so this never fights the pin.
    final box = _dayHeaderKeys[dayKey]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    final vp = RenderAbstractViewport.maybeOf(box);
    if (vp == null) return;
    // Header dy in viewport coordinates vs. its resting slot below the
    // pinned chrome.
    final actual = box.localToGlobal(Offset.zero, ancestor: vp).dy;
    final delta = actual - (_pinnedChrome(trip) + _cityHeaderHeight(dayKey));
    if (delta.abs() > 2) {
      _scroll.jumpTo((_scroll.offset + delta)
          .clamp(0.0, _scroll.position.maxScrollExtent));
    }
  }

  /// Pushes the itinerary-derived booking checklist to the server, which upserts
  /// auto-TODOs (preserving booked state) and prunes legs no longer in the trip.
  Future<void> _syncBookingTodos(Trip trip) async {
    try {
      final todos = await ref
          .read(bookingTodosApiServiceProvider)
          .syncTodos(trip.id, _deriveTodos(trip));
      if (mounted) setState(() => _bookingTodos = todos);
    } catch (_) {
      // Non-fatal: keep whatever booking todos came with the trip.
    }
  }

  /// The trip's stated non-flight travel mode ('car'|'train'|'bus'|'ferry')
  /// when set, else null. Such trips derive their legs in that mode with
  /// Rome2Rio route links instead of flight defaults; flight/mixed and unset
  /// keep the legacy Greek-ferry-else-flight behavior.
  static String? _groundModeOf(Trip trip) {
    final tm = trip.travelMode;
    return (tm == 'car' || tm == 'train' || tm == 'bus' || tm == 'ferry')
        ? tm
        : null;
  }

  static IconData _travelModeIcon(String? mode) {
    switch (mode) {
      case 'car':
        return Icons.directions_car;
      case 'train':
        return Icons.train;
      case 'bus':
        return Icons.directions_bus;
      case 'ferry':
        return Icons.directions_boat;
      case 'mixed':
        return Icons.alt_route;
      case 'flight':
        return Icons.flight;
      default:
        return Icons.explore_outlined; // unset: "how are you traveling?"
    }
  }

  static String _travelModeLabel(AppLocalizations l10n, String? mode) {
    switch (mode) {
      case 'car':
        return l10n.tripTravelModeDriving;
      case 'train':
        return l10n.tripTravelModeByTrain;
      case 'bus':
        return l10n.tripTravelModeByBus;
      case 'ferry':
        return l10n.tripTravelModeByFerry;
      case 'mixed':
        return l10n.tripTravelModeMixed;
      case 'flight':
        return l10n.tripTravelModeFlying;
      default:
        return l10n.tripTravelModeUnset;
    }
  }

  /// Computes per-leg travel times for the itinerary in its existing display
  /// order by calling /optimize-route in preserve-order mode (no reordering).
  /// Results are keyed by the source item's position; failures leave the map
  /// empty so the itinerary still renders.
  Future<void> _computeTravelTimes(Trip trip) async {
    final items = trip.items ?? const <ItineraryItem>[];
    final withCoords =
        items.where((i) => i.latitude != 0 || i.longitude != 0).length;
    if (withCoords < 2) return;
    try {
      final locations = [
        for (final it in items)
          Location(
            id: it.id,
            name: it.name,
            placeId: it.placeId,
            address: it.address,
            // (0,0) is the "no location" sentinel (e.g. manually added places
            // without a Places match) — send null so the optimizer skips the
            // coordinate rather than routing via the Gulf of Guinea.
            latitude:
                it.latitude == 0 && it.longitude == 0 ? null : it.latitude,
            longitude:
                it.latitude == 0 && it.longitude == 0 ? null : it.longitude,
            category: it.category,
          ),
      ];
      final resp = await ref.read(apiClientProvider).optimizeRoute(
            RouteRequest(
              locations: locations,
              returnToStart: false,
              preserveOrder: true,
            ),
          );
      final timings = resp.locationTimings;
      final map = <int, LocationTiming>{};
      for (var i = 0; i < items.length && i < timings.length; i++) {
        map[items[i].position] = timings[i];
      }
      if (mounted) setState(() => _travelByPos = map);
    } catch (_) {
      // Non-fatal: leave travel times empty.
    }
  }

  /// Builds the auto-TODO payload from the itinerary's location groups: a stay
  /// per city (with its dates) and a transport leg between consecutive cities.
  /// Dates come from [visibleLegRanges], so stay check-ins, inter-city leg
  /// dates, and the header chips all agree — including squeezed legs, which
  /// read as a zero-night stop at their arrival.
  List<Map<String, dynamic>> _deriveTodos(Trip trip) {
    final ranges = _derive(trip).visibleRanges;
    final todos = <Map<String, dynamic>>[];
    final legs = <String,
        ({
          String origin,
          String destination,
          String? date,
          _Coord? originCoord,
          _Coord? destCoord
        })>{};
    final ferryLegs =
        <String, ({String origin, String destination, String? date})>{};
    var pos = 0;
    final home = _homeAirport;
    final hasHome = home != null && home.isNotEmpty && ranges.isNotEmpty;
    final ground = _groundModeOf(trip);

    // Adds a transport (flight) todo and records its leg so the booking item can
    // open Find Flights prefilled. Coords (when known) resolve an endpoint to its
    // nearest airport if the city label itself has no IATA match.
    void addFlight(String origin, String destination, DateTime? when,
        {_Coord? originCoord, _Coord? destCoord}) {
      final date = when == null ? null : _fmt(when);
      final key =
          'transport:${origin.toLowerCase()}>>${destination.toLowerCase()}';
      todos.add({
        'kind': 'transport',
        'todo_key': key,
        'title': '$origin → $destination',
        if (when != null) 'subtitle': _fmtShortDt(when),
        'provider': 'google_flights',
        'position': pos++,
        'origin': origin,
        'destination': destination,
        if (date != null) 'depart_date': date,
        'passengers': 1,
      });
      legs[key] = (
        origin: origin,
        destination: destination,
        date: date,
        originCoord: originCoord,
        destCoord: destCoord,
      );
    }

    // Adds a transport (ferry) todo for a Greek port<->port leg and records it so
    // the booking item opens the Ferryhopper search for that route.
    void addFerry(String origin, String destination, DateTime? when) {
      final date = when == null ? null : _fmt(when);
      final key =
          'transport:${origin.toLowerCase()}>>${destination.toLowerCase()}';
      todos.add({
        'kind': 'transport',
        'todo_key': key,
        'title': '$origin → $destination',
        if (when != null) 'subtitle': _fmtShortDt(when),
        'provider': 'ferry',
        'position': pos++,
        'origin': origin,
        'destination': destination,
        if (date != null) 'depart_date': date,
        'passengers': 1,
      });
      ferryLegs[key] = (origin: origin, destination: destination, date: date);
    }

    // Adds a ground transport todo (car/train/bus trip) that opens a Rome2Rio
    // route search. Deliberately NOT registered in [legs]/[ferryLegs]: the card
    // then opens the server-built search_url with no "Find flights" override.
    void addGround(String origin, String destination, DateTime? when) {
      final date = when == null ? null : _fmt(when);
      final key =
          'transport:${origin.toLowerCase()}>>${destination.toLowerCase()}';
      todos.add({
        'kind': 'transport',
        'todo_key': key,
        'title': '$origin → $destination',
        if (when != null) 'subtitle': _fmtShortDt(when),
        'provider': 'rome2rio',
        'position': pos++,
        'origin': origin,
        'destination': destination,
        if (date != null) 'depart_date': date,
        'passengers': 1,
      });
    }

    // A leg between two Greek ports/islands (incl. Athens/Piraeus) is a ferry;
    // a stated ground travel mode makes every other leg ground; otherwise the
    // long-haul default is a flight.
    void addLeg(String origin, String destination, DateTime? when,
        {_Coord? originCoord, _Coord? destCoord}) {
      if (_isGreekIsland(origin) && _isGreekIsland(destination)) {
        addFerry(origin, destination, when);
      } else if (ground != null) {
        addGround(origin, destination, when);
      } else {
        addFlight(origin, destination, when,
            originCoord: originCoord, destCoord: destCoord);
      }
    }

    // Outbound: home airport -> first city, on the first group's start (the
    // trip's start date via the first-leg anchor, unless a confirmed stay
    // overrides it).
    if (hasHome) {
      if (ground != null) {
        addGround(home, ranges.first.label, ranges.first.start);
      } else {
        addFlight(home, ranges.first.label, ranges.first.start,
            destCoord: ranges.first.coord);
      }
    }

    for (var i = 0; i < ranges.length; i++) {
      final r = ranges[i];
      final label = r.label;
      final start = r.start;
      final checkIn = start == null ? null : _fmt(start);
      final checkOut = r.end == null ? null : _fmt(r.end!);
      todos.add({
        'kind': 'stay',
        'todo_key': 'stay:${label.toLowerCase()}',
        'title': 'Stay in $label',
        if (start != null && r.end != null)
          'subtitle': formatShortRange(start, r.end!),
        'provider': 'airbnb',
        'position': pos++,
        'destination': label,
        if (checkIn != null) 'depart_date': checkIn,
        if (checkOut != null) 'return_date': checkOut,
        'guests': 1,
      });
      if (i < ranges.length - 1) {
        addLeg(label, ranges[i + 1].label, r.end,
            originCoord: r.coord, destCoord: ranges[i + 1].coord);
      }
    }

    // Return: last city -> home airport, on the trip's end date.
    if (hasHome) {
      if (ground != null) {
        addGround(ranges.last.label, home, ranges.last.end);
      } else {
        addFlight(ranges.last.label, home, ranges.last.end,
            originCoord: ranges.last.coord);
      }
    }

    _flightLegs = legs;
    _ferryLegs = ferryLegs;
    return todos;
  }

  // The per-city booking-slot partition lives in
  // [TripDerivation.groupedBookings] (trip_detail_derivation.dart).

  /// The one "Booked" writer: flips the todo and (when the slot has one) the
  /// matched confirmed record in lockstep, so every reader of either flag —
  /// checklist rows, calendar/.ics export, print packet — agrees with the
  /// single visible checkbox. Optimistic on all touched lists; any failure
  /// rolls every list back (a partial server success self-heals on the next
  /// toggle or sync).
  Future<void> _setRowBooked(bool booked,
      {BookingTodo? todo, Accommodation? stay, TripSegment? segment}) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    final prevTodos = _bookingTodos;
    final prevStays = _stays;
    final prevSegments = _segments;
    setState(() {
      if (todo != null) {
        _bookingTodos = [
          for (final t in _bookingTodos)
            if (t.id == todo.id) t.copyWith(booked: booked) else t,
        ];
      }
      if (stay != null) {
        _stays = [
          for (final a in _stays)
            if (a.id == stay.id) a.copyWith(booked: booked) else a,
        ];
      }
      if (segment != null) {
        _segments = [
          for (final s in _segments)
            if (s.id == segment.id) s.copyWith(booked: booked) else s,
        ];
      }
    });
    try {
      await Future.wait<void>([
        if (todo != null)
          ref
              .read(bookingTodosApiServiceProvider)
              .setBooked(widget.tripId, todo.id, booked),
        if (stay != null)
          ref
              .read(accommodationsApiServiceProvider)
              .update(widget.tripId, stay.id, {'booked': booked}),
        if (segment != null)
          ref
              .read(transportApiServiceProvider)
              .updateSegment(widget.tripId, segment.id, {'booked': booked}),
      ]);
    } catch (e) {
      if (mounted) {
        setState(() {
          _bookingTodos = prevTodos;
          _stays = prevStays;
          _segments = prevSegments;
        });
      }
      _showSnack(l10n.tripUpdateFailed(friendlyError(l10n, e)));
    }
  }

  /// Persists a drag-reorder of the Bookings section's residual "Other" cards.
  /// Optimistic: residual display order derives from _bookingTodos list order
  /// (see _groupedBookings), so move the residual entries to the tail in their
  /// new order — grouped todos are slot-matched by key, so nothing else shifts.
  Future<void> _reorderResidual(
      List<BookingTodo> residual, int oldIndex, int newIndex) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    if (newIndex > oldIndex) newIndex--;
    if (newIndex == oldIndex) return;
    final newOrder = List.of(residual);
    newOrder.insert(newIndex, newOrder.removeAt(oldIndex));
    final residualIds = {for (final t in residual) t.id};
    final prev = _bookingTodos;
    setState(() {
      _bookingTodos = [
        for (final t in _bookingTodos)
          if (!residualIds.contains(t.id)) t,
        ...newOrder,
      ];
    });
    try {
      await ref
          .read(bookingTodosApiServiceProvider)
          .reorderTodos(widget.tripId, [for (final t in newOrder) t.id]);
    } catch (e) {
      if (mounted) setState(() => _bookingTodos = prev);
      _showSnack(l10n.tripReorderFailed(friendlyError(l10n, e)));
    }
  }

  /// The residual booking-todo cards (the Bookings section's "Other"
  /// sub-group): todos that didn't match a city group. City-matched todos
  /// render embedded inside their city groups instead. Only called with a
  /// non-empty [residual] — the section hides the sub-group otherwise.
  Widget _residualBookingsList(List<BookingTodo> residual, ThemeData theme) {
    final l10n = context.l10n;
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      buildDefaultDragHandles: false,
      itemCount: residual.length,
      onReorder: (oldIndex, newIndex) =>
          _reorderResidual(residual, oldIndex, newIndex),
      itemBuilder: (context, i) {
        final todo = residual[i];
        // Drag stays on all widths here: for residual custom bookings the
        // handle is the ONLY reorder mechanism (no kebab move entries).
        final canDrag = !_readOnly && !_isOffline && residual.length > 1;
        return Padding(
          key: ValueKey(todo.id),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: BookingTodoCard(
            todo: todo,
            onBookedChanged: (v) => _setRowBooked(v, todo: todo),
            onOpen: _openCallbackFor(todo),
            openLabelOverride: _flightLegs.containsKey(todo.todoKey)
                ? l10n.tripFindFlights
                : null,
            onEdit: todo.auto ? null : () => _editTodo(todo),
            onDelete: todo.auto ? null : () => _deleteTodo(todo),
            dragHandle: canDrag
                ? ReorderableDragStartListener(
                    index: i,
                    child: Icon(
                      Icons.drag_indicator,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  )
                : null,
          ),
        );
      },
    );
  }

  /// "Add details…" on an inline booking row: promotes the todo to a
  /// confirmed accommodation/segment via the existing add-sheets, prefilled
  /// from the todo. Confirmed records are what viewers see and what calendar
  /// export, the Tonight caption, and map stay pins read — this is the
  /// one-tap replacement for the retired Suggested-draft "Keep" flow. The
  /// next drafts sync sees the leg covered by a confirmed row and prunes its
  /// shadow draft server-side. Deliberately does NOT mark the todo booked —
  /// booking state stays a separate, explicit action.
  Future<void> _addDetailsFromTodo(BookingTodo todo) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    if (todo.kind == 'stay') {
      final body = await showModalBottomSheet<Map<String, dynamic>>(
        context: context,
        isScrollControlled: true,
        builder: (_) => AddStaySheet(
          initialName: todo.title,
          initialCheckIn: todo.departDate,
          initialCheckOut: todo.returnDate,
        ),
      );
      if (body == null) return;
      try {
        await ref
            .read(accommodationsApiServiceProvider)
            .add(widget.tripId, body);
        await _load();
      } catch (e) {
        _showSnack(l10n.tripAddStayFailed(friendlyError(l10n, e)));
      }
      return;
    }
    // Transport: the todo model carries no origin/destination fields, but
    // _deriveTodos always titles a leg 'A → B' — split it back apart. Mode
    // follows the provider the leg was derived with.
    final parts = todo.title.split(' → ');
    final trip = _trip;
    final body = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AddSegmentSheet(
        initialOrigin: parts.isNotEmpty ? parts.first : null,
        initialDestination: parts.length > 1 ? parts[1] : null,
        initialMode: switch (todo.provider) {
          'ferry' => 'ferry',
          'rome2rio' => trip == null ? null : _groundModeOf(trip),
          _ => 'flight',
        },
        initialDepartDate: todo.departDate,
      ),
    );
    if (body == null) return;
    try {
      await ref
          .read(transportApiServiceProvider)
          .addSegment(widget.tripId, body);
      await _load();
    } catch (e) {
      _showSnack(l10n.tripAddTransportFailed(friendlyError(l10n, e)));
    }
  }

  Future<void> _deleteTodo(BookingTodo todo) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    try {
      await ref
          .read(bookingTodosApiServiceProvider)
          .delete(widget.tripId, todo.id);
      if (mounted) {
        setState(() => _bookingTodos =
            _bookingTodos.where((t) => t.id != todo.id).toList());
      }
    } catch (e) {
      _showSnack(l10n.tripDeleteFailed(friendlyError(l10n, e)));
    }
  }

  Future<void> _addBooking() async {
    if (_guardOffline()) return;
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => _AddBookingTodoDialog(
        tripId: widget.tripId,
        groundMode: _trip == null ? null : _groundModeOf(_trip!),
      ),
    );
    if (added == true) await _load();
  }

  Future<void> _editTodo(BookingTodo todo) async {
    if (_guardOffline()) return;
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) =>
          _AddBookingTodoDialog(tripId: widget.tripId, existing: todo),
    );
    if (changed == true) await _load();
  }

  /// [day] preselects the dialog's Day dropdown (e.g. from the map's
  /// empty-day CTA, where the user is already looking at a specific day).
  Future<void> _addPlace({int? day}) async {
    if (_guardOffline()) return;
    final trip = _trip;
    if (trip == null) return;
    final beforeIds = {
      for (final i in trip.items ?? const <ItineraryItem>[]) i.id
    };
    final added = await showDialog<bool>(
      context: context,
      builder: (_) => AddItineraryItemDialog(trip: trip, initialDay: day),
    );
    if (added == true) {
      await _load();
      _expandRunsOfNewItems(beforeIds);
    }
  }

  /// Groups default collapsed, so a place added into a collapsed run would
  /// vanish with zero visible feedback — open the run(s) holding items that
  /// weren't in the trip before the add.
  void _expandRunsOfNewItems(Set<String> beforeIds) {
    final trip = _trip;
    if (trip == null) return;
    final items = trip.items ?? const <ItineraryItem>[];
    final fresh = {
      for (final i in items)
        if (!beforeIds.contains(i.id)) i.id
    };
    if (fresh.isEmpty) return;
    setState(() {
      for (final leg in _derive(trip).legs) {
        if (leg.items.any((i) => fresh.contains(i.id))) {
          _expandedCities.add(leg.key);
        }
      }
    });
  }

  Future<void> _patch(
      {String? title,
      String? startDate,
      String? endDate,
      String? status,
      String? travelMode}) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    try {
      final updated = await ref.read(tripsApiServiceProvider).patchTrip(
            widget.tripId,
            title: title,
            startDate: startDate,
            endDate: endDate,
            status: status,
            travelMode: travelMode,
          );
      if (mounted) setState(() => _trip = updated);
      ref.read(tripsProvider.notifier).loadTrips(); // keep list in sync
      // A mode change re-derives the auto-seeded transport rows immediately,
      // so e.g. suggested flight legs heal to car without a reload.
      if (travelMode != null) {
        await _syncBookingTodos(updated);
      }
    } catch (e) {
      _showSnack(l10n.tripUpdateFailed(friendlyError(l10n, e)));
    }
  }

  Future<void> _editTitle() async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    final controller = TextEditingController(text: _trip?.title ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.tripEditTitle),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.commonCancel)),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: Text(l10n.commonSave),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await _patch(title: result);
    }
  }

  Future<void> _editDates() async {
    if (_guardOffline()) return;
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
    );
    if (range != null) {
      await _patch(startDate: _fmt(range.start), endDate: _fmt(range.end));
    }
  }

  /// Opens the in-page refinement panel on [target], seeding a fresh session
  /// with the section's current contents. The session is bound to this trip
  /// server-side, so changes patch the trip in place (no new versions).
  void _openRefine(Trip trip, RefineTarget target) {
    // Chat/refine needs the network; also keeps the refine panel from ever
    // observing a cached (read-only) trip.
    if (_guardOffline()) return;
    // Owners and editor co-planners refine; viewer-role members are
    // read-only. Buttons are hidden, this is the belt-and-braces guard.
    if (!trip.canEdit) return;
    final l10n = context.l10n;
    final items = trip.items ?? [];
    if (items.isEmpty) {
      _showSnack(l10n.tripAddPlacesBeforeRefine);
      return;
    }
    ref
        .read(tripRefineProvider(widget.tripId).notifier)
        .beginSectionRefinement(_buildSectionSeed(trip, target),
            // displayLabel is what the traveler reads in the panel header, so
            // it uses the localized form; the seed prompt above keeps the
            // canonical English label the agent expects (specs/i18n-spanish).
            displayLabel: target.assistant
                ? l10n.tripAssistantLabel
                : l10n.tripRefiningSection(target.displayLabel(l10n)));
    setState(() {
      _panelOpen = true;
      _refineTarget = target;
    });
  }

  /// FAB entry point: resumes the panel conversation if one is in progress,
  /// otherwise starts a fresh whole-trip assistant session.
  void _openChat(Trip trip) {
    if (_guardOffline()) return;
    // The FAB is hidden for read-only viewers; belt-and-braces like
    // _openRefine.
    if (!trip.canEdit) return;
    final hasConversation =
        ref.read(tripRefineProvider(widget.tripId)).messages.isNotEmpty;
    if (hasConversation) {
      setState(() {
        _panelOpen = true;
        // Restore a header if the screen was rebuilt and lost it; keep a
        // surviving section-refine target so its header stays accurate.
        _refineTarget ??= const RefineTarget.assistant();
      });
      return;
    }
    _openRefine(trip, const RefineTarget.assistant());
  }

  /// Whether an item falls inside the refinement target (client-side mirror of
  /// the server's section selector, using the same hub grouping as the list).
  bool _inTarget(ItineraryItem it, RefineTarget t) {
    switch (t.scope) {
      case 'day':
        if (it.day != t.day) return false;
        return t.city == null ||
            (_hubOf(it)?.toLowerCase() == t.city!.toLowerCase());
      case 'city':
        return _hubOf(it)?.toLowerCase() == t.city!.toLowerCase();
      default:
        return true;
    }
  }

  /// One compact line per item with everything the agent must echo back to
  /// keep the item unchanged (coordinates and all tags).
  String _seedLine(ItineraryItem it) {
    final b = StringBuffer('- ${it.name}');
    if (it.category != null) b.write(' [${it.category}]');
    b.write(' (${it.latitude}, ${it.longitude})');
    final city = it.city?.trim();
    if (city != null && city.isNotEmpty) b.write(', city: $city');
    final hub = it.dayTripFrom?.trim();
    if (hub != null && hub.isNotEmpty) b.write(', day trip from $hub');
    if (it.day != null) b.write(', day ${it.day}');
    if (it.timeOfDay != null) b.write(', ${it.timeOfDay}');
    return b.toString();
  }

  /// Builds the panel's seed message: trip context, the target section's items
  /// in full detail, and explicit instructions to patch only that section via
  /// update_itinerary_section.
  String _buildSectionSeed(Trip trip, RefineTarget t) {
    final items = trip.items ?? [];
    final b =
        StringBuffer('I want to refine my saved trip "${_displayTitle(trip)}"');
    if (trip.startDate != null && trip.endDate != null) {
      b.write(' (${trip.startDate} to ${trip.endDate})');
    }
    b.writeln('.');

    final inTarget = items.where((it) => _inTarget(it, t)).toList();
    if (t.scope == 'trip') {
      b.writeln('\nThe full itinerary:');
    } else {
      // A one-line digest of the rest of the trip so the agent has context
      // without treating it as editable.
      b.writeln('\nFor context, the rest of the trip (do not change these): '
          '${items.where((it) => !_inTarget(it, t)).map((it) => it.name).join(', ')}.');
      b.writeln('\nThe section to refine — ${t.label}:');
    }
    for (final it in inTarget) {
      b.writeln(_seedLine(it));
    }

    b.write('\nOnly change this section unless I broaden the request. When you '
        'apply a change, call update_itinerary_section with ');
    switch (t.scope) {
      case 'day':
        b.write("scope='day', day=${t.day}");
        if (t.city != null) b.write(", city='${t.city}'");
      case 'city':
        b.write("scope='city', city='${t.city}'");
      default:
        b.write("scope='trip'");
    }
    b.write(' and the COMPLETE updated list for the section, keeping unchanged '
        'places exactly as listed above (same coordinates and tags). ');
    b.write(t.assistant
        ? 'I may also just ask questions about the trip (flights, bookings, '
            'timing) — answer those directly without changing anything. '
            'Start by asking how you can help.'
        : 'Start by asking what I want to change.');
    return b.toString();
  }

  Future<void> _delete() async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.tripDeleteTitle),
        content: Text(l10n.tripDeleteBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (confirm == true) {
      try {
        await ref.read(tripsProvider.notifier).deleteTrip(widget.tripId);
        await ref
            .read(recentTripProvider.notifier)
            .clearIfMatches(widget.tripId);
        if (mounted) Navigator.of(context).pop();
      } catch (e) {
        _showSnack(l10n.tripDeleteFailed(friendlyError(l10n, e)));
      }
    }
  }

  void _showSnack(String msg) {
    if (mounted) showSnack(context, msg);
  }

  /// Drops this shared trip from the member's own list (the owner's trip is
  /// untouched). Editors and viewer follows alike.
  Future<void> _leaveTrip() async {
    final l10n = context.l10n;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.tripLeaveTitle),
        content: Text(l10n.tripLeaveBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.commonCancel)),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.tripRemove),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ref.read(tripsApiServiceProvider).leaveTrip(widget.tripId);
      ref.invalidate(sharedWithMeProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _showSnack(l10n.tripLeaveFailed(friendlyError(l10n, e)));
    }
  }

  Future<void> _addStay() async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    final body = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const AddStaySheet(),
    );
    if (body == null) return;
    try {
      await ref
          .read(accommodationsApiServiceProvider)
          .add(widget.tripId, body);
      await _load();
    } catch (e) {
      _showSnack(l10n.tripAddStayFailed(friendlyError(l10n, e)));
    }
  }

  Future<void> _deleteStay(Accommodation a) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    try {
      await ref
          .read(accommodationsApiServiceProvider)
          .delete(widget.tripId, a.id);
      await _load();
    } catch (e) {
      _showSnack(l10n.tripRemoveStayFailed(friendlyError(l10n, e)));
    }
  }

  /// Opens the stay sheet prefilled; a save PATCHes the row, which also
  /// confirms it if it was a Suggested draft.
  Future<void> _editStay(Accommodation a) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    final body = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AddStaySheet(initial: a),
    );
    if (body == null) return;
    try {
      await ref
          .read(accommodationsApiServiceProvider)
          .update(widget.tripId, a.id, body);
      await _load();
    } catch (e) {
      _showSnack(l10n.tripUpdateStayFailed(friendlyError(l10n, e)));
    }
  }

  Future<void> _addSegment() async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    // A stated travel mode prefills the form ('mixed' doesn't pick a side).
    final tm = _trip?.travelMode;
    final body = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AddSegmentSheet(initialMode: tm == 'mixed' ? null : tm),
    );
    if (body == null) return;
    try {
      await ref
          .read(transportApiServiceProvider)
          .addSegment(widget.tripId, body);
      await _load();
    } catch (e) {
      _showSnack(l10n.tripAddTransportFailed(friendlyError(l10n, e)));
    }
  }

  Future<void> _deleteSegment(TripSegment s) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    try {
      await ref
          .read(transportApiServiceProvider)
          .deleteSegment(widget.tripId, s.id);
      await _load();
    } catch (e) {
      _showSnack(l10n.tripRemoveTransportFailed(friendlyError(l10n, e)));
    }
  }

  /// Opens the transport sheet prefilled; a save PATCHes the row, which also
  /// confirms it if it was a Suggested draft.
  Future<void> _editSegment(TripSegment s) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    final body = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AddSegmentSheet(initial: s),
    );
    if (body == null) return;
    try {
      await ref
          .read(transportApiServiceProvider)
          .updateSegment(widget.tripId, s.id, body);
      await _load();
    } catch (e) {
      _showSnack(l10n.tripUpdateTransportFailed(friendlyError(l10n, e)));
    }
  }

  /// Where the app is mounted on its host: '/' in dev, '/app/' in the
  /// Anchors the app-bar share menu so the iPad share popover has a rect to
  /// point at (share_plus requires sharePositionOrigin there).
  final GlobalKey _shareMenuKey = GlobalKey();

  Rect? _shareAnchorRect() {
    final box =
        _shareMenuKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// "Title · dates" line that accompanies a shared link.
  String _shareMessage(Trip trip) {
    final dates = tripDateRange(trip.startDate, trip.endDate);
    return dates == null
        ? _displayTitle(trip)
        : '${_displayTitle(trip)} · $dates';
  }

  /// Mints (or reuses) the trip's share link, then hands it to the OS share
  /// sheet (mobile) or the clipboard (web/desktop).
  Future<void> _shareLink() async {
    final trip = _trip;
    if (trip == null) return;
    final l10n = context.l10n;
    try {
      final token = await ref
          .read(tripsApiServiceProvider)
          .createShareLink(widget.tripId);
      if (!mounted) return;
      await shareOrCopyLink(
        context,
        url: shareUrl(token),
        message: _shareMessage(trip),
        snackOnCopy: l10n.tripShareLinkCopied,
        sharePositionOrigin: _shareAnchorRect(),
      );
    } catch (e) {
      _showSnack(l10n.tripShareLinkFailed(friendlyError(l10n, e)));
    }
  }

  /// Mints an owner-private export token and opens the printable view (which
  /// the browser's print dialog turns into a PDF). Export needs the network,
  /// so it's gated on !_isOffline like the rest of the share menu.
  Future<void> _openPrintExport() => _openExport(print: true);

  /// Mints an export token and opens the calendar (.ics) download — the trip's
  /// days as calendar events.
  Future<void> _openCalendarExport() => _openExport(print: false);

  Future<void> _openExport({required bool print}) async {
    if (_trip == null || _isOffline) return;
    final l10n = context.l10n;
    try {
      final service = ref.read(tripsApiServiceProvider);
      final token = await service.mintExportToken(widget.tripId);
      if (!mounted) return;
      final base = service.apiClient.baseUrl;
      final url =
          print ? exportPrintUrl(base, token) : exportIcsUrl(base, token);
      await trackedLaunchUrl(
        context,
        url,
        provider: 'export',
        surface: print ? 'print' : 'calendar',
        tripId: widget.tripId,
      );
    } catch (e) {
      _showSnack(print
          ? l10n.tripPrintExportFailed(friendlyError(l10n, e))
          : l10n.tripCalendarExportFailed(friendlyError(l10n, e)));
    }
  }

  /// Opens a prefilled Google Calendar event for one itinerary item — a pure
  /// URL, so no token mint and no offline gate. Timed when the item carries a
  /// time_of_day, matching the .ics.
  Future<void> _addItemToGoogleCalendar(ItineraryItem item) async {
    final range = itemCalendarRange(_trip?.startDate, item.day,
        timeOfDay: item.timeOfDay);
    if (range == null) return;
    await trackedLaunchUrl(
      context,
      googleCalendarUrl(
        title: item.name,
        start: range.start,
        endExclusive: range.endExclusive,
        allDay: range.allDay,
        location: item.address,
        details: itemCalendarDetails(context.l10n, item),
      ),
      provider: 'google_calendar',
      surface: 'event_calendar',
      tripId: widget.tripId,
      kind: 'item',
    );
  }

  /// Mints an export token and downloads the item's one-event .ics (the Apple
  /// Calendar path). Needs the network, like _openExport.
  Future<void> _addItemToAppleCalendar(ItineraryItem item) async {
    if (_isOffline) return;
    final l10n = context.l10n;
    try {
      final service = ref.read(tripsApiServiceProvider);
      final token = await service.mintExportToken(widget.tripId);
      if (!mounted) return;
      final url = exportEventIcsUrl(
          service.apiClient.baseUrl, token, 'item', item.id);
      await trackedLaunchUrl(
        context,
        url,
        provider: 'apple_calendar',
        surface: 'event_calendar',
        tripId: widget.tripId,
        kind: 'item',
      );
    } catch (e) {
      _showSnack(l10n.tripEventExportFailed(friendlyError(l10n, e)));
    }
  }

  Future<void> _revokeLink() async {
    final l10n = context.l10n;
    try {
      await ref.read(tripsApiServiceProvider).revokeShareLink(widget.tripId);
      _showSnack(l10n.tripSharingTurnedOff);
    } catch (e) {
      _showSnack(l10n.tripSharingOffFailed(friendlyError(l10n, e)));
    }
  }

  /// Mints an editor link and shares/copies it — the recipient can join as a
  /// co-planner and edit this trip.
  Future<void> _inviteCoPlanner() async {
    final trip = _trip;
    if (trip == null) return;
    final l10n = context.l10n;
    try {
      final token = await ref
          .read(tripsApiServiceProvider)
          .createShareLink(widget.tripId, role: 'editor');
      if (!mounted) return;
      await shareOrCopyLink(
        context,
        url: shareUrl(token),
        message: l10n.tripCoPlanInviteMessage(_shareMessage(trip)),
        snackOnCopy: l10n.tripInviteCopied,
        sharePositionOrigin: _shareAnchorRect(),
      );
    } catch (e) {
      _showSnack(l10n.tripInviteFailed(friendlyError(l10n, e)));
    }
  }

  /// Owner-only sheet listing active co-planners with per-person removal.
  Future<void> _manageCoPlanners() async {
    final l10n = context.l10n;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => _CoPlannersSheet(
        tripId: widget.tripId,
        onRemoved: () => _showSnack(l10n.tripCoPlannerRemoved),
        onInvited: (email) => _showSnack(l10n.tripInviteSent(email)),
      ),
    );
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

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

  /// A stored title is "long" when it's really the AI summary (multi-line or
  /// lengthy); such trips get a computed display title instead.
  bool _titleIsLong(String t) => t.contains('\n') || t.length > 60;

  /// What to show as the header title: the trip's own title when it's concise,
  /// otherwise a title computed from the itinerary's cities + dates.
  String _displayTitle(Trip t) =>
      _titleIsLong(t.title) ? _computedTitle(t) : t.title;

  /// The overview prose: the dedicated summary when present, else the long
  /// stored title (legacy trips), else nothing.
  String? _overviewText(Trip t) =>
      t.summary ?? (_titleIsLong(t.title) ? t.title : null);

  /// Builds "City" / "City & City" / "City & City +N more", with the trip's date
  /// range appended when available. Falls back to the (truncated) stored title.
  String _computedTitle(Trip t) {
    final l10n = context.l10n;
    final cities = <String>[];
    for (final it in t.items ?? const <ItineraryItem>[]) {
      final c = _hubOf(it);
      if (c != null && c.isNotEmpty && !cities.contains(c)) cities.add(c);
    }
    String label;
    if (cities.isEmpty) {
      final firstLine = t.title.split('\n').first.trim();
      label = firstLine.length > 40
          ? '${firstLine.substring(0, 40).trim()}…'
          : (firstLine.isEmpty ? l10n.tripTitleFallback : firstLine);
    } else if (cities.length == 1) {
      label = cities.first;
    } else if (cities.length == 2) {
      label = l10n.citiesTwo(cities[0], cities[1]);
    } else {
      label = l10n.citiesMore(cities[0], cities[1], cities.length - 2);
    }
    final start = DateTime.tryParse(t.startDate ?? '');
    final end = DateTime.tryParse(t.endDate ?? '');
    if (start != null && end != null && !end.isBefore(start)) {
      return '$label · ${formatShortRange(start, end)}';
    }
    return label;
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
      {required bool showTonight, ({DateTime? start, DateTime? end})? range}) {
    // City-filler suppression happens here — NOT in the derivation's
    // filtered list — so an all-filler city keeps its group (city header +
    // embedded booking rows; the slot<->group mapping indexes over the full
    // itinerary).
    items = items.where((it) => !isCityFiller(it)).toList();
    if (!items.any((it) => it.day != null)) {
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
    var i = 0;
    while (i < items.length) {
      final day = items[i].day;
      final run = <ItineraryItem>[];
      while (i < items.length && items[i].day == day) {
        run.add(items[i]);
        i++;
      }
      if (day != null) {
        final dayKey = '$groupKey#$day';
        final collapsed = _collapsedDays.contains(dayKey);
        final header = _daySubHeader(
            day, tripStart, theme, collapsed, _runTravelMin(run), () {
          setState(() {
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
            isToday: day == todayDay);
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
    return slivers;
  }

  /// Wraps a run of box widgets as a single sliver for use inside MultiSliver.
  Widget _boxSliver(List<Widget> children) => SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );

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
  /// Material keeps items from showing through while pinned.
  Widget _cityHeader(
      Trip trip, CityGroup group, ThemeData theme, double dateChipWidth) {
    final l10n = context.l10n;
    final cityCollapsed = !_expandedCities.contains(group.key);
    final chipStyle = _chipTextStyle(theme);
    return HoverReveal(
      builder: (context, revealed) => Material(
        color: theme.scaffoldBackgroundColor,
        child: InkWell(
          onTap: () => setState(() {
            if (cityCollapsed) {
              _expandedCities.add(group.key);
            } else {
              _expandedCities.remove(group.key);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.location_on,
                        size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        groupLabelText(l10n, group.label),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (group.dateRange != null)
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
                    // would sit a button-slot right of the other rows.
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
                          : ExcludeSemantics(
                              child: IgnorePointer(
                                child: Opacity(
                                  opacity: 0,
                                  // No tooltip: IgnorePointer blocks hover, a
                                  // ghost tooltip target would outlive it.
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
                const SizedBox(height: 4),
                const Divider(height: 1),
              ],
            ),
          ),
        ),
      ),
    );
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
              padding: const EdgeInsets.only(
                  top: AppSpacing.sm, bottom: AppSpacing.xs),
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
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
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

  /// Live local-events section for a city group, looked up for the group's date
  /// window. Returns an empty box (no sliver content) when the group has no
  /// real city/dates to query. Wrapped in a [Consumer] so only this section
  /// rebuilds as the async lookup resolves.
  Widget _eventsSliver(
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
        final header = Padding(
          padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
          child: Row(
            children: [
              Icon(Icons.local_activity, size: 16, color: AppColors.toolEvents),
              const SizedBox(width: 6),
              Text(
                context.l10n.tripEventsWhileHere,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: AppColors.toolEvents,
                ),
              ),
            ],
          ),
        );
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
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                for (final e in events.take(5))
                  EventCard(
                    event: e,
                    onAddToTrip: () =>
                        _addToTrip(AddToTripPayload.fromEvent(e)),
                  ),
              ],
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

  /// Greek islands/ports we offer ferry connectors between (mirrors the API's
  /// isGreekLocation set; kept small and local since it only gates the UI hint).
  static const _greekIslands = {
    'athens', 'piraeus', 'santorini', 'thira', 'fira', 'oia', 'mykonos',
    'naxos', 'paros', 'ios', 'milos', 'syros', 'tinos', 'folegandros',
    'crete', 'heraklion', 'chania', 'rethymno', 'rhodes', 'kos', 'corfu',
    'kefalonia', 'zakynthos', 'lefkada', 'skiathos', 'skopelos', 'samos',
    'chios', 'lesbos', 'mytilene', 'karpathos', 'symi', 'hydra', 'spetses',
    'aegina',
  };

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


  /// The saved-details line under a slot's todo row (or standalone when the
  /// slot has no todo — viewers get none from the server). Carries the
  /// confirmed record's edit/delete/calendar affordances; the checkbox shows
  /// only in detail-only mode, where there's no todo row above to drive it.
  Widget _detailRowFor({Accommodation? stay, TripSegment? segment,
      required bool detailOnly}) {
    final editable = !_readOnly && !_isOffline;
    if (stay != null) {
      return BookingDetailRow.stay(
        tripId: widget.tripId,
        stay: stay,
        onEdit: editable ? () => _editStay(stay) : null,
        onDelete: editable ? () => _deleteStay(stay) : null,
        showCheckbox: detailOnly,
        onBookedChanged:
            detailOnly && !_readOnly ? (v) => _setRowBooked(v, stay: stay) : null,
        appleCalendarEnabled: !_readOnly && !_isOffline,
      );
    }
    final s = segment!;
    return BookingDetailRow.segment(
      tripId: widget.tripId,
      segment: s,
      onEdit: editable ? () => _editSegment(s) : null,
      onDelete: editable ? () => _deleteSegment(s) : null,
      showCheckbox: detailOnly,
      onBookedChanged:
          detailOnly && !_readOnly ? (v) => _setRowBooked(v, segment: s) : null,
      appleCalendarEnabled: !_readOnly && !_isOffline,
    );
  }

  /// Compact booking rows for a city group's slot: arrival flight + stay when
  /// [departureOnly] is false, the return-home flight when true. Each todo
  /// row is followed by its matched confirmed record's details; a match
  /// without a todo (viewers) renders as a standalone detail row.
  /// [unbookedOnly] keeps only rows whose visible checkbox is unchecked (the
  /// todo's flag when a todo row drives the entry, the record's otherwise) —
  /// the "Not booked yet" lens.
  List<Widget> _bookingRowWidgets(
    BookingSlot slot, {
    required bool departureOnly,
    bool unbookedOnly = false,
  }) {
    final l10n = context.l10n;
    var entries = departureOnly
        ? [(todo: slot.departure, stay: null as Accommodation?, segment: slot.departureMatch)]
        : [
            (todo: slot.arrival, stay: null as Accommodation?, segment: slot.arrivalMatch),
            (todo: slot.stay, stay: slot.stayMatch, segment: null as TripSegment?),
          ];
    if (unbookedOnly) {
      entries = entries
          .where((e) =>
              !(e.todo?.booked ?? e.stay?.booked ?? e.segment?.booked ?? true))
          .toList();
    }
    return [
      for (final e in entries) ...[
        if (e.todo case final todo?)
          BookingTodoRow(
            todo: todo,
            compact: _narrow,
            onBookedChanged: (v) => _setRowBooked(v,
                todo: todo, stay: e.stay, segment: e.segment),
            onOpen: _openCallbackFor(todo),
            openLabelOverride: _ferryLegs.containsKey(todo.todoKey)
                ? (_narrow ? l10n.tripFindFerriesShort : l10n.tripFindFerries)
                : _flightLegs.containsKey(todo.todoKey)
                    ? (_narrow
                        ? l10n.tripFindFlightsShort
                        : l10n.tripFindFlights)
                    : null,
            onAddDetails:
                (_readOnly || _isOffline || todo.kind == 'other')
                    ? null
                    : () => _addDetailsFromTodo(todo),
          ),
        if (e.stay != null || e.segment != null)
          _detailRowFor(
              stay: e.stay, segment: e.segment, detailOnly: e.todo == null),
      ],
    ];
  }

  /// Flat "left to book" rows for the 'unbooked' lens: every city slot's
  /// unbooked rows in trip order, then the residual todos and detail-only
  /// records that matched no city. Reuses the same row widgets (and the
  /// _setRowBooked writer) as the inline city view, so checking a box here
  /// behaves identically and the row leaves the lens on the rebuild.
  List<Widget> _unbookedRows(GroupedBookings grouped) {
    final l10n = context.l10n;
    return [
      for (final (i, slot) in grouped.slots.indexed) ...[
        ..._bookingRowWidgets(slot, departureOnly: false, unbookedOnly: true),
        if (i == grouped.slots.length - 1)
          ..._bookingRowWidgets(slot, departureOnly: true, unbookedOnly: true),
      ],
      for (final todo in grouped.residual.where((t) => !t.booked))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: BookingTodoCard(
            todo: todo,
            onBookedChanged: (v) => _setRowBooked(v, todo: todo),
            onOpen: _openCallbackFor(todo),
            openLabelOverride: _flightLegs.containsKey(todo.todoKey)
                ? l10n.tripFindFlights
                : null,
            onEdit: todo.auto ? null : () => _editTodo(todo),
            onDelete: todo.auto ? null : () => _deleteTodo(todo),
          ),
        ),
      for (final a in grouped.residualStays.where((a) => !a.booked))
        _detailRowFor(stay: a, segment: null, detailOnly: true),
      for (final s in grouped.residualSegments.where((s) => !s.booked))
        _detailRowFor(stay: null, segment: s, detailOnly: true),
    ];
  }

  /// The 'bookings' lens rows: every city slot's rows — booked and unbooked —
  /// in trip order, then the residual todos and detail-only records that
  /// matched no city. Reuses the same row widgets (and the _setRowBooked
  /// writer) as the inline city view, so checking a box here behaves
  /// identically; the row stays put, struck through.
  ///
  /// [destination] narrows to one leg label (null = all): slot i is included
  /// when labels[i] matches; residuals only under All or the 'Other places'
  /// chip (they matched no destination by definition). This filters the
  /// OUTPUT of the one full-label groupedBookings partition — never re-run
  /// the partition on a label subset: its claim-once matching is
  /// order-dependent, so a subset call would assign rows differently than
  /// the inline city view (docs/zen.md).
  List<Widget> _allBookingRows(
    GroupedBookings grouped,
    List<String> labels, {
    String? destination,
  }) {
    final l10n = context.l10n;
    bool slotShown(int i) =>
        destination == null ||
        (i < labels.length && labels[i] == destination);
    final showResiduals =
        destination == null || destination == _kOtherPlaces;
    return [
      for (final (i, slot) in grouped.slots.indexed)
        if (slotShown(i)) ...[
          ..._bookingRowWidgets(slot, departureOnly: false),
          if (i == grouped.slots.length - 1)
            ..._bookingRowWidgets(slot, departureOnly: true),
        ],
      if (showResiduals) ...[
        for (final todo in grouped.residual)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: BookingTodoCard(
              todo: todo,
              onBookedChanged: (v) => _setRowBooked(v, todo: todo),
              onOpen: _openCallbackFor(todo),
              openLabelOverride: _flightLegs.containsKey(todo.todoKey)
                  ? l10n.tripFindFlights
                  : null,
              onEdit: todo.auto ? null : () => _editTodo(todo),
              onDelete: todo.auto ? null : () => _deleteTodo(todo),
            ),
          ),
        for (final a in grouped.residualStays)
          _detailRowFor(stay: a, segment: null, detailOnly: true),
        for (final s in grouped.residualSegments)
          _detailRowFor(stay: null, segment: s, detailOnly: true),
      ],
    ];
  }

  /// Chip values for the 'bookings' lens destination filter: the leg labels
  /// deduped in trip order (a revisited city gets ONE chip covering both its
  /// runs — chips select by label equality, and run-suffixed chips would
  /// leak the internal `#2` key grammar), plus the canonical 'Other places'
  /// value when residual bookings exist and no real 'Other places' leg
  /// already supplied it.
  List<String> _bookingsLensChips(List<String> labels,
      {required bool hasResiduals}) {
    final chips = <String>[];
    for (final l in labels) {
      if (!chips.contains(l)) chips.add(l);
    }
    if (hasResiduals && !chips.contains(_kOtherPlaces)) {
      chips.add(_kOtherPlaces);
    }
    return chips;
  }

  /// The 'bookings' lens body: destination filter chips above the flat
  /// all-bookings list. Returns [] when the trip has no bookings at all so
  /// build can swap in the lens empty state. A stale chip selection (leg
  /// labels change when the itinerary is edited) is clamped here — we're
  /// already in build, so this frame renders the clamped value (the
  /// _selectedDay clamp idiom).
  List<Widget> _bookingsLensBody(
    GroupedBookings grouped,
    List<String> labels,
  ) {
    final l10n = context.l10n;
    final all = _allBookingRows(grouped, labels);
    if (all.isEmpty) return const [];
    final hasResiduals = grouped.residual.isNotEmpty ||
        grouped.residualStays.isNotEmpty ||
        grouped.residualSegments.isNotEmpty;
    final chips = _bookingsLensChips(labels, hasResiduals: hasResiduals);
    if (_bookingsLensDestination != null &&
        !chips.contains(_bookingsLensDestination)) {
      _bookingsLensDestination = null;
    }
    final rows = _bookingsLensDestination == null
        ? all
        : _allBookingRows(grouped, labels,
            destination: _bookingsLensDestination);
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        child: ChoiceChipRow(
          options: chips,
          selected: _bookingsLensDestination,
          onSelected: (v) => setState(() => _bookingsLensDestination = v),
          labelBuilder: (v) =>
              v == _kOtherPlaces ? l10n.tripOtherBookings : v,
        ),
      ),
      if (rows.isEmpty)
        SizedBox(
          height: 120,
          child: EmptyState(
            icon: Icons.search_off,
            title: l10n.tripBookingsLensNoneForDestination,
            compact: true,
          ),
        )
      else
        ...rows,
    ];
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
  /// sheet still covers the full section). Handles hide under a category
  /// filter: the rendered rows are then a non-contiguous subset, so batch
  /// indexes no longer map onto the trip's item order.
  Widget _batchReorderableSliver(
      List<ItineraryItem> batch, double indent, ThemeData theme) {
    // Narrow first: phones reorder via the kebab (Move up/down + Reorder
    // section), so no handle is built at all — the same null-handle path
    // filters/offline/singleton batches already take.
    final canDrag = !_narrow &&
        !_readOnly &&
        !_isOffline &&
        _itemFilter == 'all' &&
        batch.length > 1;
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
    setState(() {
      items.setAll(0, newItems);
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

  /// A small "↓ 12 min · 4.3 km" row shown between two consecutive itinerary
  /// tiles, but only for within-city hops (same hub, truly adjacent in the
  /// itinerary order). Returns null when it shouldn't render — including while a
  /// category filter is active, since filtered tiles aren't globally adjacent.
  Widget? _travelConnector(ItineraryItem from, ItineraryItem to,
      double indentLeft, ThemeData theme) {
    if (_itemFilter != 'all') return null;
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
  /// day's run. Zero while a category filter is active (legs aren't adjacent).
  int _runTravelMin(List<ItineraryItem> run) {
    if (_itemFilter != 'all') return 0;
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

  // The map's travel-time labels live in [TripDerivation.segmentLabels].

  /// Travel time from the hub city to a day trip, e.g. "45 min from Paris",
  /// taken from the already-computed leg into the day trip's first stop. Null
  /// unless the preceding item is actually in the hub city (so a town-to-town
  /// or cross-city leg is never mislabeled), or while a category filter is
  /// active (filtered tiles aren't globally adjacent).
  String? _dayTripTravelLabel(ItineraryItem first) {
    if (_itemFilter != 'all') return null;
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
  Widget _daySubHeader(
      int day,
      DateTime? tripStart,
      ThemeData theme,
      bool collapsed,
      int travelMin,
      VoidCallback onTap,
      VoidCallback? onRefine,
      {Key? headerKey,
      bool isToday = false}) {
    final l10n = context.l10n;
    final label = tripStart != null
        ? _fmtDayHeader(tripStart.add(Duration(days: day - 1)))
        : l10n.tripDayN(day);
    final muted = theme.colorScheme.onSurfaceVariant;
    return HoverReveal(
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
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
            child: Row(
              children: [
                Icon(Icons.today, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
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
    // and momentarily erase the just-added item.
    if (added != null && added.id == widget.tripId) _refresh();
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

  // ---- Trip Health one-tap fixes ------------------------------------------

  /// Applies a Trip Health finding's structured [FindingFix]. Safe mutations
  /// (move/mark-booked/add-packing) apply instantly with a snackbar + Undo;
  /// adds open the existing sheet PREFILLED; set-dates / raise-budget open the
  /// existing editors. After any success the trip reloads and the review
  /// re-reads (see [_afterFix]) so the resolved finding drops off.
  Future<void> _applyFix(TripFinding finding) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    final fix = finding.fix;
    if (fix == null) return;
    final tripId = widget.tripId;
    switch (fix.action) {
      case 'add_lodging':
        final body = await showModalBottomSheet<Map<String, dynamic>>(
          context: context,
          isScrollControlled: true,
          builder: (_) => AddStaySheet(
            initialName: fix.city == null ? null : 'Stay in ${fix.city}',
            initialCheckIn: fix.checkIn,
            initialCheckOut: fix.checkOut,
          ),
        );
        if (body == null) return;
        try {
          await ref
              .read(accommodationsApiServiceProvider)
              .add(tripId, body);
          await _afterFix();
        } catch (e) {
          _showSnack(l10n.tripAddStayFailed(friendlyError(l10n, e)));
        }
        break;
      case 'add_transport':
        final body = await showModalBottomSheet<Map<String, dynamic>>(
          context: context,
          isScrollControlled: true,
          builder: (_) => AddSegmentSheet(
            initialOrigin: fix.origin,
            initialDestination: fix.destination,
            initialMode: fix.mode,
            initialDepartDate: fix.date,
          ),
        );
        if (body == null) return;
        try {
          await ref
              .read(transportApiServiceProvider)
              .addSegment(tripId, body);
          await _afterFix();
        } catch (e) {
          _showSnack(l10n.tripAddTransportFailed(friendlyError(l10n, e)));
        }
        break;
      case 'move_item':
        final itemId = fix.itemId;
        final targetDay = fix.targetDay;
        if (itemId == null || targetDay == null) return;
        final oldDay = _dayOfItem(itemId);
        try {
          await ref
              .read(tripsApiServiceProvider)
              .updateItineraryItem(tripId, itemId, {'day': targetDay});
          await _afterFix();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(l10n.tripMovedToDay(targetDay)),
            action: oldDay == null
                ? null
                : SnackBarAction(
                    label: l10n.tripUndo,
                    onPressed: () => _moveItemToDay(itemId, oldDay),
                  ),
          ));
        } catch (e) {
          _showSnack(l10n.tripMoveItemFailed(friendlyError(l10n, e)));
        }
        break;
      case 'mark_booked':
        final itemId = fix.itemId;
        if (itemId == null) return;
        final isAccommodation = fix.entityType == 'accommodation';
        try {
          await _setEntityBooked(isAccommodation, itemId, true);
          await _afterFix();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(l10n.tripMarkedAsBooked),
            action: SnackBarAction(
              label: l10n.tripUndo,
              onPressed: () async {
                await _setEntityBooked(isAccommodation, itemId, false);
                await _afterFix();
              },
            ),
          ));
        } catch (e) {
          _showSnack(l10n.tripUpdateBookingFailed(friendlyError(l10n, e)));
        }
        break;
      case 'add_packing':
        final title = fix.packingItem;
        if (title == null) return;
        final category = fix.packingCategory ?? 'general';
        try {
          final added = await ref
              .read(checklistApiServiceProvider)
              .add(tripId, title, category);
          ref.invalidate(checklistProvider(tripId));
          await _afterFix();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(l10n.tripAddedToPacking(title)),
            action: SnackBarAction(
              label: l10n.tripUndo,
              onPressed: () async {
                try {
                  await ref
                      .read(checklistApiServiceProvider)
                      .delete(tripId, added.id);
                  ref.invalidate(checklistProvider(tripId));
                  _invalidateReview();
                } catch (e) {
                  _showSnack(l10n.tripUndoFailed(friendlyError(l10n, e)));
                }
              },
            ),
          ));
        } catch (e) {
          _showSnack(l10n.tripAddPackingFailed(friendlyError(l10n, e)));
        }
        break;
      case 'set_dates':
        await _editDates();
        _invalidateReview();
        break;
      case 'raise_budget':
        await _editBudgetTarget();
        break;
    }
  }

  /// Reloads the trip payload and re-reads the health review so a resolved
  /// finding disappears on the next fetch.
  Future<void> _afterFix() async {
    await _load();
    _invalidateReview();
  }

  /// Invalidates both review variants (hours-off and hours-on) so whichever the
  /// section is showing re-fetches.
  void _invalidateReview() {
    ref.invalidate(
        tripReviewProvider(TripReviewKey(widget.tripId, checkHours: false)));
    ref.invalidate(
        tripReviewProvider(TripReviewKey(widget.tripId, checkHours: true)));
  }

  int? _dayOfItem(String itemId) {
    for (final item in _trip?.items ?? const <ItineraryItem>[]) {
      if (item.id == itemId) return item.day;
    }
    return null;
  }

  Future<void> _moveItemToDay(String itemId, int day) async {
    final l10n = context.l10n;
    try {
      await ref
          .read(tripsApiServiceProvider)
          .updateItineraryItem(widget.tripId, itemId, {'day': day});
      await _afterFix();
    } catch (e) {
      _showSnack(l10n.tripMoveItemFailed(friendlyError(l10n, e)));
    }
  }

  Future<void> _setEntityBooked(
      bool isAccommodation, String id, bool booked) async {
    if (isAccommodation) {
      await ref
          .read(accommodationsApiServiceProvider)
          .update(widget.tripId, id, {'booked': booked});
    } else {
      await ref
          .read(transportApiServiceProvider)
          .updateSegment(widget.tripId, id, {'booked': booked});
    }
  }

  /// Screen-level budget-target editor for the raise_budget fix. Reuses the
  /// budget provider/service; keeps the trip's existing currency.
  Future<void> _editBudgetTarget() async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    final Budget budget;
    try {
      budget = await ref.read(budgetProvider(widget.tripId).future);
    } catch (e) {
      _showSnack(l10n.tripLoadBudgetFailed(friendlyError(l10n, e)));
      return;
    }
    if (!mounted) return;
    final currency = budget.currency;
    final controller = TextEditingController(
      text: budget.targetAmount == null
          ? ''
          : budget.targetAmount!.toStringAsFixed(0),
    );
    final result = await showDialog<Map<String, double?>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.tripSetBudgetTarget),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: l10n.tripBudgetTargetLabel(currency),
            hintText: l10n.tripBudgetTargetHint,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l10n.commonCancel)),
          FilledButton(
            onPressed: () {
              final raw = controller.text.trim();
              final amount = raw.isEmpty ? null : double.tryParse(raw);
              if (raw.isNotEmpty && (amount == null || amount < 0)) return;
              Navigator.of(ctx).pop(<String, double?>{'amount': amount});
            },
            child: Text(l10n.commonSave),
          ),
        ],
      ),
    );
    if (result == null) return; // cancelled
    try {
      await ref.read(budgetApiServiceProvider).upsertBudget(
            widget.tripId,
            targetAmount: result['amount'],
            currency: currency,
          );
      ref.invalidate(budgetProvider(widget.tripId));
      await _afterFix();
    } catch (e) {
      _showSnack(l10n.tripUpdateBudgetFailed(friendlyError(l10n, e)));
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

  // The per-position date chips live in [TripDerivation.locationDates]; the
  // leg date-range derivation itself (raw + visible) stays in
  // utils/leg_ranges.dart (specs/trip-dates-truth stage 0a) — one testable
  // definition shared with the booking-todo derivation and the Go twin
  // behind the server legs payload.

  /// "Jul 15" in English, "15 jul" in Spanish — the cached DateFormat reads
  /// Intl.defaultLocale, which the locale provider sets (specs/i18n-spanish).
  String _fmtShortDt(DateTime d) => mmmd().format(d);

  /// Coarse relative timestamp for the "Updated by X" line.
  String _relativeTime(String iso) {
    final l10n = context.l10n;
    final t = DateTime.tryParse(iso);
    if (t == null) return l10n.tripTimeRecently;
    final d = DateTime.now().difference(t.toLocal());
    if (d.inMinutes < 1) return l10n.tripTimeJustNow;
    if (d.inMinutes < 60) return l10n.tripTimeMinutesAgo(d.inMinutes);
    if (d.inHours < 24) return l10n.tripTimeHoursAgo(d.inHours);
    return l10n.tripTimeDaysAgo(d.inDays);
  }

  /// Day-header date, e.g. "Wed, Jul 15" (weekday + month + day); Spanish
  /// reorders to "mié, 15 jul" on its own.
  String _fmtDayHeader(DateTime d) => mmmed().format(d);

  // ── Trailing collapsed sections ─────────────────────────────────────────
  // Trip health / Packing / Budget end the page as one-line summary rows,
  // closed by default — health first so its actionable review pill is met
  // before the empty-state rows. Summary data comes from watches HERE in
  // the parent — the section widgets are only mounted while expanded, so a
  // child-side watch could never feed a collapsed row's counts.

  bool _sectionExpanded(String id) => _expandedSections.contains(id);

  void _toggleSection(String id) => setState(() {
        if (!_expandedSections.add(id)) _expandedSections.remove(id);
      });

  /// Lays out the trailing section rows in a settings-list rhythm: hairline
  /// dividers between the rows that are present. Hidden rows are null, so a
  /// divider never renders against a missing neighbor.
  Widget _sectionCluster(List<Widget?> rows) {
    final present = rows.whereType<Widget>().toList();
    if (present.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.md),
        const Divider(height: 1),
        for (final (i, row) in present.indexed) ...[
          if (i > 0) const Divider(height: 1),
          row,
        ],
      ],
    );
  }

  /// The itinerary's trailing "Other bookings" area — the new home for
  /// everything the retired Bookings section held that has no city slot:
  /// residual todos (custom bookings, stale autos), confirmed records that
  /// matched no city, and the add actions. Editors always get the add
  /// buttons; the sub-header renders only over actual content.
  Widget? _otherBookingsArea(
      ThemeData theme,
      ({
        List<BookingTodo> residual,
        List<Accommodation> residualStays,
        List<TripSegment> residualSegments,
      }) other) {
    final l10n = context.l10n;
    final hasContent = other.residual.isNotEmpty ||
        other.residualStays.isNotEmpty ||
        other.residualSegments.isNotEmpty;
    if (_readOnly && !hasContent) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasContent)
          Padding(
            padding:
                const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
            child: Text(
              l10n.tripOtherBookings,
              style: theme.textTheme.titleSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        if (other.residual.isNotEmpty)
          _residualBookingsList(other.residual, theme),
        for (final a in other.residualStays)
          _detailRowFor(stay: a, segment: null, detailOnly: true),
        for (final s in other.residualSegments)
          _detailRowFor(stay: null, segment: s, detailOnly: true),
        if (!_readOnly)
          // The button trio can outgrow a small phone's width, so it must be
          // able to break into two lines itself (Wrap, not Row).
          Wrap(
            alignment: WrapAlignment.end,
            children: [
              TextButton.icon(
                onPressed: _isOffline ? null : _addStay,
                icon: const Icon(Icons.hotel_outlined, size: 18),
                label: Text(l10n.bookingsAddStay),
              ),
              TextButton.icon(
                onPressed: _isOffline ? null : _addSegment,
                icon: const Icon(Icons.route_outlined, size: 18),
                label: Text(l10n.bookingsAddTransport),
              ),
              TextButton.icon(
                onPressed: _isOffline ? null : _addBooking,
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.bookingsAddBooking),
              ),
            ],
          ),
      ],
    );
  }

  /// Per-leg what-to-wear derivations for the merged section
  /// (specs/what-to-wear). Weather queries stay on rawLegRanges — the
  /// doc-pinned range source shared with the day chips (leg_ranges.dart) —
  /// while the DISPLAYED dates come from the index-aligned visibleLegRanges
  /// pair, so a row's dates can never disagree with the city-header chips
  /// above it (the same raw-vs-visible twin the nights counter rides).
  /// Iterates the leg LIST — not groupRanges, whose label keying is
  /// last-wins for revisited cities — so a revisited city gets one row per
  /// visit. Fetch sharing: a single-visit city's WeatherQuery is
  /// byte-identical to its city-group watch, so the provider family dedups;
  /// a revisited city's earlier visits query per-visit windows the chips
  /// never build — one extra cached /weather call each, the accepted cost of
  /// per-visit rows. Loading or failed reports derive null and drop out;
  /// offline this is simply empty.
  List<WearRegionRec> _legClothingRecs(Trip trip, WidgetRef ref) {
    // NOTE: [ref] is the packing row's Consumer ref, NOT the State's — the
    // weather watches here must subscribe that row, never the whole screen
    // (the screen-scope visibility gate is [_legClothingRecsVisible]).
    final derivation = _derive(trip);
    final raw = derivation.rawRanges;
    final visible = derivation.visibleRanges; // 1:1 by index with raw
    final recs = <WearRegionRec>[];
    for (var i = 0; i < raw.length; i++) {
      final r = raw[i];
      final start = r.start, end = r.end;
      if (r.label == _kOtherPlaces || start == null || end == null) continue;
      final report = ref
          .watch(weatherByCityProvider(WeatherQuery(
            city: r.label,
            startDate: _fmt(start),
            endDate: _fmt(end),
          )))
          .valueOrNull;
      if (report == null) continue;
      final rec = clothingRec(report);
      if (rec == null) continue;
      final v = visible[i];
      recs.add((
        label: r.label,
        start: v.start ?? start,
        end: v.end ?? end,
        rec: rec,
      ));
    }
    return recs;
  }

  /// Collapsed one-liner for the merged row: the cross-region temperature
  /// envelope plus the rain signal. Kind-neutral by design — the "typical"
  /// qualifier stays on the expanded per-region rows.
  String _wearSummary(List<WearRegionRec> recs) {
    final s = clothingSummary([for (final r in recs) r.rec]);
    // Spaced dash like the date ranges ("Sep 15 – Sep 20"), so a negative low
    // never collides with it ("-6° – 2°").
    final range = '${s.loC}° – ${s.hiC}°';
    return s.rainLikely ? '$range · ${context.l10n.wearSummaryRain}' : range;
  }

  Widget? _packingSectionRow(Trip trip, ThemeData theme) {
    // Merged "What to wear & pack" (specs/what-to-wear): weather-derived
    // recommendations on top, the editable checklist below. Recommendations
    // alone can show the row (read-only viewers get guidance even with an
    // empty checklist); without weather the gate reduces exactly to the old
    // checklist-only rule, which mirrors ChecklistSection's own gates
    // (nothing until loaded; viewers with an empty list get no checklist).
    // The parent (whole-screen) watch is VISIBILITY only — narrow bool
    // selects, so the screen rebuilds when the row appears or disappears
    // (preserving _sectionCluster's null-counting divider contract) while
    // content updates (checks ticked, weather details) rebuild only the
    // Consumer below.
    final showChecklistGate = ref.watch(checklistProvider(trip.id).select((a) {
      final items = a.valueOrNull;
      return items != null && !(items.isEmpty && _readOnly);
    }));
    if (!showChecklistGate && !_legClothingRecsVisible(trip)) return null;
    return Consumer(
      builder: (context, ref, _) {
        final items = ref.watch(checklistProvider(trip.id)).valueOrNull;
        final recs = _legClothingRecs(trip, ref);
        final showChecklist = items != null && !(items.isEmpty && _readOnly);
        // The parent gate and this content can disagree for one frame while
        // a provider flips; render nothing rather than dereference a state
        // the gate no longer justifies.
        if (recs.isEmpty && !showChecklist) return const SizedBox.shrink();
        final checked = items?.where((i) => i.checked).length ?? 0;
        // With recs in the summary slot, the checked-count stays glanceable
        // via the pill (same chrome as ChecklistSection's standalone header).
        final summary = recs.isNotEmpty
            ? _wearSummary(recs)
            : context.l10n.checklistSummary(checked, items!.length);
        return CollapsibleSection(
          title: context.l10n.wearSectionTitle,
          icon: Icons.luggage_outlined,
          summary: summary,
          pill: (recs.isEmpty || items == null || items.isEmpty)
              ? null
              : StatusPill.custom(
                  label: '$checked/${items.length}',
                  background: theme.colorScheme.surfaceContainerHighest,
                  foreground: theme.colorScheme.onSurfaceVariant,
                ),
          expanded: _sectionExpanded('packing'),
          onToggle: () => _toggleSection('packing'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (recs.isNotEmpty) WearRecsList(regions: recs),
              if (recs.isNotEmpty && showChecklist) const Divider(height: 24),
              ChecklistSection(
                tripId: trip.id,
                canEdit: !_readOnly,
                isOffline: _isOffline,
                showHeader: false,
              ),
            ],
          ),
        );
      },
    );
  }

  /// Visibility half of [_legClothingRecs]: does ANY leg currently have a
  /// clothing recommendation? Watched at screen scope with per-leg bool
  /// selects, so a weather report resolving flips this at most once — the
  /// full recommendation content is watched only inside the packing row's
  /// Consumer. The early return is deliberate: once one leg says visible,
  /// later legs don't need subscriptions to answer the question.
  bool _legClothingRecsVisible(Trip trip) {
    for (final r in _derive(trip).rawRanges) {
      if (r.label == _kOtherPlaces || r.start == null || r.end == null) {
        continue;
      }
      final has = ref.watch(weatherByCityProvider(WeatherQuery(
        city: r.label,
        startDate: _fmt(r.start!),
        endDate: _fmt(r.end!),
      )).select((a) {
        final report = a.valueOrNull;
        return report != null && clothingRec(report) != null;
      }));
      if (has) return true;
    }
    return false;
  }

  Widget? _budgetSectionRow(Trip trip, ThemeData theme) {
    // Mirrors BudgetSection's own gates, like _packingSectionRow.
    // Parent watch = VISIBILITY atoms only (loaded? target set? any
    // expenses?) so spend/target edits rebuild the Consumer below, not the
    // screen; null atoms mean not-loaded, which hides the row as before.
    final hasTarget = ref.watch(budgetProvider(trip.id).select((a) {
      final b = a.valueOrNull;
      return b == null ? null : b.targetAmount != null;
    }));
    final expensesEmpty = ref.watch(
        expensesProvider(trip.id).select((a) => a.valueOrNull?.isEmpty));
    if (hasTarget == null || expensesEmpty == null) return null;
    if (expensesEmpty && !hasTarget && _readOnly) return null;
    return Consumer(
      builder: (context, ref, _) {
        final budget = ref.watch(budgetProvider(trip.id)).valueOrNull;
        final expenses = ref.watch(expensesProvider(trip.id)).valueOrNull;
        if (budget == null || expenses == null) {
          return const SizedBox.shrink();
        }
        final hasTarget = budget.targetAmount != null;
        final l10n = context.l10n;
        final String summary;
        if (hasTarget) {
          summary = '${formatMoney(budget.spent, budget.currency)}'
              ' / ${formatMoney(budget.targetAmount!, budget.currency)}';
        } else if (expenses.isNotEmpty) {
          summary =
              '${l10n.budgetSummarySpent(formatMoney(budget.spent, budget.currency))}'
              ' · ${l10n.budgetSummaryNoTarget}';
        } else {
          summary = l10n.budgetSummaryEmpty;
        }
        return CollapsibleSection(
          title: l10n.budgetTitle,
          icon: Icons.account_balance_wallet_outlined,
          summary: summary,
          expanded: _sectionExpanded('budget'),
          onToggle: () => _toggleSection('budget'),
          child: BudgetSection(
            tripId: trip.id,
            canEdit: !_readOnly,
            isOffline: _isOffline,
            showHeader: false,
          ),
        );
      },
    );
  }

  Widget? _healthSectionRow(Trip trip, ThemeData theme) {
    // Base provider key (checkHours: false): the section's internal opt-in
    // hours check flips ITS key to the slower variant, so this collapsed
    // count can briefly lag while that toggle is on — accepted.
    // Parent watch = loaded-or-not only; finding counts/severity render in
    // the Consumer, so a background review refresh repaints the row alone.
    final visible = ref.watch(tripReviewProvider(TripReviewKey(trip.id))
        .select((a) => a.valueOrNull != null));
    if (!visible) return null;
    return Consumer(
      builder: (context, ref, _) {
        final findings = ref
            .watch(tripReviewProvider(TripReviewKey(trip.id)))
            .valueOrNull;
        if (findings == null) return const SizedBox.shrink();
        final l10n = context.l10n;
        final worst = TripReviewSection.worstSeverity(findings);
        final colors = worst == null
            ? null
            : TripReviewSection.severityColors(theme, worst);
        return CollapsibleSection(
          title: l10n.reviewSectionTitle,
          icon: Icons.fact_check_outlined,
          summary: findings.isEmpty ? l10n.reviewEmptyTitle : null,
          pill: findings.isEmpty
              ? null
              : StatusPill.custom(
                  label: l10n.reviewCountToReview(findings.length),
                  background: colors!.bg,
                  foreground: colors.fg,
                ),
          expanded: _sectionExpanded('health'),
          onToggle: () => _toggleSection('health'),
          child: TripReviewSection(
            tripId: trip.id,
            isOffline: _isOffline,
            onScrollToDay: _scrollToDay,
            dayForItem: (itemId) {
              for (final item in trip.items ?? const <ItineraryItem>[]) {
                if (item.id == itemId) return item.day;
              }
              return null;
            },
            onApplyFix: _readOnly ? null : _applyFix,
            showHeader: false,
          ),
        );
      },
    );
  }

  /// The trip's hero header: title (+ rename), date/status chips, a Refine
  /// button, and a collapsible overview.
  Widget _buildHeaderCard(Trip trip, ThemeData theme) {
    final l10n = context.l10n;
    final overview = _overviewText(trip);
    final hasDates = trip.startDate != null && trip.endDate != null;
    // Deliberately card-less: the app bar already carries the title, so this
    // block is a compact anchor (rename affordance + meta chips + context
    // line + clamped overview), not a hero panel.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                _displayTitle(trip),
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.bold),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (trip.canEdit)
              IconButton(
                icon: const Icon(Icons.edit, size: 20),
                tooltip: l10n.tripRename,
                onPressed: _isOffline ? null : _editTitle,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ActionChip(
              avatar: const Icon(Icons.event, size: 16),
              // Narrow: humanized short range ("Jul 20 – Jul 27") — the raw
              // ISO pair is ~200px and forces the meta row to wrap.
              label: Text(hasDates
                  ? (_narrow
                      ? (tripDateRange(trip.startDate, trip.endDate) ??
                          '${trip.startDate} → ${trip.endDate}')
                      : '${trip.startDate} → ${trip.endDate}')
                  : l10n.tripAddDates),
              onPressed: (_isOffline || !trip.canEdit) ? null : _editDates,
            ),
            if (trip.canEdit)
              PopupMenuButton<String>(
                tooltip: l10n.tripChangeStatus,
                enabled: !_isOffline,
                onSelected: (v) => _patch(status: v),
                itemBuilder: (_) => [
                  PopupMenuItem(
                      value: 'draft', child: Text(l10n.tripStatusDraft)),
                  PopupMenuItem(
                      value: 'planned', child: Text(l10n.tripStatusPlanned)),
                ],
                child: StatusPill(
                  status: trip.status,
                  trailing: const Icon(Icons.arrow_drop_down),
                ),
              )
            else
              StatusPill(status: trip.status),
            if (trip.canEdit)
              PopupMenuButton<String>(
                tooltip: l10n.tripTravelModeTooltip,
                enabled: !_isOffline,
                onSelected: (v) => _patch(travelMode: v),
                itemBuilder: (_) => [
                  PopupMenuItem(
                      value: 'flight', child: Text(l10n.tripTravelModeFlying)),
                  PopupMenuItem(
                      value: 'car', child: Text(l10n.tripTravelModeDriving)),
                  PopupMenuItem(
                      value: 'train', child: Text(l10n.tripModeTrain)),
                  PopupMenuItem(value: 'bus', child: Text(l10n.tripModeBus)),
                  PopupMenuItem(
                      value: 'ferry', child: Text(l10n.tripModeFerry)),
                  PopupMenuItem(
                      value: 'mixed', child: Text(l10n.tripTravelModeMixed)),
                ],
                child: Chip(
                  avatar: Icon(_travelModeIcon(trip.travelMode), size: 16),
                  label: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(_travelModeLabel(l10n, trip.travelMode)),
                    const Icon(Icons.arrow_drop_down, size: 18),
                  ]),
                ),
              )
            else if (trip.travelMode != null)
              Chip(
                avatar: Icon(_travelModeIcon(trip.travelMode), size: 16),
                label: Text(_travelModeLabel(l10n, trip.travelMode)),
              ),
            // Refine entry, demoted from a full-width banner to a peer of the
            // meta chips. Same canEdit gate as before, so editor
            // collaborators keep their spec-mandated entry point
            // (specs/collaborator-refine); the per-city/day sparkles and the
            // chat FAB are unchanged. On narrow this moves to the app bar.
            if (trip.canEdit && !_narrow)
              FilledButton.tonalIcon(
                // Chat/refine needs the network — disabled while offline.
                onPressed: _isOffline
                    ? null
                    : () => _openRefine(trip, const RefineTarget.trip()),
                style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact),
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: Text(l10n.tripRefineWithAI),
              ),
          ],
        ),
        // Muted context line: collaborator standing and/or "Updated by
        // Maria · 2m ago" (the server omits self-attribution). Either part
        // can stand alone.
        if (!trip.isOwner || trip.updatedByName != null) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (!trip.isOwner)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                        trip.canEdit
                            ? Icons.group_outlined
                            : Icons.visibility_outlined,
                        size: 16,
                        color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    // Flexible, or the Row hands the Text unbounded width
                    // and a long owner name overflows the Wrap on phones.
                    Flexible(
                      child: Text(
                        trip.canEdit
                            ? (trip.ownerName != null
                                ? l10n.tripCoPlanningWith(trip.ownerName!)
                                : l10n.tripCoPlanningShared)
                            : (trip.ownerName != null
                                ? l10n.tripSharedBy(trip.ownerName!)
                                : l10n.tripSharedViewOnly),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              if (trip.updatedByName != null)
                Text(
                  l10n.tripUpdatedBy(
                      trip.updatedByName!, _relativeTime(trip.updatedAt)),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
            ],
          ),
        ],
        if (overview != null) ...[
          const SizedBox(height: 12),
          // Self-contained show-more leaf: toggling it rebuilds this text
          // block only, not the whole screen.
          _OverviewText(
            text: overview,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  // Destination pins live in [TripDerivation.mapDestinations]: one per
  // location group with a real coordinate, in visit order, derived from the
  // FULL itinerary — never the day/category-filtered view, which would shift
  // the numbering (the home-leg doctrine in [_openFullMap]).

  /// The rounded map card shared by the wide (pinned header) and phone
  /// (scroll-away) layouts. When [expandable], the map is a static preview:
  /// an [AbsorbPointer] swallows the pin/stay gesture detectors so the whole
  /// card is one tap target opening [TripMapScreen], and — because the tap
  /// [GestureDetector] claims only taps — vertical drags fall through to the
  /// page scroll. The day chips sit above the gesture layer either way, so
  /// they stay tappable inline.
  Widget _mapCard(
    Trip trip,
    AppLocalizations l10n,
    int mapDayCount,
    Set<int> mappedDays, {
    required bool expandable,
  }) {
    final derivation = _derive(trip);
    final endpoints = derivation.homeLegEndpoints;
    // Day + selection live in ValueNotifiers: this builder — not the whole
    // screen — is what a day-chip tap or pin/row selection rebuilds. The
    // day-filtered lists come from the derivation's lazy per-day caches, so
    // a selection-only rebuild passes TripMap the identical lists and its
    // marker cache skips re-clustering.
    return ListenableBuilder(
      listenable: Listenable.merge([_selectedDay, _selectedPosition]),
      builder: (context, _) {
        final day = _clampedDay(mapDayCount);
        // Consumer, not the screen's ref: homeOverlayFor watches the
        // home-airport resolution provider, and that watch belongs to the
        // map subtree — resolution landing must not rebuild the screen.
        Widget map = Consumer(
          builder: (context, ref, _) {
            final home = homeOverlayFor(
              ref,
              homeAirport: _homeAirport,
              day: day,
              dayCount: mapDayCount,
              firstCityPoint: endpoints.first,
              lastCityPoint: endpoints.last,
            );
            return TripMap(
              items: derivation.dayFilteredItems(day),
              accommodations: derivation.dayFilteredStays(day),
              destinations: day == null ? derivation.mapDestinations : null,
              selectedPosition: _selectedPosition.value,
              // Unfiltered by day: TripMap's position+1 adjacency guard
              // drops labels across the gaps a day filter creates, and the
              // category filter already empties this map.
              segmentLabels: derivation.segmentLabels,
              home: home,
              fitSignature: day,
              // Keep fitted markers clear of the chip row overlaid below.
              topOverlayInset: mapDayCount > 0 ? MapDayChips.mapTopInset : 0,
              interactive: !expandable,
              emptyLabel: day == null
                  ? l10n.tripNoMappedPlaces
                  : l10n.tripNoPlacesOnDay(day),
              emptyMessage: _isOffline ? null : l10n.tripAddPlaceMapHint,
              // The preview absorbs pointers, so its empty-state CTA could
              // never be tapped; the pinned "+ Add place" button sits right
              // below anyway.
              emptyAction: (expandable || _isOffline || _readOnly)
                  ? null
                  : FilledButton.tonalIcon(
                      onPressed: () => _addPlace(day: day),
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(l10n.tripAddPlace),
                    ),
              onPinTap: expandable
                  ? null
                  : (pos) {
                      final it =
                          trip.items!.firstWhere((i) => i.position == pos);
                      _selectedPosition.value = pos;
                      // The highlighted row can only be seen if its run
                      // renders: groups default collapsed, so open the
                      // tapped item's run. Selection itself is
                      // notifier-driven; setState only when expansion
                      // actually changed (the one thing the wider screen
                      // must re-render).
                      var expandedChanged = false;
                      for (final leg in _derive(trip).legs) {
                        if (leg.items.any((i) => i.position == pos)) {
                          expandedChanged =
                              _expandedCities.add(leg.key) || expandedChanged;
                        }
                      }
                      if (expandedChanged) setState(() {});
                      _showSnack(it.name);
                    },
              onExpand: expandable
                  ? null
                  : () => _openFullMap(trip, mapDayCount, mappedDays),
            );
          },
        );
        if (expandable) {
          map = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openFullMap(trip, mapDayCount, mappedDays),
            child: AbsorbPointer(child: map),
          );
        }
        return ClipRRect(
          borderRadius: AppRadius.lgAll,
          child: Stack(
            children: [
              Positioned.fill(child: map),
              // Above the map's gesture layer, so chip taps and row scrolls
              // never pan the map.
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: MapDayChips(
                  dayCount: mapDayCount,
                  selected: day,
                  mappedDays: mappedDays,
                  onSelected: (d) => _selectedDay.value = d,
                ),
              ),
              if (expandable)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: MapControlButton(
                    icon: Icons.fullscreen,
                    tooltip: l10n.tripExpandMap,
                    onTap: () => _openFullMap(trip, mapDayCount, mappedDays),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Read-side clamp for [_selectedDay]: a refresh can shrink the trip below
  /// a stale selection (fewer days after an edit); an out-of-range day reads
  /// as All. Clamping at read — instead of writing the notifier during
  /// build — keeps build pure; the stale value is harmless because every
  /// consumer goes through here with the current day count.
  int? _clampedDay(int mapDayCount) {
    final day = _selectedDay.value;
    return (day != null && day > mapDayCount) ? null : day;
  }

  // Home-leg endpoints live in [TripDerivation.homeLegEndpoints] — the
  // trip's first/last location groups, the same derivation the
  // outbound/return booking todos trust — never the first/last mapped pin,
  // which shifts under day/category filters.

  /// Pushes the full-screen interactive map. Root navigator so the map
  /// covers the bottom navigation bar; the closures read the live [_trip] so
  /// a silent refresh propagates on the next chip tap.
  void _openFullMap(Trip trip, int mapDayCount, Set<int> mappedDays) {
    final derivation = _derive(trip);
    final endpoints = derivation.homeLegEndpoints;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => TripMapScreen(
          title: _displayTitle(trip),
          destinations: derivation.mapDestinations,
          homeAirport: _homeAirport,
          firstCityPoint: endpoints.first,
          lastCityPoint: endpoints.last,
          itemsForDay: (d) {
            final t = _trip;
            return t == null
                ? const <ItineraryItem>[]
                : _derive(t).dayFilteredItems(d);
          },
          staysForDay: (d) {
            final t = _trip;
            return t == null
                ? const <Accommodation>[]
                : _derive(t).dayFilteredStays(d);
          },
          segmentLabels: derivation.segmentLabels,
          dayCount: mapDayCount,
          mappedDays: mappedDays,
          initialDay: _clampedDay(mapDayCount),
          // The embedded map card listens to the notifier, so the full-screen
          // selection stays in sync with the card behind it — no setState.
          onDaySelected: (d) => _selectedDay.value = d,
          onAddPlace: (_isOffline || _readOnly)
              ? null
              : (day) => _addPlace(day: day),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final trip = _trip;

    return LayoutBuilder(builder: (context, constraints) {
      // Same width the body LayoutBuilder sees (Scaffold adds no horizontal
      // chrome), so this always agrees with _mapPinned. Plain assignment:
      // we're in build, like _mapPinned's own write.
      _narrow = constraints.maxWidth < kRailBreakpoint;
      return Scaffold(
      // Always-reachable chat entry, mirroring the _openRefine guards so it's
      // never a dead button. Hidden while the panel is open: on wide layouts
      // the panel is docked (redundant), on narrow it would overlap the sheet.
      floatingActionButton: (trip != null &&
              !_panelOpen &&
              trip.canEdit &&
              !_isOffline &&
              (trip.items?.isNotEmpty ?? false))
          ? FloatingActionButton(
              tooltip: l10n.tripAskAI,
              onPressed: () => _openChat(trip),
              child: const Icon(Icons.chat_bubble_outline),
            )
          : null,
      appBar: GradientAppBar(
        title: Text(
            trip != null ? _displayTitle(trip) : l10n.tripTitleFallback,
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
        actions: [
          // Narrow: the header card drops its Refine button (one clean chip
          // row), so the trip-level refine entry moves up here — first, so
          // share/delete/leave keep their outer-edge spots for every role.
          // Same gates as the button it replaces: editors only
          // (specs/collaborator-refine), disabled — not hidden — offline.
          if (_narrow && trip != null && trip.canEdit)
            IconButton(
              icon: const Icon(Icons.auto_awesome),
              tooltip: l10n.tripRefineWithAI,
              onPressed: _isOffline
                  ? null
                  : () => _openRefine(trip, const RefineTarget.trip()),
            ),
          // Sharing and deletion are owner-only surfaces; editors see
          // neither. Both mutate, so they're hidden while offline-serving.
          if (trip != null && trip.isOwner && !_isOffline)
            PopupMenuButton<String>(
              key: _shareMenuKey,
              icon: const Icon(Icons.share_outlined),
              tooltip: l10n.tripShareTrip,
              onSelected: (v) => switch (v) {
                'copy' => _shareLink(),
                'invite' => _inviteCoPlanner(),
                'manage' => _manageCoPlanners(),
                'print' => _openPrintExport(),
                'calendar' => _openCalendarExport(),
                _ => _revokeLink(),
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                    value: 'copy',
                    child: Text(shareUsesNativeSheet
                        ? l10n.tripShareLinkAction
                        : l10n.tripCopyShareLink)),
                PopupMenuItem(
                    value: 'invite',
                    child: Text(shareUsesNativeSheet
                        ? l10n.tripShareInviteAction
                        : l10n.tripCopyInviteLink)),
                PopupMenuItem(
                    value: 'manage', child: Text(l10n.tripManageAccess)),
                const PopupMenuDivider(),
                PopupMenuItem(
                    value: 'print', child: Text(l10n.tripPrintSavePdf)),
                PopupMenuItem(
                    value: 'calendar', child: Text(l10n.tripAddToCalendar)),
                const PopupMenuDivider(),
                PopupMenuItem(
                    value: 'revoke', child: Text(l10n.tripTurnOffSharing)),
              ],
            ),
          if (trip != null && trip.isOwner && !_isOffline)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: l10n.tripDeleteTrip,
              onPressed: _delete,
            ),
          // Members (editors and viewer follows) can drop the trip from
          // their own list; the owner's trip is untouched.
          if (trip != null && !trip.isOwner && !_isOffline)
            IconButton(
              icon: const Icon(Icons.bookmark_remove_outlined),
              tooltip: l10n.tripRemoveFromMyTrips,
              onPressed: _leaveTrip,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(l10n.tripLoadFailed),
                      const SizedBox(height: 8),
                      FilledButton(
                          onPressed: _load, child: Text(l10n.commonRetry)),
                    ],
                  ),
                )
              : trip == null
                  ? const SizedBox.shrink()
                  : LayoutBuilder(builder: (context, constraints) {
                      // Phones get the scroll-away tap-to-expand map; wide
                      // layouts keep the pinned header. Keyed to the width
                      // the body actually gets (like the refine-dock check
                      // below), not the window. Plain assignment: we're in
                      // build, and the post-frame Today scroll reads it
                      // fresh.
                      _mapPinned = constraints.maxWidth >= kRailBreakpoint;
                      // Hoisted dock decision (also used at the bottom of this
                      // builder): the docked panel + divider eat 401px of this
                      // width, so the gutter must be computed from what the
                      // scroll view actually gets.
                      final panelDocked = _panelOpen &&
                          _refineTarget != null &&
                          constraints.maxWidth >= 900;
                      final bodyWidth = panelDocked
                          ? constraints.maxWidth - 401
                          : constraints.maxWidth;
                      // Symmetric gutter capping content at _contentMaxWidth;
                      // exactly the old 16px below the cap (+32 slack keeps
                      // the transition seamless), so phones are bit-identical.
                      final gutter = bodyWidth > _contentMaxWidth + 32
                          ? (bodyWidth - _contentMaxWidth) / 2
                          : 16.0;
                      // One derivation per input signature — a view-only
                      // setState (row select, expand/collapse, day chip…)
                      // rebuilds against the cached object instead of
                      // re-running the pipeline (Wave 4 PR1).
                      final derivation = _derive(trip);
                      // City-matched bookings render inside their city group;
                      // the rest fall through to the Bookings section's
                      // "Other" sub-group.
                      final legLabels = derivation.legLabels;
                      final grouped = derivation.groupedBookings;
                      final filtered = derivation.filtered;
                      final groups = derivation.groups;
                      // Shared per-build chip width — see _dateChipWidth's
                      // doc for why this must stay a build-local.
                      final dateChipWidth = _dateChipWidth(groups, theme);
                      // Groups default collapsed (empty _expandedCities); a
                      // sole group is seeded open once — a one-city trip
                      // collapsed to a single header line is an empty screen.
                      // One-shot so later groups (refine adds a city) arrive
                      // collapsed and the seeded one stays re-collapsible.
                      if (!_citySeedConsumed && groups.isNotEmpty) {
                        _citySeedConsumed = true;
                        if (groups.length == 1) {
                          _expandedCities.add(groups.first.key);
                        }
                      }
                      // Day-header GlobalKeys for the CURRENT groups' day
                      // keys, not just whatever happens to be built: a
                      // collapsed group's day headers don't exist yet, but
                      // their keys must still resolve so _scrollToDay can
                      // expand the group and land (specs/today-mode).
                      for (final key in derivation.liveDayKeys) {
                        _dayHeaderKeys.putIfAbsent(key, GlobalKey.new);
                      }
                      // Date window per city group, for the embedded events
                      // lookup (keyed by the same label the groups use).
                      final groupRanges = derivation.groupRanges;
                      final tripStart = DateTime.tryParse(trip.startDate ?? '');
                      // Map day chips (specs/today-mode). Day count spans the
                      // whole trip, not the category filter, so chips never
                      // come and go with the Attractions/Restaurants toggle.
                      final mapDayCount = derivation.mapDayCount;
                      // A stale out-of-range day selection (a refresh can
                      // shrink the trip) is clamped read-side by every
                      // consumer — see _clampedDay; build never writes it.
                      // Days that would plot something, so empty days (e.g.
                      // the fly-out day, all booking todos) get muted chips.
                      // Trip-wide like mapDayCount — the category filter never
                      // flickers the chip treatment.
                      final mappedDays = derivation.mappedDays;
                      // Today mode: the jump chip renders only when today
                      // falls inside the trip's dates AND some item carries a
                      // day tag (the same gate as the auto-scroll, so the
                      // chip never points at nothing).
                      final todayDay =
                          tripDayOn(trip.startDate, trip.endDate, DateTime.now());
                      final hasTodayTarget = todayDay != null &&
                          (trip.items ?? const <ItineraryItem>[])
                              .any((i) => i.day != null);
                      // Tonight caption (specs/happening-now): day numbers
                      // repeat across city groups (keys are '$groupKey#$day'),
                      // so resolve the FIRST group containing today's day
                      // once, here — exactly one caption can ever render.
                      // Matched on the run key, not the label: a revisited
                      // city has two runs sharing a label. todayDay is
                      // clock-derived, so it stays a build-local and queries
                      // the derivation.
                      final firstTodayGroupKey =
                          derivation.firstGroupKeyForDay(todayDay);
                      // A loud load queued the one-shot auto-scroll; this is
                      // the first frame that actually mounts the scroll view
                      // (and registers the day-header keys), so kick it off
                      // once this frame's layout is done.
                      final pendingToday = _pendingTodayScroll;
                      if (pendingToday != null) {
                        _pendingTodayScroll = null;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) _scrollToDay(pendingToday);
                        });
                      }
                      final scrollView = CustomScrollView(
                        controller: _scroll,
                        // Always scrollable: with the trailing sections
                        // collapsed to one-liners, a small trip fits inside
                        // the viewport — without this, no overscroll means
                        // pull-to-refresh could never arm.
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: [
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 0),
                            sliver: SliverToBoxAdapter(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _buildHeaderCard(trip, theme),
                                  const SizedBox(height: AppSpacing.lg),
                                ],
                              ),
                            ),
                          ),
                          // Wide: the map scrolls with the page until it
                          // reaches the top, then stays pinned while the
                          // itinerary scrolls beneath it. Phones have no room
                          // to pin — a shorter static preview scrolls away
                          // with the page, and tapping it opens the
                          // full-screen map (TripMapScreen).
                          if (derivation.mapShown)
                            if (_mapPinned)
                              SliverPersistentHeader(
                                pinned: true,
                                delegate: _PinnedHeaderDelegate(
                                  height: _mapHeaderHeight,
                                  backgroundColor:
                                      theme.scaffoldBackgroundColor,
                                  padding: EdgeInsets.fromLTRB(
                                      gutter, 12, gutter, 12),
                                  child: _mapCard(
                                      trip, l10n, mapDayCount, mappedDays,
                                      expandable: false),
                                ),
                              )
                            else
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: EdgeInsets.fromLTRB(
                                      gutter, 12, gutter, 12),
                                  child: SizedBox(
                                    height: _mapHeightNarrow,
                                    child: _mapCard(
                                        trip, l10n, mapDayCount, mappedDays,
                                        expandable: true),
                                  ),
                                ),
                              ),
                          // Itinerary title row; pins beneath the map so the
                          // Today jump, category filter, and Add place stay
                          // reachable while scrolling. The filter is a popup
                          // menu, not a chip row — one fixed-height row keeps
                          // the pinned chrome (and the Today scroll math)
                          // constant.
                          SliverPersistentHeader(
                            pinned: true,
                            delegate: _PinnedHeaderDelegate(
                              height: _listHeaderHeight,
                              backgroundColor: theme.scaffoldBackgroundColor,
                              padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 8),
                              // Align fills the header's full extent so the child's
                              // measured height matches maxExtent (a min-sized
                              // Column would be shorter, yielding an invalid sliver
                              // geometry: layoutExtent > paintExtent).
                              child: Align(
                                alignment: Alignment.topLeft,
                                child: SizedBox(
                                  height: 36,
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Row(
                                          children: [
                                            Flexible(
                                              child: Text(l10n.tripItinerary,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: theme
                                                      .textTheme.titleMedium),
                                            ),
                                            // Booking progress, relocated from
                                            // the retired Bookings section's
                                            // header. Flexible so it gives way
                                            // (ellipsis) before the row can
                                            // overflow on narrow widths.
                                            if (_bookingTodos.isNotEmpty) ...[
                                              const SizedBox(width: 8),
                                              // Tappable shortcut into the
                                              // all-bookings lens; idempotent
                                              // (the filter menu is the way
                                              // back out). Pure view work, so
                                              // not offline-gated. Padded so
                                              // the hit target fills the 36px
                                              // header row. Disabled on a
                                              // place-less trip: the
                                              // items-empty branch shadows
                                              // the lens there and the filter
                                              // menu (the only exit) is
                                              // hidden — the tap would trap
                                              // an invisible sticky lens.
                                              Flexible(
                                                child: Semantics(
                                                  button: true,
                                                  label: l10n
                                                      .tripBookingsLensCounterHint,
                                                  child: InkWell(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            8),
                                                    onTap: (trip.items ??
                                                                const <
                                                                    ItineraryItem>[])
                                                            .isEmpty
                                                        ? null
                                                        : () => setState(() {
                                                              _itemFilter =
                                                                  'bookings';
                                                              _bookingsLensDestination =
                                                                  null;
                                                            }),
                                                    child: Padding(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                          horizontal: 4,
                                                          vertical: 8),
                                                      child: Text(
                                                        l10n.bookingsSummaryProgress(
                                                            _bookingTodos
                                                                .where((t) =>
                                                                    t.booked)
                                                                .length,
                                                            _bookingTodos
                                                                .length),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: theme.textTheme
                                                            .bodySmall
                                                            ?.copyWith(
                                                                color: theme
                                                                    .colorScheme
                                                                    .onSurfaceVariant),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                      if (hasTodayTarget) ...[
                                        ActionChip(
                                          avatar: Icon(Icons.today,
                                              size: 16,
                                              color:
                                                  theme.colorScheme.primary),
                                          label: Text(l10n.tripToday),
                                          visualDensity:
                                              VisualDensity.compact,
                                          materialTapTargetSize:
                                              MaterialTapTargetSize
                                                  .shrinkWrap,
                                          // Pure view work (select +
                                          // expand + scroll): allowed
                                          // offline and while the refine
                                          // panel is open.
                                          onPressed: () {
                                            _selectedDay.value = todayDay;
                                            _scrollToDay(todayDay);
                                          },
                                        ),
                                        const SizedBox(width: 4),
                                      ],
                                      // Category filter (pure view work, so
                                      // never offline-gated). Tinted when a
                                      // filter is active — the only signal
                                      // the menu is narrowing the list.
                                      if ((trip.items ?? const [])
                                          .isNotEmpty)
                                        SizedBox(
                                          width: 36,
                                          height: 36,
                                          child: PopupMenuButton<String>(
                                            tooltip: l10n.tripFilterTooltip,
                                            padding: EdgeInsets.zero,
                                            icon: Icon(Icons.filter_list,
                                                size: 20,
                                                color: _itemFilter != 'all'
                                                    ? theme
                                                        .colorScheme.primary
                                                    : theme.colorScheme
                                                        .onSurfaceVariant),
                                            onSelected: (f) => setState(() {
                                              _itemFilter = f;
                                              _bookingsLensDestination = null;
                                            }),
                                            itemBuilder: (_) => [
                                              for (final f
                                                  in _itemFilters) ...[
                                                // The bookings lens sits
                                                // apart from the places
                                                // lenses above it.
                                                if (f == 'unbooked')
                                                  const PopupMenuDivider(),
                                                CheckedPopupMenuItem(
                                                  value: f,
                                                  checked: _itemFilter == f,
                                                  child: Text(
                                                      _filterLabel(l10n, f)),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      if (!_readOnly)
                                        TextButton.icon(
                                          onPressed: _isOffline
                                              ? null
                                              : _addPlace,
                                          style: TextButton.styleFrom(
                                            visualDensity:
                                                VisualDensity.compact,
                                          ),
                                          icon: const Icon(Icons.add,
                                              size: 18),
                                          label: Text(l10n.tripAddPlace),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if ((trip.items ?? []).isEmpty)
                            SliverPadding(
                              padding:
                                  EdgeInsets.symmetric(horizontal: gutter),
                              sliver: SliverToBoxAdapter(
                                child: SizedBox(
                                  height: 260,
                                  child: EmptyState(
                                    icon: Icons.place_outlined,
                                    title: l10n.tripNoPlacesYet,
                                    message: l10n.tripNoPlacesYetMessage,
                                  ),
                                ),
                              ),
                            )
                          else if (_itemFilter == 'unbooked')
                            // Bookings lens: a flat left-to-book list in
                            // place of the city groups (whose == 'all'
                            // guards would hide the booking rows).
                            SliverPadding(
                              padding:
                                  EdgeInsets.fromLTRB(gutter, 4, gutter, 0),
                              sliver: switch (_unbookedRows(grouped)) {
                                [] => SliverToBoxAdapter(
                                    child: SizedBox(
                                      height: 260,
                                      child: EmptyState(
                                        icon: Icons.celebration_outlined,
                                        title: l10n.tripFilterAllBooked,
                                        message:
                                            l10n.tripFilterAllBookedMessage,
                                      ),
                                    ),
                                  ),
                                final rows => _boxSliver(rows),
                              },
                            )
                          else if (_itemFilter == 'bookings')
                            // All-bookings lens: the whole trip's bookings
                            // (booked and unbooked) in place of the city
                            // groups, filterable by destination. One surface
                            // at a time — the inline rows render only under
                            // == 'all', so booked-state never shows on two
                            // surfaces at once (the PR #274 bar).
                            SliverPadding(
                              padding:
                                  EdgeInsets.fromLTRB(gutter, 4, gutter, 0),
                              sliver: switch (
                                  _bookingsLensBody(grouped, legLabels)) {
                                [] => SliverToBoxAdapter(
                                    child: SizedBox(
                                      height: 260,
                                      child: EmptyState(
                                        icon: Icons.book_online_outlined,
                                        title:
                                            l10n.tripBookingsLensEmptyTitle,
                                        message: l10n
                                            .tripBookingsLensEmptyMessage,
                                      ),
                                    ),
                                  ),
                                final body => _boxSliver(body),
                              },
                            )
                          else if (filtered.isEmpty)
                            SliverPadding(
                              padding:
                                  EdgeInsets.symmetric(horizontal: gutter),
                              sliver: SliverToBoxAdapter(
                                child: _FilterMissNotice(theme: theme),
                              ),
                            )
                          else
                            // Each city is a MultiSliver whose header pins
                            // beneath the filter bar while the city's items
                            // scroll past, then is pushed off by the next city;
                            // day headers nest the same way within each city.
                            SliverPadding(
                              padding:
                                  EdgeInsets.fromLTRB(gutter, 4, gutter, 0),
                              sliver: MultiSliver(children: [
                                for (final (gi, group) in groups.indexed)
                                  // A collapsed group is a plain scrolling
                                  // row, NOT a pinned header: pinning exists
                                  // so a header stays visible while its
                                  // content scrolls beneath it, and a
                                  // zero-body pinned group's paintOrigin
                                  // (= viewport overlap) poisons
                                  // MultiSliver's minPaintOrigin — every
                                  // collapsed header squishes, then
                                  // vanishes, as the pinned chrome scrolls
                                  // in. (pushPinnedChildren: false is no
                                  // fix either — the header would pin
                                  // forever and overlay the next group.)
                                  if (!_expandedCities.contains(group.key))
                                    SliverToBoxAdapter(
                                        child: KeyedSubtree(
                                            // Keyed by the run, not the city:
                                            // a revisited city renders two
                                            // headers at once and a shared
                                            // GlobalKey would break the build.
                                            key: _cityHeaderKeys.putIfAbsent(
                                                group.key, GlobalKey.new),
                                            child: _cityHeader(trip, group,
                                                theme, dateChipWidth)))
                                  else
                                    MultiSliver(
                                      pushPinnedChildren: true,
                                      children: [
                                        SliverPinnedHeader(
                                            child: KeyedSubtree(
                                                key: _cityHeaderKeys
                                                    .putIfAbsent(group.key,
                                                        GlobalKey.new),
                                                child: _cityHeader(trip, group,
                                                    theme, dateChipWidth))),
                                        // Embedded bookings render only in the
                                        // unfiltered view: a category filter can
                                        // merge adjacent same-label runs, which
                                        // would break the slot<->group mapping.
                                        if (_itemFilter == 'all' &&
                                            gi < grouped.slots.length)
                                          _boxSliver(_bookingRowWidgets(
                                              grouped.slots[gi],
                                              departureOnly: false)),
                                        ..._buildGroupItemSlivers(
                                            group.label,
                                            group.key,
                                            group.items,
                                            theme,
                                            tripStart,
                                            showTonight: group.key ==
                                                firstTodayGroupKey,
                                            range: groupRanges[group.label]),
                                        // Curated local recommendations for this
                                        // city — the "legit info you can't
                                        // google" surface. Leads the events
                                        // section; only in the unfiltered view.
                                        if (_itemFilter == 'all')
                                          _localIntelSliver(group.label, theme),
                                        // Local events for this city's dates —
                                        // only in the unfiltered view, where
                                        // group labels map 1:1 to date ranges.
                                        if (_itemFilter == 'all')
                                          _eventsSliver(
                                              group.label,
                                              groupRanges[group.label],
                                              theme),
                                        if (_itemFilter == 'all' &&
                                            gi == groups.length - 1 &&
                                            gi < grouped.slots.length)
                                          _boxSliver(_bookingRowWidgets(
                                              grouped.slots[gi],
                                              departureOnly: true)),
                                      ],
                                    ),
                              ]),
                            ),
                          // Residual bookings + add actions, at the tail of
                          // the itinerary. Only in the unfiltered view, like
                          // the embedded booking rows above — a category
                          // filter is a places lens, not a bookings one.
                          if (_itemFilter == 'all')
                            if (_otherBookingsArea(theme, (
                              residual: grouped.residual,
                              residualStays: grouped.residualStays,
                              residualSegments: grouped.residualSegments,
                            )) case final other?)
                              SliverPadding(
                                padding: EdgeInsets.fromLTRB(
                                    gutter, AppSpacing.sm, gutter, 0),
                                sliver: SliverToBoxAdapter(child: other),
                              ),
                          // Trailing sections, collapsed to one-line summary
                          // rows (settings-list rhythm: hairline dividers).
                          // One sliver for all three; the 96px bottom padding
                          // keeps the chat FAB off the last row. Each _xxx
                          // SectionRow hides itself exactly when its expanded
                          // section would (see the builders).
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(
                                gutter, AppSpacing.sm, gutter, 96),
                            sliver: SliverToBoxAdapter(
                              child: _sectionCluster([
                                  // Health first: it carries actionable state
                                  // (the review pill), so it's met right after
                                  // the itinerary; empty Packing/Budget rows
                                  // trail at the true page bottom.
                                  _healthSectionRow(trip, theme),
                                  _packingSectionRow(trip, theme),
                                  _budgetSectionRow(trip, theme),
                                ]),
                            ),
                          ),
                        ],
                      );

                      // Pull-to-refresh: with async co-editing, this is how a
                      // user picks up a collaborator's latest changes.
                      Widget refreshable = RefreshIndicator(
                        onRefresh: _refresh,
                        child: scrollView,
                      );
                      // Offline: the trip on screen is a cached copy — pin
                      // the banner above it. Retry takes the loud load path,
                      // which exits offline mode on success or re-serves the
                      // copy on another network failure.
                      final offlineSince = _offlineSince;
                      if (offlineSince != null) {
                        refreshable = Column(
                          children: [
                            OfflineBanner(
                                savedAt: offlineSince, onRetry: _load),
                            Expanded(child: refreshable),
                          ],
                        );
                      }

                      if (!_panelOpen || _refineTarget == null) {
                        return refreshable;
                      }
                      final panel = TripRefinePanel(
                        tripId: widget.tripId,
                        target: _refineTarget!,
                        onClose: () => setState(() => _panelOpen = false),
                        onTripUpdated: _refresh,
                      );
                      if (panelDocked) {
                        // Wide: dock the chat beside the itinerary.
                        return Row(
                          children: [
                            Expanded(child: refreshable),
                            const VerticalDivider(width: 1),
                            SizedBox(width: 400, child: panel),
                          ],
                        );
                      }
                      // Narrow: collapsible bottom sheet over the page; bottom
                      // inset keeps the input above the keyboard.
                      return Stack(
                        children: [
                          refreshable,
                          DraggableScrollableSheet(
                            initialChildSize: 0.45,
                            minChildSize: 0.15,
                            maxChildSize: 0.92,
                            snap: true,
                            builder: (context, scrollController) => Material(
                              elevation: 8,
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(16)),
                              clipBehavior: Clip.antiAlias,
                              child: Padding(
                                padding: EdgeInsets.only(
                                    bottom: MediaQuery.of(context)
                                        .viewInsets
                                        .bottom),
                                child: Column(
                                  children: [
                                    // Drag handle (also a scrollable so the
                                    // sheet responds to drags at its header).
                                    SingleChildScrollView(
                                      controller: scrollController,
                                      child: Center(
                                        child: Container(
                                          width: 36,
                                          height: 4,
                                          margin: const EdgeInsets.symmetric(
                                              vertical: 8),
                                          decoration: BoxDecoration(
                                            color: theme
                                                .colorScheme.outlineVariant,
                                            borderRadius:
                                                BorderRadius.circular(2),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Expanded(child: panel),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    }),
      );
    });
  }

  /// The open action for a booking item: a transport item with a known flight
  /// leg opens the in-app Find Flights screen prefilled; everything else falls
  /// back to its external provider search link.
  VoidCallback? _openCallbackFor(BookingTodo todo) {
    // The attach-rate numerator (specs/instrumentation-events): opening any
    // booking handoff counts as a click. External links record-then-launch via
    // trackedLaunchUrl; the one in-app handoff (Find Flights) records via the
    // same helper before navigating. Fire-and-forget either way.
    if (todo.kind == 'transport') {
      final ferry = _ferryLegs[todo.todoKey];
      if (ferry != null) {
        return () => _openFerry(ferry, todo);
      }
      final leg = _flightLegs[todo.todoKey];
      if (leg != null) {
        return () {
          trackBookingLinkClick(
            context,
            provider: 'duffel',
            surface: 'booking_checklist',
            tripId: widget.tripId,
            todoKey: todo.todoKey,
            kind: todo.kind,
          );
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => FlightSearchScreen(
              prefillOrigin: leg.origin,
              prefillDestination: leg.destination,
              prefillDepartDate: leg.date,
              prefillOriginCoord: leg.originCoord,
              prefillDestinationCoord: leg.destCoord,
            ),
          ));
        };
      }
    }
    if (todo.searchUrl != null) {
      return () async {
        // Captured before the await: the widget can unmount while the launch
        // is in flight, and an inherited-widget lookup would then throw.
        final failedMessage = context.l10n.tripOpenLinkFailed;
        final ok = await trackedLaunchUrl(
          context,
          todo.searchUrl!,
          provider: (todo.provider ?? 'unknown').toLowerCase(),
          surface: 'booking_checklist',
          tripId: widget.tripId,
          todoKey: todo.todoKey,
          kind: todo.kind,
        );
        if (!ok) _showSnack(failedMessage);
      };
    }
    return null;
  }

  /// Opens the Ferryhopper search for a ferry leg. The booking URL (with the
  /// correct port codes) is built server-side, so we fetch it on tap — a single
  /// quick GET — keeping the port-code map a single source of truth in the API.
  Future<void> _openFerry(
      ({String origin, String destination, String? date}) leg,
      BookingTodo todo) async {
    final l10n = context.l10n;
    try {
      final options = await ref.read(ferryApiServiceProvider).searchFerries(
            leg.origin,
            leg.destination,
            date: leg.date,
          );
      if (!mounted) return;
      if (options.isNotEmpty && options.first.bookingUrl.isNotEmpty) {
        final ok = await trackedLaunchUrl(
          context,
          options.first.bookingUrl,
          provider: 'ferryhopper',
          surface: 'booking_checklist',
          tripId: widget.tripId,
          todoKey: todo.todoKey,
          kind: todo.kind,
        );
        if (!ok) _showSnack(l10n.tripOpenLinkFailed);
        return;
      }
    } catch (_) {
      // fall through to the generic failure snack
    }
    _showSnack(l10n.tripFerrySearchFailed);
  }

  // Raw launcher for non-booking links only (the per-item "Open in Google
  // Maps" action) — booking handoffs must go through trackedLaunchUrl.
  Future<void> _launch(String url) async {
    final l10n = context.l10n;
    final ok =
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok) _showSnack(l10n.tripOpenLinkFailed);
  }
}

/// Adds or edits a custom booking TODO. A destination (and optional dates)
/// lets the server build the search link; a pasted link overrides it.
class _AddBookingTodoDialog extends ConsumerStatefulWidget {
  final String tripId;

  /// When set, the dialog edits this todo (PATCH) instead of adding one.
  /// Destination/origin aren't persisted server-side, so they open blank:
  /// re-entering a destination makes the server rebuild the search link,
  /// otherwise the existing link is kept.
  final BookingTodo? existing;

  /// The trip's stated non-flight travel mode ('car'|'train'|'bus'|'ferry'):
  /// new transport todos then prefer the Rome2Rio link over Google Flights.
  final String? groundMode;

  const _AddBookingTodoDialog(
      {required this.tripId, this.existing, this.groundMode});

  @override
  ConsumerState<_AddBookingTodoDialog> createState() =>
      _AddBookingTodoDialogState();
}

class _AddBookingTodoDialogState extends ConsumerState<_AddBookingTodoDialog> {
  String _kind = 'stay';
  final _title = TextEditingController();
  final _destination = TextEditingController();
  final _origin = TextEditingController();
  DateTime? _departDate;
  DateTime? _returnDate;
  final _url = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _kind = e.kind;
      _title.text = e.title;
      _url.text = e.searchUrl ?? '';
      _departDate = DateTime.tryParse(e.departDate ?? '');
      _returnDate = DateTime.tryParse(e.returnDate ?? '');
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _destination.dispose();
    _origin.dispose();
    _url.dispose();
    super.dispose();
  }

  String? _nn(String s) {
    final t = s.trim();
    return t.isEmpty ? null : t;
  }

  String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate(bool isDepart) async {
    final now = DateTime.now();
    final first = now.subtract(const Duration(days: 365));
    final last = now.add(const Duration(days: 365 * 2));
    var initial = (isDepart ? _departDate : _returnDate) ?? now;
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (picked != null) {
      setState(() => isDepart ? _departDate = picked : _returnDate = picked);
    }
  }

  Future<void> _save() async {
    final l10n = context.l10n;
    if (_title.text.trim().isEmpty) {
      setState(() => _error = l10n.tripTitleRequired);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final isTransport = _kind == 'transport';
      final isEdit = widget.existing != null;
      // Note: PATCH is a COALESCE partial update, so an omitted date can't
      // clear a previously saved one — it just keeps the old value.
      final body = <String, dynamic>{
        'kind': _kind,
        'title': _title.text.trim(),
        if (_nn(_destination.text) != null)
          'destination': _nn(_destination.text),
        if (isTransport && _nn(_origin.text) != null)
          'origin': _nn(_origin.text),
        if (_departDate != null) 'depart_date': _fmt(_departDate!),
        if (!isTransport && _returnDate != null)
          'return_date': _fmt(_returnDate!),
        // On edit the field is prefilled with the stored link; sending it
        // back unchanged would override a destination-driven rebuild (an
        // explicit search_url wins server-side), so omit it unless the user
        // actually changed it — COALESCE keeps the stored one.
        if (_nn(_url.text) != null &&
            (!isEdit || _nn(_url.text) != widget.existing!.searchUrl))
          'search_url': _nn(_url.text),
        // The provider is only a preference for the server's link builder; on
        // edit, sending it without a destination would overwrite the stored
        // provider while the old link stays — so only send it when a link is
        // (re)built from a destination.
        if (!isEdit || _nn(_destination.text) != null) ...{
          if (_kind == 'stay') 'provider': 'airbnb',
          if (isTransport)
            'provider':
                widget.groundMode != null ? 'rome2rio' : 'google_flights',
        },
        'guests': 1,
        'passengers': 1,
      };
      final svc = ref.read(bookingTodosApiServiceProvider);
      if (isEdit) {
        await svc.update(widget.tripId, widget.existing!.id, body);
      } else {
        await svc.addTodo(widget.tripId, body);
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = l10n.tripSaveFailed(friendlyError(l10n, e));
      });
    }
  }

  /// A picker-backed date row: tap to pick, with a clear button when set
  /// (both dates are optional).
  Widget _dateField(String label, bool isDepart) {
    final value = isDepart ? _departDate : _returnDate;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.event, size: 18),
            label: Align(
              alignment: Alignment.centerLeft,
              child: Text(value == null ? label : '$label: ${_fmt(value)}'),
            ),
            onPressed: () => _pickDate(isDepart),
          ),
        ),
        if (value != null)
          IconButton(
            icon: const Icon(Icons.clear, size: 18),
            tooltip: context.l10n.tripClearDate,
            onPressed: () => setState(() =>
                isDepart ? _departDate = null : _returnDate = null),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isTransport = _kind == 'transport';
    return AlertDialog(
      title: Text(widget.existing == null
          ? l10n.tripAddBooking
          : l10n.tripEditBooking),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _kind,
              decoration: InputDecoration(labelText: l10n.tripFieldType),
              items: [
                DropdownMenuItem(
                    value: 'stay', child: Text(l10n.tripKindStay)),
                DropdownMenuItem(
                    value: 'transport', child: Text(l10n.tripKindTransport)),
                DropdownMenuItem(
                    value: 'other', child: Text(l10n.tripKindOther)),
              ],
              onChanged: (v) => setState(() => _kind = v ?? 'stay'),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
                controller: _title,
                decoration: InputDecoration(labelText: l10n.tripFieldTitle)),
            const SizedBox(height: AppSpacing.md),
            if (isTransport) ...[
              TextField(
                  controller: _origin,
                  decoration:
                      InputDecoration(labelText: l10n.tripFieldOrigin)),
              const SizedBox(height: AppSpacing.md),
            ],
            TextField(
                controller: _destination,
                decoration:
                    InputDecoration(labelText: l10n.tripFieldDestination)),
            const SizedBox(height: AppSpacing.md),
            _dateField(
                isTransport
                    ? l10n.tripFieldDepartDate
                    : l10n.tripFieldCheckIn,
                true),
            if (!isTransport) ...[
              const SizedBox(height: AppSpacing.sm),
              _dateField(l10n.tripFieldCheckOut, false),
            ],
            const SizedBox(height: AppSpacing.md),
            TextField(
                controller: _url,
                decoration: InputDecoration(labelText: l10n.tripFieldLink)),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel)),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(l10n.commonSave),
        ),
      ],
    );
  }
}

/// Compact, centered notice shown when a category filter hides every item — a
/// lighter touch than the full empty state since the fix (clearing the filter)
/// is right above it.
class _FilterMissNotice extends StatelessWidget {
  final ThemeData theme;
  const _FilterMissNotice({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
      child: Column(
        children: [
          Icon(
            Icons.filter_alt_off_outlined,
            size: 32,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            context.l10n.tripFilterNoMatch,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
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

/// A fixed-height header that scrolls with the page until it reaches the top,
/// then stays pinned. Used for the trip map and, stacked beneath it, the
/// itinerary filter bar. The opaque [backgroundColor] fill keeps list content
/// from peeking through the [padding] (side margins and gaps) while pinned.
class _PinnedHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double height;
  final Color backgroundColor;
  final EdgeInsetsGeometry padding;
  final Widget child;

  const _PinnedHeaderDelegate({
    required this.height,
    required this.backgroundColor,
    required this.padding,
    required this.child,
  });

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
          BuildContext context, double shrinkOffset, bool overlapsContent) =>
      Container(
        color: backgroundColor,
        padding: padding,
        child: child,
      );

  @override
  bool shouldRebuild(_PinnedHeaderDelegate oldDelegate) =>
      oldDelegate.child != child ||
      oldDelegate.height != height ||
      oldDelegate.backgroundColor != backgroundColor ||
      oldDelegate.padding != padding;
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

/// Owner-only bottom sheet: lists active co-planners with per-person removal.
/// Removal revokes their access immediately; the invite link (if still on)
/// would let them rejoin, so the empty state reminds the owner of that.
class _CoPlannersSheet extends ConsumerStatefulWidget {
  final String tripId;
  final VoidCallback onRemoved;
  final void Function(String email) onInvited;
  const _CoPlannersSheet(
      {required this.tripId, required this.onRemoved, required this.onInvited});

  @override
  ConsumerState<_CoPlannersSheet> createState() => _CoPlannersSheetState();
}

class _CoPlannersSheetState extends ConsumerState<_CoPlannersSheet> {
  List<({String userId, String displayName, String email, String role})>?
      _collaborators;
  List<({String id, String email, DateTime expiresAt})>? _invites;
  final _emailController = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    try {
      final service = ref.read(tripsApiServiceProvider);
      final results = await Future.wait([
        service.listCollaborators(widget.tripId),
        service.listInvites(widget.tripId),
      ]);
      if (mounted) {
        setState(() {
          _collaborators = results[0]
              as List<({String userId, String displayName, String email, String role})>;
          _invites =
              results[1] as List<({String id, String email, DateTime expiresAt})>;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _sendInvite() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await ref.read(tripsApiServiceProvider).createInvite(widget.tripId, email);
      _emailController.clear();
      widget.onInvited(email);
      await _loadAll();
    } catch (e) {
      if (mounted) {
        setState(() =>
            _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _revokeInvite(String inviteId) async {
    try {
      await ref.read(tripsApiServiceProvider).revokeInvite(widget.tripId, inviteId);
      await _loadAll();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _remove(String userId) async {
    try {
      await ref
          .read(tripsApiServiceProvider)
          .removeCollaborator(widget.tripId, userId);
      widget.onRemoved();
      await _loadAll();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  String _expiresIn(DateTime expiresAt) {
    final l10n = context.l10n;
    final d = expiresAt.difference(DateTime.now());
    if (d.inDays >= 1) return l10n.tripExpiresInDays(d.inDays);
    if (d.inHours >= 1) return l10n.tripExpiresInHours(d.inHours);
    return l10n.tripExpiresSoon;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final collaborators = _collaborators;
    final invites = _invites;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: AppSpacing.lg,
          right: AppSpacing.lg,
          top: AppSpacing.lg,
          // Keep the email field above the keyboard.
          bottom: AppSpacing.lg + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.tripManageAccess, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            // Invite by email (specs/invite-by-email): the friend gets a
            // single-use link; they appear below once they accept.
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: InputDecoration(
                      hintText: l10n.tripFriendEmail,
                      isDense: true,
                      prefixIcon:
                          const Icon(Icons.alternate_email, size: 18),
                    ),
                    onSubmitted: (_) => _sendInvite(),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton.tonal(
                  onPressed: _sending ? null : _sendInvite,
                  child: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(l10n.tripInvite),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (_error != null)
              Text(_error!, style: TextStyle(color: theme.colorScheme.error))
            else if (collaborators == null || invites == null)
              const Center(child: CircularProgressIndicator())
            else ...[
              if (collaborators.isEmpty && invites.isEmpty)
                Text(
                  l10n.tripNoCoPlanners,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              for (final c in collaborators)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                      child: Icon(
                          c.role == 'viewer'
                              ? Icons.visibility_outlined
                              : Icons.person,
                          size: 18)),
                  title: Text(
                      c.displayName.isNotEmpty ? c.displayName : c.email),
                  subtitle: Text([
                    if (c.displayName.isNotEmpty) c.email,
                    c.role == 'viewer'
                        ? l10n.tripRoleViewer
                        : l10n.tripRoleCanEdit,
                  ].join(' · ')),
                  trailing: IconButton(
                    icon: const Icon(Icons.person_remove_outlined),
                    tooltip: l10n.tripRemoveAccess,
                    onPressed: () => _remove(c.userId),
                  ),
                ),
              if (invites.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(l10n.tripPendingInvites,
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                for (final inv in invites)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const CircleAvatar(
                        child: Icon(Icons.mail_outline, size: 18)),
                    title: Text(inv.email),
                    subtitle:
                        Text(l10n.tripInvited(_expiresIn(inv.expiresAt))),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: l10n.tripRevokeInvite,
                      onPressed: () => _revokeInvite(inv.id),
                    ),
                  ),
              ],
            ],
          ],
        ),
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

/// The trip overview paragraph with its "Show more/less" toggle — a
/// self-contained leaf so expanding it rebuilds this block, never the
/// screen that hosts it. Collapsed = 2 lines; the toggle only renders for
/// text long enough to plausibly clip (same 140-char heuristic as before).
class _OverviewText extends StatefulWidget {
  final String text;
  final TextStyle? style;

  const _OverviewText({required this.text, this.style});

  @override
  State<_OverviewText> createState() => _OverviewTextState();
}

class _OverviewTextState extends State<_OverviewText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.text,
          style: widget.style,
          maxLines: _expanded ? null : 2,
          overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
        ),
        if (widget.text.length > 140)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? l10n.tripShowLess : l10n.tripShowMore),
            ),
          ),
      ],
    );
  }
}
