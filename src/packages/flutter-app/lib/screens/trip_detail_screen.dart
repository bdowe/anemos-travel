import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
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
import '../providers/plan_resume.dart';
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
import '../services/api_client.dart' show isTransientError;
import '../services/trip_cache.dart';
import '../services/trips_api_service.dart' show TripEndpointsException;
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../utils/calendar_links.dart';
import '../utils/clothing_recs.dart';
import '../utils/date_formats.dart';
import '../utils/event_picks.dart';
import '../utils/leg_parity.dart';
import '../utils/money_format.dart';
import '../utils/share_link.dart';
import '../utils/tracked_launch.dart';
import '../utils/trip_days.dart';
import '../utils/travel_mode.dart';
import '../utils/trip_format.dart';
import '../utils/trip_legs.dart';
import '../widgets/add_itinerary_item_dialog.dart';
import '../widgets/add_to_trip_sheet.dart';
import '../services/api_client.dart' show ApiException;
import '../widgets/booked_expense_prompt.dart';
import '../widgets/booking_detail_row.dart';
import '../widgets/booking_filter_bar.dart';
import '../widgets/booking_sheets.dart';
import '../widgets/booking_todo_card.dart';
import '../widgets/budget_section.dart';
import '../widgets/budget_target_dialog.dart';
import '../widgets/trip_health_sheet.dart';
import '../widgets/trip_review_section.dart';
import '../widgets/empty_state.dart';
import '../widgets/city_events_sheet.dart';
import '../widgets/hover_reveal.dart';
import '../widgets/local_rec_card.dart';
import '../widgets/offline_banner.dart';
import '../widgets/place_photo_card.dart';
import '../widgets/source_links_card.dart';
import '../widgets/status_pill.dart';
import '../widgets/trip_actions_sheet.dart';
import '../widgets/trip_airports_sheet.dart';
import '../widgets/trip_details_dialog.dart';
import '../widgets/trip_refine_panel.dart';
import '../widgets/wear_pack_sheet.dart';
import 'flight_search_screen.dart';
import 'local_guide_detail_screen.dart';
import 'trip_detail_derivation.dart';
import 'trip_map_screen.dart';
import '../widgets/trip_detail/trip_header_card.dart';
import '../widgets/trip_detail/map_band.dart';
import '../utils/snack.dart';
part '../widgets/trip_detail/itinerary_tab.dart';
part '../widgets/trip_detail/bookings_tab.dart';

/// A geographic coordinate used to resolve an itinerary place to its nearest
/// bookable airport when the place name has no IATA match.
typedef _Coord = ({double lat, double lng});

/// The dates a derived transport leg actually knows, and — crucially — which of
/// them may be presented as a DEPARTURE.
///
///  * A leg with a confirmed segment carries whatever that segment says. A
///    transatlantic red-eye departs the calendar day BEFORE the trip starts.
///  * An inter-city or return leg without one carries a departure: the
///    itinerary's own model is that you leave a city on its last day.
///  * The OUTBOUND home leg without one carries only an arrival. There is no
///    leg before the first city, so the itinerary knows the day the traveler
///    lands and nothing about the day they left home — and saying "Aug 24"
///    under "EWR → Amsterdam" asserts a departure that, for an overnight
///    flight, is simply false.
typedef _LegDates = ({DateTime? depart, DateTime? arrive});

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
  /// setState pass-through for the part-file extensions (specs/
  /// trip-detail-extract): [State.setState] is protected, so extension
  /// members can't call it directly. Identical semantics — same object,
  /// same closure, same rebuild.
  void _rebuild(VoidCallback fn) => setState(fn);

  Trip? _trip;
  bool _loading = true;
  // The raw caught load error (not a string): the error screen classifies it
  // via friendlyError(l10n, ...) so a 429 reads differently from a 500.
  Object? _error;
  // Non-null while _trip is a cached copy served because the network was
  // unreachable (value = when the copy was saved). The screen is read-only
  // in this mode; a successful live load clears it.
  DateTime? _offlineSince;
  // In-page AI refinement panel (side dock on wide layouts, bottom sheet on
  // narrow ones). This bool is ALL the panel's screen state: the header derives
  // from the conversation itself, so back has exactly one thing to undo
  // (specs/trip-refine-memory).
  bool _panelOpen = false;

  // Where the trip's saved conversation is in its restore. `_chatResumeTried`
  // makes the fetch once-per-screen so a 404 doesn't refetch on every tap.
  RefineChatPhase _chatPhase = RefineChatPhase.ready;
  Object? _chatError;
  bool _chatResumeTried = false;

  // The active view state. 'all' renders the grouped itinerary; 'bookings'
  // and 'unbooked' are the Bookings view (entered from the header tab) and
  // its left-to-book scope (the chip inside that view) — both replace the
  // city groups with flat booking rows; 'budget' is the Budget view (third
  // header tab), which replaces them with the budget body. Tab selection is
  // DERIVED from this one string every build — never stored as its own
  // field (PR #335's invariant).
  String _itemFilter = 'all';
  // Destination chip selection inside the 'bookings' lens (null = All).
  // Reset on every lens change so the lens always opens at All; clamped in
  // _bookingsLensBody against the current leg labels (edits can stale it).
  String? _bookingsLensDestination;

  /// Whether the Bookings view (header tab) is active. Either lens state
  /// replaces the grouped itinerary with flat booking rows, so the tab
  /// highlight and the Today-scroll force-exit treat them as one view.
  bool get _inBookingsView =>
      _itemFilter == 'unbooked' || _itemFilter == 'bookings';

  /// Whether the Budget view (third header tab) is active.
  bool get _inBudgetView => _itemFilter == 'budget';

  /// Travel-time labels for whichever map is being built: empty in the
  /// Bookings/Budget views, whose map stays label-free (the pre-existing
  /// behavior from when the derivation view-gated these). The ONE gate for
  /// both map call sites — inline card and full-screen.
  Map<int, String> _mapSegmentLabels(TripDerivation d) =>
      (_inBookingsView || _inBudgetView) ? const {} : d.segmentLabels;
  // Focused leg on the map; null = All. MAP-ONLY state (chips, camera fit,
  // per-leg item/stay filtering) — group expansion is _collapsedGroups,
  // fully decoupled. Keyed by the FULL-itinerary run key (leg.key,
  // `#2`-suffixed on revisits). A ValueNotifier consumed solely by the map
  // card's ListenableBuilder, so a focus write never rebuilds the screen
  // and a same-value write is dropped. May hold a stale key after an edit
  // removes the leg — readers clamp via _clampedLegKey (read-side, so
  // build never mutates state).
  final ValueNotifier<String?> _focusedLegKey = ValueNotifier<String?>(null);
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
  // _collapsedDays; cities are keyed by run key (group.key), the same
  // keyspace as _collapsedGroups.
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
  // Group expansion is LIST-ONLY state, fully decoupled from map focus
  // (this supersedes the specs/map-city-focus accordion, where the open
  // group was derived from the focused leg): _collapsedGroups is inverted
  // like _collapsedDays — empty = ALL groups expanded, the landing default —
  // and keyed by GROUP key (group.key run keys, `#2`-suffixed on revisits;
  // the _cityHeaderKeys keyspace). A header tap toggles only its group and
  // never touches the map; chip taps and map region-pin taps un-collapse
  // their target on the way to it. Session-only, never pruned: a key staled
  // by a lens switch or an edit just misses contains() and the group renders
  // expanded — the safe default. Days stay inverted the same way, keyed
  // "<cityKey>#<day>" since day numbers repeat across cities.
  final Set<String> _collapsedGroups = {};
  final Set<String> _collapsedDays = {};
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
  // todo_key -> the leg's known dates, for EVERY transport row (flight, ferry
  // and ground alike, unlike the two maps above). Read by "Add details…" so the
  // sheet prefills what the app actually knows: on a leg with no recorded
  // flight the departure field opens BLANK rather than pre-filled with the
  // arrival day, which is the wrong day to hand a traveler for confirmation.
  Map<String, _LegDates> _legDates = {};
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
    _focusedLegKey.dispose();
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
        // Under setState: the map's home overlay reads _homeAirport, and a
        // prefs load that lands after the first build must trigger its own
        // rebuild — riding on _syncBookingTodos' setState left the overlay
        // permanently absent whenever that sync was skipped (empty trip) or
        // failed.
        final home = ref.read(preferencesProvider).prefs?.homeAirport;
        if (mounted && home != _homeAirport) {
          setState(() => _homeAirport = home);
        }
        if (mounted && (trip.items ?? const []).isNotEmpty) {
          await _syncBookingTodos(trip);
        }
      }

      await Future.wait([
        if (mounted && (trip.items ?? const []).isNotEmpty)
          _computeTravelTimes(trip),
        syncTodosAfterPrefs(),
      ]);
      // Trip Health is a SEPARATE fetch (GET /trips/{id}/review) behind a
      // non-autoDispose provider, so nothing expires it on its own — leaving
      // the screen and coming back re-reads the same cached answer. Every
      // mutation on this screen ends here, so this is the one place that can
      // promise the badge, the sheet and the Next Step card describe the trip
      // that was just loaded. It used to be the caller's job, and eight of
      // them didn't do it: adding a stay from the Bookings view left "no
      // lodging booked" on screen next to the stay you had just added. The
      // booking-todo sync's own invalidate was no help — it only fired when
      // the DERIVED todo set changed, and a new accommodation changes no todo
      // key and no booked flag.
      if (mounted) _invalidateReview();
    } catch (e) {
      // Loud path: fall back to the cached copy and render it read-only for
      // network-level failures AND transient HTTP failures (429/502/503/504
      // surviving send()'s own retries) — a rate-limited boot with a good
      // cached copy must not dead-end on an error screen. Stable HTTP errors
      // (403/404/500) never match either predicate, so a revoked or deleted
      // trip can't resurrect from a stale copy.
      if (mounted && !quiet &&
          (TripCache.isNetworkError(e) || isTransientError(e))) {
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
      if (mounted && !quiet) setState(() => _error = e);
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

  /// Item ids as they stood before something the traveler ASKED FOR started
  /// writing — armed by [_armRevealOfNewItems], consumed by [_refresh] once
  /// its coalescing loop has settled. Null on every other refresh (the
  /// background status poll, the chat-delete cleanup), which is what keeps a
  /// collaborator's edit from unfolding a list you deliberately folded.
  Set<String>? _revealBaseline;

  /// Arms the next [_refresh] to reveal whatever it brings in.
  ///
  /// Idempotent across a streaming turn: the FIRST snapshot wins. A second
  /// `trip_updated` landing mid-fetch must not redefine "new" as "added after
  /// the batch I already missed" — one turn is one baseline.
  void _armRevealOfNewItems() {
    if (_revealBaseline != null) return;
    final trip = _trip;
    if (trip == null) return;
    _revealBaseline = {
      for (final i in trip.items ?? const <ItineraryItem>[]) i.id
    };
  }

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
        // The budget lives outside the trip payload in its own two
        // providers; refetch it alongside so pull-to-refresh (and the
        // trip_updated bump a collaborator's budget edit fires via
        // TouchTrip) picks up spend changes. skipLoadingOnReload keeps the
        // current values on screen — no flash.
        ref.invalidate(budgetProvider(widget.tripId));
        ref.invalidate(expensesProvider(widget.tripId));
        // The health review rides along inside _load, which owns that
        // invalidation for every path — including this one, so the badge and
        // Next Step card advance behind an open panel rather than on the next
        // cold load.
        await _load(silent: true);
      } while (mounted && _refreshQueued);
      // AFTER the loop, not inside it: a turn that writes three times in a
      // row should reveal once, against the state the turn started from.
      final baseline = _revealBaseline;
      _revealBaseline = null;
      if (mounted && baseline != null) _revealNewItems(baseline);
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

  // Itinerary/Bookings/Budget tab row (44 — real touch targets for the view
  // tabs)
  // + bottom padding (8) + breathing room (4); the header is one
  // fixed-height row whether or not the trip has items.
  static const double _listHeaderHeight = 56;

  /// Combined height of the chrome pinned above the itinerary slivers: the
  /// map header (when it renders AND is pinned — on phones the map scrolls
  /// away, so it never rests above a target header) plus the itinerary
  /// title header. This is the resting-slot measurement for the scroll
  /// helpers' correction passes ONLY — never subtract it from a
  /// getOffsetToReveal result, which already accounts for these extents
  /// (`maxScrollObstructionExtentBefore`).
  double _pinnedChrome(Trip trip) {
    final mapShown = _derive(trip).mapShown;
    return ((_mapPinned && mapShown) ? mapBandHeaderHeight : 0) +
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
  /// focus preselection lands in the same frame as the trip. Never called
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
    // Map preselect: the leg holding today's items, set before the first
    // paint so the camera doesn't hop All → today one frame later.
    // Exact-day match only — an untagged today leaves the default (All)
    // and the pending scroll's nearest-day fallback selects. Map-only:
    // groups land expanded by default, so there is nothing to open.
    final d = _derive(trip);
    final todayLeg = d.legKeyForDay(today);
    if (todayLeg != null) _setMapFocus(d, todayLeg);
    // The scroll itself waits for the first build that actually shows the
    // scroll view: this setState still renders the loading spinner (the
    // loud path clears _loading later, in its finally), so a post-frame
    // callback scheduled here could fire before the CustomScrollView exists.
    _pendingTodayScroll = today;
  }

  /// Scrolls the itinerary so [day]'s header rests just below the pinned
  /// chrome (map + title + city header). Missing headers fall back to the
  /// nearest prior day, then the nearest following; a collapsed city/day is
  /// expanded first, and a bookings lens or the Budget view (both swap the
  /// city groups out entirely, so no day header could ever build) is exited
  /// back to the full itinerary — the Today chip and health day-links read
  /// as "show me that day". Pure view work — safe offline and with the
  /// panel open.
  void _scrollToDay(int day) {
    final trip = _trip;
    if (trip == null) return;
    final dayKey = _resolveDayHeaderKey(day);
    if (dayKey == null) return;
    final cityKey = dayKey.substring(0, dayKey.lastIndexOf('#'));
    final inAltView = _inBookingsView || _inBudgetView;
    final d = _derive(trip);
    // "Show me that day" focuses the MAP on that day's leg and un-collapses
    // its group/day so the header can be measured. cityKey is a GROUP key
    // from liveDayKeys, and groups and legs run the same split, so it
    // doubles as the leg key — clamped in case an edit staled it mid-jump.
    // Bookings lenses and the Budget view keep the places set whole, so the
    // pre-exit derivation's groups are the post-exit ones too.
    final legKey = d.legIndexOf(cityKey) == null ? null : cityKey;
    // Whether the target section still has layout work to settle before
    // the scroll can measure it (a collapsed group/day opening, or the
    // lens swap rebuilding the list).
    final needsLayout = inAltView ||
        _collapsedGroups.contains(cityKey) ||
        _collapsedDays.contains(dayKey);
    if (needsLayout) {
      setState(() {
        if (inAltView) {
          _itemFilter = 'all';
          _bookingsLensDestination = null;
        }
        _collapsedGroups.remove(cityKey);
        _collapsedDays.remove(dayKey);
      });
    }
    if (legKey != null) _setMapFocus(d, legKey); // no-op if already selected
    if (needsLayout) {
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
  /// MultiSliver, so compute the reveal offset, animate, then run exactly
  /// one correction pass against the header's actual on-screen position.
  ///
  /// `getOffsetToReveal(target, 0)` already rests the target below the
  /// viewport-level pinned chrome: it subtracts the summed obstruction of
  /// the pinned viewport children before the target's sliver
  /// (`maxScrollObstructionExtentBefore`) — exactly [_pinnedChrome], so
  /// subtracting that here again would animate 56–420px past the target
  /// and leave the correction pass to snap back every time (the
  /// up-then-down jank). Only the city SliverPinnedHeader needs manual
  /// subtraction: it sits INSIDE the group's SliverPadding→MultiSliver
  /// viewport child and the obstruction walk never descends into a child
  /// sliver. (That SliverPadding reporting 0 obstruction is also what
  /// keeps getOffsetToReveal's isPinned→infinity branch unreachable for
  /// these targets — don't unwrap it.)
  Future<void> _scrollToDayHeader(String dayKey) async {
    final trip = _trip;
    if (!mounted || trip == null || !_scroll.hasClients) return;
    final target = _dayHeaderKeys[dayKey]?.currentContext?.findRenderObject();
    if (target == null || !target.attached) return;
    final viewport = RenderAbstractViewport.maybeOf(target);
    if (viewport == null) return;
    final reveal = viewport.getOffsetToReveal(target, 0).offset -
        _cityHeaderHeight(dayKey);
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

  /// THE writer for map focus, and ONLY map focus — group expansion is
  /// [_collapsedGroups], never touched here. No setState: the chips and
  /// camera both render inside the map card's ListenableBuilder, and the
  /// notifier drops same-value writes (re-selecting the focused leg never
  /// bumps the camera). Focus is disabled below two legs (a fit bump would
  /// snap a user-panned camera for no visible change).
  void _setMapFocus(TripDerivation d, String? legKey) {
    if (legKey != null && d.legs.length < 2) return;
    // Clear the pin selection with the focus change: a lingering selection
    // would suppress later content refits and keep a ghost highlight from
    // another leg.
    _selectedPosition.value = null;
    _focusedLegKey.value = legKey;
  }

  /// The combined chip action (inline strip and the full-screen map's
  /// report-back): focus the map on the leg via [_setMapFocus], un-collapse
  /// its group, and rest the header under the pinned map (wide layout). The
  /// All chip (null) resets the MAP only — the list is untouched, since
  /// expansion is decoupled from focus.
  ///
  /// Under a bookings lens no city headers exist at all: the chip drives
  /// the map only and the lens is NOT exited (unlike _scrollToDay, whose
  /// whole job is list navigation).
  void _setFocusedLeg(TripDerivation d, String? key) {
    if (d.legs.length < 2) return; // single-leg trips have no focus
    _setMapFocus(d, key);
    if (key == null) return; // All: map overview only, list untouched
    final groupKey = d.groupKeyForLeg(key);
    if (groupKey == null) return; // stale key: nothing to rest
    if (_collapsedGroups.remove(groupKey)) setState(() {});
    // Post-frame so a freshly expanded section has laid out first (the
    // _scrollToDay pattern); on phones the chips ride the scroll-away
    // preview card, so scrolling the list would hide the very map being
    // focused — desktop only.
    if (!_mapPinned) return;
    _revealCityHeader(groupKey);
  }

  /// Scrolls [groupKey]'s header under the chrome on the frame after next —
  /// post-frame so any un-collapse this tap made has laid out first.
  /// addPostFrameCallback does NOT itself request a frame, and with groups
  /// expanded by default the common case (tap on an already-expanded,
  /// already-focused target) changes no state at all — on a quiescent UI no
  /// frame would ever come and the scroll would silently stall until
  /// unrelated activity. ensureVisualUpdate guarantees the frame.
  ///
  /// [animate] false lands the header in one jump instead of the 350ms glide.
  /// The fold-all control passes false because it changes the whole list's
  /// extent at once: collapsing everything can leave the current offset far
  /// past the new maxScrollExtent, and gliding from an out-of-range offset
  /// paints blank while it travels.
  void _revealCityHeader(String groupKey, {bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToCityHeader(groupKey, animate: animate));
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Offset-reveal scroll resting [cityKey]'s header just below the pinned
  /// chrome — [_scrollToDayHeader] minus the city-header term (this header
  /// IS the target; the chrome rests via getOffsetToReveal's own
  /// obstruction handling, see there). Same one-correction contract.
  ///
  /// [animate] false jumps instead — see [_revealCityHeader].
  Future<void> _scrollToCityHeader(String cityKey,
      {bool animate = true}) async {
    final trip = _trip;
    if (!mounted || trip == null || !_scroll.hasClients) return;
    final target =
        _cityHeaderKeys[cityKey]?.currentContext?.findRenderObject();
    if (target == null || !target.attached) return;
    final viewport = RenderAbstractViewport.maybeOf(target);
    if (viewport == null) return;
    final reveal = viewport.getOffsetToReveal(target, 0).offset;
    final offset = reveal.clamp(0.0, _scroll.position.maxScrollExtent);
    if (animate) {
      await _scroll.animateTo(offset,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic);
    } else {
      _scroll.jumpTo(offset);
      // Unlike the awaited animateTo, jumpTo does not relayout before it
      // returns: the correction pass below would measure the offset we just
      // left and then "correct" by that stale delta. Wait for the frame.
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted || !_scroll.hasClients) return;
    final box = _cityHeaderKeys[cityKey]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    final vp = RenderAbstractViewport.maybeOf(box);
    if (vp == null) return;
    final actual = box.localToGlobal(Offset.zero, ancestor: vp).dy;
    final delta = actual - _pinnedChrome(trip);
    if (delta.abs() > 2) {
      _scroll.jumpTo((_scroll.offset + delta)
          .clamp(0.0, _scroll.position.maxScrollExtent));
    }
  }

  // ── Fold all / unfold all ─────────────────────────────────────────────
  // One control, two directions, kept next to the reveal machinery it
  // reuses. Both flags are DERIVED from the live derivation every build and
  // never stored — the view-tabs doctrine (PR #335): a stored "is everything
  // collapsed?" bit drifts the moment a refresh adds or drops a destination,
  // and the two placements (wide header button, narrow overflow entry) would
  // then disagree about what one tap means.

  /// Whether the fold control has anything to act on. The Bookings and
  /// Budget views swap the city groups out for flat lists — there is no
  /// accordion there to fold — and an items-empty trip renders the
  /// EmptyState branch with no groups behind it.
  bool _foldControlShown(TripDerivation d) =>
      !_inBookingsView && !_inBudgetView && d.groups.isNotEmpty;

  /// True only when EVERY live group is collapsed — the one state in which
  /// the control flips to "Expand all". `<empty>.every(...)` is true in
  /// Dart, so the isNotEmpty guard is what keeps this predicate honest on
  /// its own terms; no live caller reaches it with an empty list, since
  /// they all gate on [_foldControlShown] first.
  bool _allGroupsCollapsed(TripDerivation d) =>
      d.groups.isNotEmpty &&
      d.groups.every((g) => _collapsedGroups.contains(g.key));

  /// THE fold action, shared by the wide header button and the narrow
  /// overflow entry so the two can never disagree. Re-derives at ACTION
  /// time rather than trusting a captured flag: the overflow entry is built
  /// when the menu opens and selected a beat later.
  ///
  /// Pure LIST work, exactly like a header tap: it never writes map focus
  /// ([_setMapFocus] stays the only writer), never moves the camera, and
  /// never exits a lens.
  ///
  /// Deliberately asymmetric. Collapsing touches GROUPS only — a collapsed
  /// city's day headers aren't rendered, so [_collapsedDays] is invisible
  /// either way, and preserving it means re-opening one city by its own
  /// chevron restores the day state the traveler left. Expanding clears
  /// BOTH: an "expand all" that leaves a day shut is a liar, and a day
  /// folded three cities ago is not something anyone will think to go
  /// looking for. Consequence to know: fold→unfold is NOT an identity
  /// round-trip.
  void _toggleAllGroups(Trip trip) {
    final d = _derive(trip);
    if (!_foldControlShown(d)) return; // stale entry: no-op, never a crash
    final collapsed = _allGroupsCollapsed(d);
    // Measured BEFORE the mutation — it reads the CURRENT layout.
    final anchor = _anchorGroupKey(trip, d);
    setState(() {
      if (collapsed) {
        _collapsedGroups.clear();
        _collapsedDays.clear();
      } else {
        // clear-then-addAll, not a bare addAll: the resulting visible state
        // is identical (every live group collapses either way), but the
        // rebuild drops run keys staled by an edit. That matters here and
        // nowhere else — with one or two hand-picked keys a stale one
        // fails safe by missing contains(), but a set holding EVERY key
        // makes the positional `#2` suffixes collide: delete the first
        // Paris visit and the bare `Paris` key now names what used to be
        // `Paris#2`, so a group the traveler never folded would render
        // folded.
        _collapsedGroups
          ..clear()
          ..addAll(d.groups.map((g) => g.key));
      }
    });
    // Keep the traveler where they were. No _mapPinned guard (unlike
    // _setFocusedLeg, which skips this on phones so the list can't scroll
    // the just-tapped map chip out of view): no map focus is in play here,
    // and keeping your place matters more on a phone, not less.
    if (anchor != null) _revealCityHeader(anchor, animate: false);
  }

  /// The destination group the traveler is currently reading: the one whose
  /// header sits LOWEST while still at or above its resting slot under the
  /// pinned chrome. While a group's body scrolls, its header is pinned
  /// exactly at that slot, the previous group's has been pushed clear above
  /// and the next is still in flow below. With everything folded nothing
  /// pins, and the same rule picks the topmost row still on screen — the
  /// right visual anchor either way.
  ///
  /// Null means "leave the scroll alone": the traveler is above the first
  /// group (still in the header card), where a fold changes nothing above
  /// them and there is nothing to re-rest.
  ///
  /// Reads [TripDerivation.groups], never the never-pruned [_cityHeaderKeys]
  /// map, so a key staled by an edit cannot vote for a group that no longer
  /// renders. Every city header is laid out at every offset — folded ones
  /// are SliverToBoxAdapters, open ones SliverPinnedHeaders, and neither is
  /// lazy (only the item lists INSIDE a group are) — so this needs no
  /// scroll-range heuristics and the guards below are belt-and-braces.
  String? _anchorGroupKey(Trip trip, TripDerivation d) {
    if (!_scroll.hasClients || _scroll.offset <= 0) return null;
    final rest = _pinnedChrome(trip) + 1; // slot + float epsilon
    String? anchor;
    var best = double.negativeInfinity;
    for (final group in d.groups) {
      final box =
          _cityHeaderKeys[group.key]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final vp = RenderAbstractViewport.maybeOf(box);
      if (vp == null) continue;
      // Same coordinate space as _scrollToCityHeader's correction pass, so
      // the anchor and its resting slot are never measured differently.
      final dy = box.localToGlobal(Offset.zero, ancestor: vp).dy;
      if (dy <= rest && dy > best) {
        best = dy;
        anchor = group.key;
      }
    }
    return anchor;
  }

  /// Pushes the itinerary-derived booking checklist to the server, which upserts
  /// auto-TODOs (preserving booked state) and prunes legs no longer in the trip.
  Future<void> _syncBookingTodos(Trip trip) async {
    try {
      final todos = await ref
          .read(bookingTodosApiServiceProvider)
          .syncTodos(trip.id, _deriveTodos(trip));
      if (mounted) {
        setState(() {
          _bookingTodos = todos;
          // Re-derive against the server's answer. A row's TAP TARGET comes
          // from the _flightLegs/_ferryLegs registries _deriveTodos populates,
          // not from the row — so a leg the bootstrap default registered as a
          // flight would keep opening the in-app flight search while its row
          // now reads "train" and links to Rome2Rio. The returned payload is
          // discarded here; the registries are the point.
          _deriveTodos(trip);
        });
      }
    } catch (_) {
      // Non-fatal: keep whatever booking todos came with the trip.
    }
  }

  /// The trip's stated non-flight travel mode ('car'|'train'|'bus'|'ferry')
  /// when set, else null. Such trips derive their legs in that mode with
  /// Rome2Rio route links instead of flight defaults; flight/mixed and unset
  /// keep the legacy Greek-ferry-else-flight behavior. Shared with the map's
  /// home-leg gate — see [groundTravelMode].
  static String? _groundModeOf(Trip trip) => groundTravelMode(trip.travelMode);

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
    final l10n = context.l10n;
    final derived = _derive(trip);
    final ranges = derived.visibleRanges;
    // The ONE segment matcher, reused rather than reimplemented: the grouped
    // booking slots already claim a confirmed segment per leg (claim-once, so
    // two legs can never take the same one), and they are 1:1 with [ranges] by
    // construction — _computeGroupedBookings is fed the raw leg labels and
    // visibleLegRanges maps those 1:1. Because the posted payload and the
    // rendered rows now read the SAME claim result, they cannot disagree.
    final slots = derived.groupedBookings.slots;
    final todos = <Map<String, dynamic>>[];
    final legDatesByKey = <String, _LegDates>{};
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
    // Where the journey starts and where it ends — SEPARATELY, because a trip
    // can fly out of one airport and come home into another (trips
    // .origin_airport / .return_airport, migration 00064). One explicit ladder,
    // read once per direction; the two differ only in which airport they take:
    //
    //   this trip's airport for that direction (set in chat: set_trip_origin)
    //   -> the origin the traveler stated in words ("Lake George, NY")
    //   -> the saved home airport, a standing guess about how this traveler
    //      usually leaves rather than anything about THIS trip.
    //
    // Server twin: tripEndpointLabels in booking_todo_identity.go — it relabels
    // these same rows on the trip's endpoints changing, so change one and you
    // change both.
    String? endpointLabel(String? tripAirport) {
      final code = tripAirport?.trim();
      if (code != null && code.isNotEmpty) return code.toUpperCase();
      final stated = trip.origin?.trim();
      if (stated != null && stated.isNotEmpty) return stated;
      return _homeAirport;
    }

    final departure = endpointLabel(trip.originAirport);
    final arrival = endpointLabel(trip.returnAirport);
    final hasDeparture =
        departure != null && departure.isNotEmpty && ranges.isNotEmpty;
    final hasArrival = arrival != null && arrival.isNotEmpty && ranges.isNotEmpty;
    final ground = _groundModeOf(trip);

    // What each leg's mode already resolved to, keyed by leg. A transport
    // row's [BookingTodo.effectiveMode] is the override somebody chose, else
    // the mode the SERVER derived for the leg (leg_transport_mode.go, 00068) —
    // geography included, which is what makes Rome → Florence a train. Both
    // outrank the local default below.
    final modeByKey = <String, String>{
      for (final t in _bookingTodos)
        if (t.kind == 'transport' && t.effectiveMode != null)
          t.todoKey: t.effectiveMode!,
    };
    String effectiveMode(String origin, String destination, String def) {
      final key =
          'transport:${origin.toLowerCase()}>>${destination.toLowerCase()}';
      return modeByKey[key] ?? def;
    }

    // A leg's dates, with the confirmed segment winning when there is one —
    // the same rule this screen already applies to a row's transport MODE
    // ("that row's mode truth is the segment"). The itinerary only ever knows
    // ONE date per leg, so [itineraryDateIsArrival] says which end of the
    // journey that date describes.
    _LegDates legDates(TripSegment? seg, DateTime? itineraryDate,
        {required bool itineraryDateIsArrival}) {
      final segDepart = DateTime.tryParse(seg?.departDate ?? '');
      if (segDepart != null) {
        return (
          depart: segDepart,
          arrive: DateTime.tryParse(seg?.arriveDate ?? '')
        );
      }
      return itineraryDateIsArrival
          ? (depart: null, arrive: itineraryDate)
          : (depart: itineraryDate, arrive: null);
    }

    // The ONE place a derived transport row's date line is written.
    String? legSubtitle(_LegDates d) =>
        transportDateLineOf(l10n, d.depart, d.arrive);

    // What rides the wire as depart_date. The server rebuilds search_url from
    // it and the in-app flight search is seeded from it, so a real departure
    // fixes both. Falling back to the arrival keeps a date on the link for a
    // leg we know nothing else about: a SEARCH date is a query the results page
    // corrects, not an assertion about the traveler's trip — the assertion
    // lives in the subtitle, which now says "Arrives" instead of guessing.
    String? legSeed(_LegDates d) {
      final seed = d.depart ?? d.arrive;
      return seed == null ? null : _fmt(seed);
    }

    // Adds a transport (flight) todo and records its leg so the booking item can
    // open Find Flights prefilled. Coords (when known) resolve an endpoint to its
    // nearest airport if the city label itself has no IATA match.
    void addFlight(String origin, String destination, _LegDates when,
        {_Coord? originCoord, _Coord? destCoord}) {
      final date = legSeed(when);
      final key =
          'transport:${origin.toLowerCase()}>>${destination.toLowerCase()}';
      todos.add({
        'kind': 'transport',
        'todo_key': key,
        'title': '$origin → $destination',
        if (legSubtitle(when) case final line?) 'subtitle': line,
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
    void addFerry(String origin, String destination, _LegDates when) {
      final date = legSeed(when);
      final key =
          'transport:${origin.toLowerCase()}>>${destination.toLowerCase()}';
      todos.add({
        'kind': 'transport',
        'todo_key': key,
        'title': '$origin → $destination',
        if (legSubtitle(when) case final line?) 'subtitle': line,
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
    void addGround(String origin, String destination, _LegDates when) {
      final date = legSeed(when);
      final key =
          'transport:${origin.toLowerCase()}>>${destination.toLowerCase()}';
      todos.add({
        'kind': 'transport',
        'todo_key': key,
        'title': '$origin → $destination',
        if (legSubtitle(when) case final line?) 'subtitle': line,
        'provider': 'rome2rio',
        'position': pos++,
        'origin': origin,
        'destination': destination,
        if (date != null) 'depart_date': date,
        'passengers': 1,
      });
    }

    // Dispatches one leg by a concrete mode (a per-leg override or a derived
    // default): ferry and flight register their leg for the in-app search
    // override; car/train/bus ride the server-built Rome2Rio link.
    void addLegAs(String mode, String origin, String destination, _LegDates when,
        {_Coord? originCoord, _Coord? destCoord}) {
      legDatesByKey['transport:${origin.toLowerCase()}>>'
          '${destination.toLowerCase()}'] = when;
      switch (mode) {
        case 'ferry':
          addFerry(origin, destination, when);
        case 'car' || 'train' || 'bus':
          addGround(origin, destination, when);
        default:
          addFlight(origin, destination, when,
              originCoord: originCoord, destCoord: destCoord);
      }
    }

    // The BOOTSTRAP default per leg, used only until the server answers: two
    // Greek ports/islands (incl. Athens/Piraeus) is a ferry; a stated ground
    // travel mode makes every other leg ground; otherwise a flight. The real
    // resolution — the same ladder plus geography — is server-side in
    // leg_transport_mode.go and arrives as [BookingTodo.derivedMode], which
    // effectiveMode prefers; this branch only decides what a brand-new trip
    // posts on its very first sync, and it retires with the rest of this
    // derivation at the specs/server-booking-todos flip.
    void addLeg(String origin, String destination, _LegDates when,
        {_Coord? originCoord, _Coord? destCoord}) {
      final greek = _isGreekIsland(origin) && _isGreekIsland(destination);
      final def = greek ? 'ferry' : (ground ?? 'flight');
      addLegAs(effectiveMode(origin, destination, def), origin, destination,
          when, originCoord: originCoord, destCoord: destCoord);
    }

    // Outbound: departure airport -> first city. The itinerary's date here is
    // the first group's START — the trip's start date via the first-leg anchor
    // — which is the day the traveler LANDS, not the day they left home. There
    // is no leg before the first city to supply a departure, so unless a
    // confirmed segment carries one this row says "Arrives <date>" rather than
    // implying the traveler flies out on the day they arrive. That single
    // wrong date used to reach the row, the Find-flights link (in-app and
    // external), the Add-details prefill, and the Trips-list "first leg
    // departs" nudge. Home legs never get the Greek-ferry default.
    if (hasDeparture) {
      addLegAs(
          effectiveMode(departure, ranges.first.label, ground ?? 'flight'),
          departure,
          ranges.first.label,
          legDates(slots.isEmpty ? null : slots.first.arrivalMatch,
              ranges.first.start,
              itineraryDateIsArrival: true),
          destCoord: ranges.first.coord);
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
        addLeg(
            label,
            ranges[i + 1].label,
            legDates(i + 1 < slots.length ? slots[i + 1].arrivalMatch : null,
                r.end,
                itineraryDateIsArrival: false),
            originCoord: r.coord,
            destCoord: ranges[i + 1].coord);
      }
    }

    // Return: last city -> arrival airport, on the trip's end date. Read from
    // its OWN ladder rung, so a trip that comes home into a different airport
    // than it left from says so.
    if (hasArrival) {
      addLegAs(
          effectiveMode(ranges.last.label, arrival, ground ?? 'flight'),
          ranges.last.label,
          arrival,
          legDates(slots.isEmpty ? null : slots.last.departureMatch,
              ranges.last.end,
              itineraryDateIsArrival: false),
          originCoord: ranges.last.coord);
    }

    _flightLegs = legs;
    _ferryLegs = ferryLegs;
    _legDates = legDatesByKey;
    return todos;
  }

  // The per-city booking-slot partition lives in
  // [TripDerivation.groupedBookings] (trip_detail_derivation.dart).

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
      if (!mounted) return; // _load awaited: the screen may be gone
      // Open whatever it landed in, then point the map at it. The map write
      // is THIS path's alone: adding one place is a request to look at it.
      final legKey = _revealNewItems(beforeIds);
      final t = _trip;
      if (legKey != null && t != null) _setMapFocus(_derive(t), legKey);
    }
  }

  /// Un-collapse every destination group — and every day inside it — that
  /// gained an item, so something the traveler just asked for can never land
  /// inside a folded section. Returns the leg key of the FIRST new item in
  /// build order (null when nothing was added) for callers that also want the
  /// map to move; the reveal itself NEVER writes focus, so the chat path can
  /// use it without dragging the camera around mid-conversation.
  ///
  /// Two things make this load-bearing rather than defensive. Folding is one
  /// tap now, so "the traveler folded this city" went from a deliberate act
  /// to the ordinary posture of anyone surveying a long trip. And the chat
  /// adds in BATCHES across several cities — the old version stopped at the
  /// first new item, which was right when [_addPlace] (exactly one place) was
  /// the only caller and silently wrong for "added 4 places in Rome and
  /// Paris". Days count as much as cities: un-collapsing Rome reveals nothing
  /// if the item landed on a day that is itself folded.
  String? _revealNewItems(Set<String> beforeIds) {
    final trip = _trip;
    if (trip == null) return null;
    final d = _derive(trip);
    String? firstLegKey;
    var changed = false;
    for (final i in trip.items ?? const <ItineraryItem>[]) {
      if (beforeIds.contains(i.id)) continue;
      final legKey = d.legKeyOfPosition(i.position);
      // `continue`, not `return`: one unresolvable item must not abandon the
      // rest of the batch.
      if (legKey == null) continue;
      firstLegKey ??= legKey;
      final groupKey = d.groupKeyForLeg(legKey);
      if (groupKey == null) continue;
      if (_collapsedGroups.remove(groupKey)) changed = true;
      final day = i.day;
      if (day != null && _collapsedDays.remove('$groupKey#$day')) {
        changed = true;
      }
    }
    if (changed) setState(() {});
    return firstLegKey;
  }

  /// Every argument is null-means-omitted, EXCEPT that an empty [summary] is a
  /// real instruction: it clears the trip's description.
  Future<void> _patch(
      {String? title,
      String? startDate,
      String? endDate,
      String? summary}) async {
    if (_guardOffline()) return;
    final l10n = context.l10n;
    try {
      final updated = await ref.read(tripsApiServiceProvider).patchTrip(
            widget.tripId,
            title: title,
            startDate: startDate,
            endDate: endDate,
            summary: summary,
          );
      if (mounted) setState(() => _trip = updated);
      ref.read(tripsProvider.notifier).loadTrips(); // keep list in sync
    } catch (e) {
      _showSnack(l10n.tripUpdateFailed(friendlyError(l10n, e)));
    }
  }

  /// The trip's name and description, edited together (specs/trip-description).
  ///
  /// Both fields are seeded from what is ON SCREEN — [_displayTitle] and
  /// [_overviewText] — rather than from the raw columns, and on a legacy trip
  /// those differ. Such a trip predates migration 00013, so its prose lives in
  /// `title` and the header already shows a computed short title above it;
  /// seeding the raw values would offer an empty description box underneath a
  /// description the traveler can plainly read. Seeding the rendered ones makes
  /// the first save promote the prose into `summary` and the computed name into
  /// `title`, which is where they each belonged all along.
  Future<void> _editTripDetails() async {
    if (_guardOffline()) return;
    final trip = _trip;
    if (trip == null) return;
    final choice = await showTripDetailsDialog(
      context,
      title: _displayTitle(trip),
      description: _overviewText(trip),
    );
    if (choice == null || choice.title.isEmpty) return;
    await _patch(title: choice.title, summary: choice.description);
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

  /// The trip page's visible proof that a conversation is waiting

  /// Makes sure the trip's saved conversation is loaded before anything is
  /// sent into it (specs/trip-refine-memory). Returns false when the caller
  /// must NOT proceed.
  ///
  /// This gate is load-bearing, not politeness: the transcript is upserted
  /// wholesale every turn, so sending a seed into a panel that failed to
  /// restore would overwrite a fifty-message conversation with two messages.
  ///
  /// The empty-transcript precondition is what makes it safe to call
  /// [PlanNotifier.resumeConversation] (which resets): a turn can never be in
  /// flight with an empty transcript, because sendMessage appends the user's
  /// message first.
  Future<bool> _ensureRefineHydrated(Trip trip) async {
    final notifier = ref.read(tripRefineProvider(widget.tripId).notifier);
    // Memory beats server: an in-progress conversation is already the truth,
    // and refetching would discard anything streaming.
    if (ref.read(tripRefineProvider(widget.tripId)).messages.isNotEmpty) {
      return true;
    }
    // Nothing stored: a fresh conversation can't overwrite anything.
    if (trip.refineChat == null) return true;
    if (_chatResumeTried) {
      // Already answered once this screen session. "Expired" means there is
      // nothing left to protect, so a fresh chat is fine; a FAILURE means a
      // stored conversation may still be there, and sending into an empty
      // panel would upsert over it.
      return _chatPhase != RefineChatPhase.failed;
    }
    _chatResumeTried = true;
    setState(() {
      _panelOpen = true;
      _chatPhase = RefineChatPhase.restoring;
      _chatError = null;
    });
    // Captured while mounted: after the await, `ref` may be unreachable
    // through a disposed element.
    final trips = ref.read(tripsApiServiceProvider);
    try {
      await resumeTripRefineChat(
          trips: trips, plan: notifier, tripId: widget.tripId);
      if (!mounted) return false;
      setState(() => _chatPhase = RefineChatPhase.ready);
      return true;
    } catch (e) {
      if (!mounted) return false;
      final gone = e is ApiException && e.statusCode == 404;
      setState(() {
        _chatPhase =
            gone ? RefineChatPhase.expired : RefineChatPhase.failed;
        _chatError = e;
      });
      return false;
    }
  }

  /// Points the trip's running conversation at [target], seeding it with that
  /// section's current contents. The session is bound to this trip server-side,
  /// so changes patch the trip in place (no new versions).
  ///
  /// Since specs/trip-refine-memory this APPENDS: a ✨ tap is a change of
  /// subject, not a new chat. Only "Clear chat" discards one.
  Future<void> _openRefine(Trip trip, RefineTarget target) async {
    // Chat/refine needs the network; also keeps the refine panel from ever
    // observing a cached (read-only) trip.
    if (_guardOffline()) return;
    // Owners and editor co-planners refine; viewer-role members are
    // read-only. Buttons are hidden, this is the belt-and-braces guard.
    if (!trip.canEdit) return;
    final l10n = context.l10n;
    final items = trip.items ?? [];
    if (items.isEmpty) {
      // An empty trip has no section to refine — but "Refine with AI" is
      // exactly how a traveler asks for a first itinerary, and the snack that
      // used to stand here made the only visible AI entry on an empty trip a
      // dead end. It promised an action the callee refused, which is why
      // fixing the callee fixes both doors (the header chip and the narrow
      // app-bar icon) at once. Same handoff the Next Step card's
      // plan_itinerary step already makes: _openSeededChat is these guards
      // minus the items check. Only trip-scope entries can reach here — no
      // items means no groups, so no city or day affordance exists to press.
      // continuing: false — #441's flag marks a seed APPENDED to a refine
      // conversation already under way. This door is the opposite: an empty
      // trip's plan-from-scratch entry, reached before _ensureRefineHydrated
      // has even run, so there is no thread to change the subject of.
      _openSeededChat(trip,
          seed: _buildSectionSeed(trip, target, continuing: false),
          displayLabel: l10n.tripPlanFromScratch);
      return;
    }
    if (!await _ensureRefineHydrated(trip)) return;
    if (!mounted) return;
    final continuing =
        ref.read(tripRefineProvider(widget.tripId)).messages.isNotEmpty;
    ref
        .read(tripRefineProvider(widget.tripId).notifier)
        .appendSectionRefinement(
            _buildSectionSeed(trip, target, continuing: continuing),
            // displayLabel is what the traveler reads in the panel header, so
            // it uses the localized form; the seed prompt above keeps the
            // canonical English label the agent expects (specs/i18n-spanish).
            displayLabel: target.assistant
                ? l10n.tripAssistantLabel
                : l10n.tripRefiningSection(target.displayLabel(l10n)));
    setState(() => _panelOpen = true);
  }

  /// Filling a city's open days (specs/shape-before-schedule) — the door out of
  /// the spine, shared by the empty-day row and the city header's count line so
  /// there is one action behind both affordances.
  ///
  /// It is deliberately NOT [RefineTarget.day], which the per-day sparkle uses:
  /// that emits `scope='day'`, and a day with no items is not a section the
  /// server can replace — `spliceSection` rejects it outright ("no itinerary
  /// items matched day N"). Filling an empty day is a CITY-scoped rewrite, and
  /// the seed says so.
  ///
  /// Null for viewers and offline, matching the per-day refine gate.
  VoidCallback? _planDaysAction(String groupKey, String cityKey, List<int> days) {
    if (_isOffline || !(_trip?.canEdit ?? true) || days.isEmpty) return null;
    // 'Other places' is a fallback label, not a hub the section tool can
    // target — the same carve-out the city sparkle makes.
    if (cityKey == _kOtherPlaces) return null;
    return () {
      final trip = _trip;
      if (trip == null) return;
      _openSeededChat(trip,
          seed: _buildFillDaysSeed(trip, groupKey, cityKey, days),
          displayLabel: context.l10n.tripRefineCity(cityKey));
    };
  }

  /// The seed for "plan these days". Carries what the job needs and nothing
  /// else: the city, the span the page renders for it, WHICH days are open, and
  /// the places already on it so a city-scoped rewrite keeps them.
  ///
  /// It asks the agent to PROPOSE first. [_buildSectionSeed] lets a refine apply
  /// straight away, which is right when the traveler said what to change — but
  /// this seed carries no instruction, only a gap. A seed that names a gap must
  /// propose before it writes; that is the whole point of the two-pass flow
  /// this door hangs off.
  ///
  /// Canonical English like every other seed here: agent input, not display
  /// copy (specs/i18n-spanish).
  String _buildFillDaysSeed(
      Trip trip, String groupKey, String cityKey, List<int> days) {
    final d = _derive(trip);
    final i = d.legIndexOf(groupKey);
    final group = i == null ? null : d.groups[i];
    final chip = group?.dateRange;
    final b = StringBuffer('I want to plan my days in $cityKey');
    if (chip != null) b.write(' (${chip.range})');
    final list = days.map((n) => 'day $n').join(', ');
    b.writeln('. $list ${days.length == 1 ? 'has' : 'have'} nothing planned.');
    if (group != null && group.items.isNotEmpty) {
      b.writeln('\nAlready in $cityKey (keep these exactly as they are — their '
          'day numbers are what set the city\'s arrival and departure dates):');
      for (final it in group.items) {
        b.writeln(_seedLine(it));
      }
    }
    b.write('\nPropose places for those days first — do not change any other '
        'city — and when I confirm, call update_itinerary_section with '
        "scope='city', city='$cityKey' and that city's COMPLETE updated list: "
        'the places above unchanged, plus the new ones tagged to the open days. '
        'Start by proposing a plan for those days.');
    return b.toString();
  }

  /// Next Step chat entry (specs/next-step-cta): the same offline + canEdit
  /// guards as [_openRefine], minus the items-empty guard — next-step seeds
  /// are server-built and embed no section, and the zero-items
  /// plan_itinerary step exists precisely for empty trips. [displayLabel] is
  /// the step's server-localized title; the seed stays canonical English
  /// (specs/i18n-spanish).
  Future<void> _openSeededChat(Trip trip,
      {required String seed, required String displayLabel}) async {
    if (_guardOffline()) return;
    if (!trip.canEdit) return;
    if (!await _ensureRefineHydrated(trip)) return;
    if (!mounted) return;
    ref
        .read(tripRefineProvider(widget.tripId).notifier)
        .appendSectionRefinement(seed, displayLabel: displayLabel);
    setState(() => _panelOpen = true);
  }

  /// FAB / "Continue chat" entry point: reopens the conversation in progress,
  /// restores the saved one, or starts a fresh whole-trip assistant session.
  Future<void> _openChat(Trip trip) async {
    if (_guardOffline()) return;
    // The FAB is hidden for read-only viewers; belt-and-braces like
    // _openRefine.
    if (!trip.canEdit) return;
    if (ref.read(tripRefineProvider(widget.tripId)).messages.isNotEmpty) {
      setState(() => _panelOpen = true);
      return;
    }
    if (trip.refineChat != null && !_chatResumeTried) {
      await _ensureRefineHydrated(trip);
      return; // the panel is open either way — restored, expired, or failed
    }
    await _openRefine(trip, const RefineTarget.assistant());
  }

  /// Explicit "Clear chat": discard the conversation here and server-side, so
  /// the page stops advertising one the traveler just dismissed. Confirms first
  /// — with one running chat per trip, this really does throw the thread away.
  ///
  /// Also backs the expired/failed panels' "New chat" button, which is the same
  /// action seen from a state where there is nothing left to lose.
  Future<void> _newChat(Trip trip) async {
    final l10n = context.l10n;
    // "Is there a conversation?" is answered from wherever one can exist, not
    // from whichever copy this path happens to hold: the Continue-chat row
    // clears without ever opening the panel, so the transcript is NOT
    // hydrated there and an in-memory-only test would skip the confirm on
    // exactly the fifty-message chat it exists to protect.
    //
    // `expired` is the one state that answers NO despite `trip.refineChat`: the
    // server already told us the transcript is gone (404), so that summary is
    // stale and asking to clear it would contradict the panel the traveler is
    // reading ("This conversation has expired.") in the same breath.
    final hasConversation = _chatPhase != RefineChatPhase.expired &&
        (ref.read(tripRefineProvider(widget.tripId)).messages.isNotEmpty ||
            trip.refineChat != null);
    if (hasConversation) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.refineClearChatConfirmTitle),
          content: Text(l10n.refineClearChatConfirmBody),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.commonCancel)),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.refineClearChat)),
          ],
        ),
      );
      if (confirm != true || !mounted) return;
    }
    final trips = ref.read(tripsApiServiceProvider);
    ref.read(tripRefineProvider(widget.tripId).notifier).startOver();
    setState(() {
      _chatPhase = RefineChatPhase.ready;
      _chatError = null;
      // A cleared conversation is not one we failed to restore: allow a fresh
      // restore attempt if the traveler somehow gets a new one.
      _chatResumeTried = false;
    });
    try {
      // Idempotent server-side, so a conversation that never completed a turn
      // is not an error here either.
      await trips.deleteTripRefineChat(widget.tripId);
    } catch (_) {
      // Best-effort: the local conversation is already gone, and the next trip
      // load re-reads whatever the server still holds.
    }
    if (mounted) await _refresh();
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
  ///
  /// [continuing] marks a seed appended to a conversation already under way
  /// (specs/trip-refine-memory) — it opens as a change of subject and drops the
  /// "start by asking" framing, so the assistant doesn't re-introduce itself
  /// mid-thread. Canonical English throughout: this text goes to the agent.
  String _buildSectionSeed(Trip trip, RefineTarget t,
      {required bool continuing}) {
    final items = trip.items ?? [];
    final b = StringBuffer(continuing
        ? "Let's turn to another part of the same trip"
        : 'I want to refine my saved trip "${_displayTitle(trip)}"');
    if (!continuing && trip.startDate != null && trip.endDate != null) {
      b.write(' (${trip.startDate} to ${trip.endDate})');
    }
    b.writeln('.');

    if (items.isEmpty) {
      // Without this branch the seed says "The full itinerary:" followed by
      // nothing, then "keeping unchanged places exactly as listed above", then
      // "Start by asking what I want to change" — an agent politely asking what
      // to change about nothing. Asks for the SHAPE first, matching the two-pass
      // flow (specs/shape-before-schedule) and the server's own seed for this
      // state (seedPlanItineraryEmpty, api/trip_next_step.go) — deliberately
      // the same job and the same tool; keep the two in intent-sync if either
      // moves. Canonical English: agent input, not display copy.
      b.write('It has no places yet. Start with the SHAPE — which cities, in '
          'what order, how many nights in each, and how I get between them — '
          'and wait for me to agree to it before adding any places. Then, when '
          "I confirm, call update_itinerary_section with scope='trip' and the "
          'COMPLETE list of places, giving each city a place on the day I '
          'arrive and one on the day I move on. Start by asking what kind of '
          'trip I want — pace, interests, and any must-sees.');
      return b.toString();
    }

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
    if (t.assistant) {
      b.write('I may also just ask questions about the trip (flights, '
          'bookings, timing) — answer those directly without changing '
          'anything. ');
    }
    b.write(continuing
        ? 'Wait for what I want to change before editing anything.'
        : (t.assistant
            ? 'Start by asking how you can help.'
            : 'Start by asking what I want to change.'));
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

  /// Revoking cuts off everyone already holding the link, and nothing brings
  /// those links back — so it confirms, the same as the other two actions that
  /// take something away (delete, leave). It sits beside "Manage access" now
  /// that it does; unconfirmed, that adjacency was a mis-tap away from
  /// stranding a co-planner.
  Future<void> _revokeLink() async {
    final l10n = context.l10n;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.tripTurnOffSharingConfirmTitle),
        content: Text(l10n.tripTurnOffSharingConfirmBody),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.tripTurnOffSharingConfirmAction),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (!mounted) return;
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

  /// A stored title is "long" when it's really the AI summary (multi-line or
  /// lengthy); such trips get a computed display title instead. The rule is
  /// shared (utils/trip_format.dart) so the trips list agrees with this header.
  bool _titleIsLong(String t) => tripTitleIsLong(t);

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

  /// Wraps a run of box widgets as a single sliver for use inside MultiSliver.
  Widget _boxSliver(List<Widget> children) => SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );

  /// One header view tab ("Itinerary" / "Bookings" + count pill). The
  /// selected tab doesn't take taps — re-tap is a no-op, which also keeps an
  /// idle tap on the already-selected Itinerary tab from clearing an active
  /// places filter. The 2px underline is reserved (transparent) when
  /// unselected so selection never shifts layout; Center(widthFactor: 1)
  /// hugs the label's width while filling the header row's height for a real
  /// touch target. [trailing] renders inside the underlined region so the
  /// underline spans label + pill as one tab.
  Widget _headerTab(ThemeData theme,
      {required String label,
      required bool selected,
      required VoidCallback onTap,
      Widget? trailing}) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        borderRadius: AppRadius.smAll,
        onTap: selected ? null : onTap,
        child: Center(
          widthFactor: 1,
          child: Container(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xs, 0, AppSpacing.xs, 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  width: 2,
                  color: selected
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: AppSpacing.xs),
                  trailing,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The header view-tab cluster: Itinerary | Bookings | Budget. Selection
  /// derives from _itemFilter at each call site — the tap handlers only
  /// write the filter (PR #335's invariant). Bookings needs itinerary items
  /// (the items-empty body branch shadows its view, so the tab would open a
  /// view that can never render — same gate as the filter menu); Budget's
  /// view renders regardless, so a place-less trip still gets an
  /// Itinerary | Budget pair (the collapsed cluster row this tab replaced
  /// was reachable there too). With no second tab to offer (place-less trip
  /// and the Budget tab gated off) the plain title keeps the old look. The
  /// inter-tab gap tightens on narrow so three tabs fit a 390px phone in
  /// Spanish.
  Widget _viewTabs(Trip trip, ThemeData theme) {
    final l10n = context.l10n;
    final itemsEmpty = (trip.items ?? const <ItineraryItem>[]).isEmpty;
    final showBudgetTab = _budgetTabVisible();
    if (itemsEmpty && !showBudgetTab) {
      return Text(l10n.tripItinerary,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium);
    }
    final tabGap = _narrow ? AppSpacing.sm : AppSpacing.md;
    // Natural-width tabs inside a scale-down FittedBox. The previous
    // Flexible-per-tab layout split the row into EQUAL shares, so the
    // widest tab (the counted Bookings label) ellipsized while its
    // neighbors sat on slack — with three tabs the thirds starve it even
    // in English. Scale-down only engages when the whole cluster genuinely
    // can't fit (tiny windows, giant accessibility text) and shrinks the
    // trio uniformly instead of eating one label. The inner SizedBox keeps
    // the 44px tap-target height the pinned header row provides.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: SizedBox(
        height: 44,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _headerTab(
              theme,
              label: l10n.tripItinerary,
              selected: !_inBookingsView && !_inBudgetView,
              onTap: () => setState(() {
                _itemFilter = 'all';
                _bookingsLensDestination = null;
              }),
            ),
            if (!itemsEmpty) ...[
              SizedBox(width: tabGap),
              // The booking progress count rides the tab as a pill — the
              // same checked/total chrome as the wear-sheet header and the
              // checklist header, so every count reads as one language.
              // (This tab replaced the counter that was the old one-way
              // door into this view.) Dropped on narrow: three tabs +
              // pill is what genuinely shrinks the FittedBox trio at
              // 390px, and the count is one tap away inside the view.
              //
              // The number is the FOLD of the destination chips
              // (bookingOverallCount over the one groupedBookings
              // partition), not a count of todos: the pill's promise is
              // "this many checkboxes behind this tab", and confirmed
              // records with no todo are checkboxes too. Still gated on
              // having todos at all — the server withholds them from
              // viewers, whose entries are only the confirmed records, so
              // a viewer's count would read "all booked" while the owner
              // sees the real remainder. No number beats a partial one.
              _headerTab(
                theme,
                label: l10n.tripTabBookings,
                trailing: (_narrow || _bookingTodos.isEmpty)
                    ? null
                    : () {
                        final d = _derive(trip);
                        final c = bookingOverallCount(
                            d.groupedBookings, d.legLabels);
                        return StatusPill.custom(
                          label: '${c.booked}/${c.total}',
                          background:
                              theme.colorScheme.surfaceContainerHighest,
                          foreground: theme.colorScheme.onSurfaceVariant,
                        );
                      }(),
                selected: _inBookingsView,
                onTap: () => setState(() {
                  _itemFilter = 'bookings';
                  _bookingsLensDestination = null;
                }),
              ),
            ],
            if (showBudgetTab) ...[
              SizedBox(width: tabGap),
              _headerTab(
                theme,
                label: l10n.budgetTitle,
                selected: _inBudgetView,
                onTap: () => setState(() {
                  _itemFilter = 'budget';
                  _bookingsLensDestination = null;
                }),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // The map's travel-time labels live in [TripDerivation.segmentLabels].

  // ---- Trip Health one-tap fixes ------------------------------------------

  /// Applies a Trip Health finding's structured [FindingFix]. Safe mutations
  /// (move/mark-booked/add-packing) apply instantly with a snackbar + Undo;
  /// adds open the existing sheet PREFILLED; set-dates / raise-budget open the
  /// existing editors. After any success the trip reloads and the review
  /// re-reads (see [_afterFix]) so the resolved finding drops off.
  ///
  /// THROWS on the offline guard and on API failure — after showing this
  /// screen's error snackbar, which renders BEHIND the health sheet's modal
  /// barrier. The throw is the sheet's signal to close itself so that
  /// snackbar is actually seen (trip_health_sheet.dart's onApplyFix wrapper);
  /// user-cancelled flows (dismissed prefill sheet, missing fix fields)
  /// return normally.
  Future<void> _applyFix(TripFinding finding) async {
    if (_guardOffline()) throw StateError('offline');
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
          rethrow;
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
          rethrow;
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
          rethrow;
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
          // Same ask as the row checkbox (the price is in hand right now);
          // the dialog resolves before the Undo snackbar shows.
          Accommodation? stay;
          TripSegment? segment;
          if (isAccommodation) {
            for (final a in _stays) {
              if (a.id == itemId) stay = a;
            }
          } else {
            for (final s in _segments) {
              if (s.id == itemId) segment = s;
            }
          }
          if (stay != null || segment != null) {
            await _maybePromptBudgetExpense(stay: stay, segment: segment);
          }
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(l10n.tripMarkedAsBooked),
            action: SnackBarAction(
              label: l10n.tripUndo,
              onPressed: () async {
                await _setEntityBooked(isAccommodation, itemId, false);
                // Un-booking takes the system-managed expense with it.
                await _removeLinkedAutoExpense([itemId]);
                await _afterFix();
              },
            ),
          ));
        } catch (e) {
          _showSnack(l10n.tripUpdateBookingFailed(friendlyError(l10n, e)));
          rethrow;
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
          rethrow;
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

  /// Reloads the trip payload — which re-reads the health review with it — so
  /// a resolved finding disappears on the next fetch. Kept as a named step
  /// because nine fix paths read better saying what they just finished than
  /// saying "load".
  Future<void> _afterFix() => _load();

  /// Invalidates both review variants (hours-off and hours-on) so whichever the
  /// section is showing re-fetches.
  void _invalidateReview() {
    ref.invalidate(
        tripReviewProvider(TripReviewKey(widget.tripId, checkHours: false)));
    ref.invalidate(
        tripReviewProvider(TripReviewKey(widget.tripId, checkHours: true)));
  }

  /// Opens the Trip Health sheet with the screen's standard wiring — shared by
  /// the Next Step card's Trip-health entry and its unknown-kind fallback (the
  /// app-bar badge keeps its own inline call).
  void _openHealthSheet(Trip trip) {
    showTripHealthSheet(
      context,
      tripId: trip.id,
      isOffline: () => _isOffline,
      onScrollToDay: _scrollToDay,
      dayForItem: _dayOfItem,
      onApplyFix: _readOnly ? null : _applyFix,
    );
  }

  /// Routes the Next Step card's primary action: planning steps seed the trip
  /// chat with the server-built prompt; mechanical steps jump to the matching
  /// control directly (mixed-actions decision, specs/next-step-cta).
  /// Walk-derived transport steps (itinerary-order walk) hand off exactly
  /// like their checklist row — Find Flights / Ferryhopper / provider link —
  /// with the seeded chat as the fallback. Unknown kinds — future ladder
  /// phases from a newer server — fall back to the step's fix, else the
  /// health sheet.
  Future<void> _onNextStepAction(Trip trip, NextStep step) async {
    switch (step.kind) {
      case 'set_dates':
        await _editDates();
        _invalidateReview();
        break;
      case 'book_trip':
        setState(() {
          _itemFilter = 'unbooked';
          _bookingsLensDestination = null;
        });
        break;
      case 'add_packing':
        await showWearPackSheet(
          context,
          tripId: trip.id,
          // Checklist-only open: regions are the weather half, which needs a
          // build-scoped watch — the checklist half is this step's target.
          regions: const [],
          canEdit: !_readOnly,
          isOffline: () => _isOffline,
        );
        // Items added inside the sheet complete the step.
        _invalidateReview();
        break;
      case 'plan_itinerary':
      case 'add_lodging':
      case 'schedule_items':
        final seed = step.seedPrompt;
        if (seed == null || seed.isEmpty) return;
        _openSeededChat(trip, seed: seed, displayLabel: step.title);
        break;
      case 'add_transport':
        // The fix's endpoints locate the client-synced todo, whose open
        // callback is the same handoff the checklist row uses. Fire-and-forget
        // exactly like the row's onOpen — deliberately NO _invalidateReview
        // (mirrors the row path; the review advances via booked flips and
        // trip_updated → _refresh → _invalidateReview). Chat is the fallback:
        // no matching todo (sync still in flight, or a stale review) or an
        // old server's fix-less step.
        if (_guardOffline()) return;
        final todo = _transportTodoForFix(step.fix);
        final open = todo == null
            ? null
            : _openCallbackFor(todo, surface: 'next_step_card');
        if (open != null) {
          open();
          break;
        }
        final transportSeed = step.seedPrompt;
        if (transportSeed == null || transportSeed.isEmpty) return;
        _openSeededChat(trip, seed: transportSeed, displayLabel: step.title);
        break;
      default:
        if (step.fix != null) {
          await _applyFix(TripFinding(
            severity: 'info',
            category: step.kind,
            message: step.title,
            tripId: trip.id,
            day: step.day,
            fix: step.fix,
          ));
        } else {
          _openHealthSheet(trip);
        }
    }
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

  /// Screen-level budget-target editor for the raise_budget fix — a thin
  /// wrapper over the shared [showBudgetTargetDialog] (the same dialog the
  /// Budget tab's pencil opens, so the fix gets currency editing too and the
  /// two paths can't drift). The helper saves, invalidates both budget
  /// providers, and snacks on save failure itself.
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
    final saved =
        await showBudgetTargetDialog(context, ref, widget.tripId, budget);
    if (saved) await _afterFix();
  }

  // The per-position date chips live in [TripDerivation.locationDates]; the
  // leg date-range derivation itself (raw + visible) stays in
  // utils/leg_ranges.dart (specs/trip-dates-truth stage 0a) — one testable
  // definition shared with the booking-todo derivation and the Go twin
  // behind the server legs payload.

  /// Coarse relative timestamp for the "Updated by X" line.

  /// Per-leg what-to-wear derivations for the wear/pack sheet
  /// (specs/what-to-wear). Queried AND displayed on visibleLegRanges — the
  /// dates the city-header chips render — so the guidance can never describe
  /// a window the traveler was never shown. (It used to query the raw ranges
  /// and display the visible ones, the same raw-vs-visible split that made a
  /// Sep 1–4 Berlin leg look up events for Sep 4 alone; friction-log
  /// 2026-08-14.) Iterates the leg LIST by index, so a revisited city gets one
  /// row per visit on that visit's own window. Fetch sharing: the city-group
  /// weather watch now builds a byte-identical WeatherQuery, so the provider
  /// family dedups every leg, revisits included. Loading or failed reports
  /// derive null and drop out; offline this is simply empty. Consecutive
  /// same-guidance recs fold into one displayed row inside [WearRecsList]
  /// ([groupWearRegions]) — a display-layer concern only, so the watches and
  /// the sheet header's summary stay per-leg here.
  List<WearRegionRec> _legClothingRecs(Trip trip, WidgetRef ref) {
    // NOTE: [ref] is the app-bar wear action's Consumer ref, NOT the
    // State's — the weather watches here must subscribe that icon, never
    // the whole screen (see _wearAppBarAction).
    final derivation = _derive(trip);
    final recs = <WearRegionRec>[];
    for (final r in derivation.visibleRanges) {
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
      recs.add((label: r.label, start: start, end: end, rec: rec));
    }
    return recs;
  }

  /// Whether the Budget header tab renders. Editors/owners: always — tab
  /// presence must never depend on provider load state (a tab popping in
  /// after a slow load reads as flicker, and the derived selection would
  /// briefly point at a view with no tab). Viewers: only a non-empty budget
  /// earns the tab (target set or any expenses — the old collapsed row's
  /// gate), OR the Budget view is already open — the anti-stranding term: a
  /// refresh that empties the budget keeps the tab until the viewer leaves
  /// it. Watches are visibility atoms only, so spend edits repaint the
  /// budget body, not the screen.
  bool _budgetTabVisible() {
    if (!_readOnly) return true;
    if (_inBudgetView) return true;
    final hasTarget = ref.watch(budgetProvider(widget.tripId).select((a) {
      final b = a.valueOrNull;
      return b == null ? null : b.targetAmount != null;
    }));
    final expensesEmpty = ref.watch(expensesProvider(widget.tripId)
        .select((a) => a.valueOrNull?.isEmpty));
    if (hasTarget == null || expensesEmpty == null) return false;
    return hasTarget || !expensesEmpty;
  }

  /// The app-bar Trip health entry: fact-check icon with a calm badge,
  /// opening the findings sheet. Replaced the trailing-cluster row
  /// (friction-log 2026-08-12) — the badge is now the ONLY glanceable
  /// health surface, so it stays visible on every breakpoint.
  ///
  /// The number counts only the attention tier (critical + warn) — a raw
  /// total read as "27 problems" when most rows were gentle info suggestions
  /// (friction-log 2026-08-13). Info-only trips get a small neutral dot
  /// (presence without a shouting number); all-clear stays a plain icon.
  ///
  /// Base provider key (checkHours: false): the sheet's internal opt-in hours
  /// check flips ITS key to the slower variant, so this badge can briefly lag
  /// while that toggle is on — accepted. The whole action lives in one
  /// Consumer so review refetches repaint the icon alone; no value yet
  /// (first load, error, viewer 404) hides it, matching the old row's gate.
  Widget _healthAppBarAction(Trip trip, ThemeData theme) {
    return Consumer(
      builder: (context, ref, _) {
        final findings = ref
            .watch(tripReviewProvider(TripReviewKey(trip.id)))
            .valueOrNull
            ?.findings;
        if (findings == null) return const SizedBox.shrink();
        const icon = Icon(Icons.fact_check_outlined);
        final l10n = context.l10n;
        // Severity → color derived only via the shared statics; badgeColors
        // is the opaque on-gradient variant of the pill pair, and partition
        // is the same tier split the sheet renders — badge and sheet can
        // never disagree.
        final (:attention, :suggestions) =
            TripReviewSection.partition(findings);
        final colors = TripReviewSection.badgeColors(
            theme, attention.isEmpty ? 'info' : attention.first.severity);
        return IconButton(
          tooltip: l10n.reviewSectionTitle,
          onPressed: () => showTripHealthSheet(
            context,
            tripId: trip.id,
            // Live read, not a captured bool: the sheet route never rebuilds
            // on this screen's connectivity setState.
            isOffline: () => _isOffline,
            onScrollToDay: _scrollToDay,
            dayForItem: _dayOfItem,
            onApplyFix: _readOnly ? null : _applyFix,
          ),
          icon: findings.isEmpty
              ? icon
              : attention.isNotEmpty
                  ? Badge(
                      backgroundColor: colors.bg,
                      textColor: colors.fg,
                      label: Text(
                        '${attention.length}',
                        semanticsLabel: l10n
                            .reviewBadgeAttentionSemantics(attention.length),
                      ),
                      child: icon,
                    )
                  : Semantics(
                      label: l10n
                          .reviewBadgeSuggestionsSemantics(suggestions.length),
                      child: Badge(
                        // No label → Material's small-dot variant; 8 over the
                        // M3 default 6 for legibility on the gradient.
                        smallSize: 8,
                        backgroundColor: colors.bg,
                        child: icon,
                      ),
                    ),
        );
      },
    );
  }

  /// The app-bar "What to wear & pack" entry: the luggage icon, opening the
  /// wear/pack sheet. Replaced the trailing-cluster row (friction-log
  /// 2026-08-13) — the last of the trailing sections, so the cluster
  /// scaffolding left with it. No count badge: health's severity count sits
  /// next door and two adjacent numbers would compete; the checked/total
  /// pill lives in the sheet header instead.
  ///
  /// One Consumer scopes every watch to this icon, collapsing the old
  /// two-tier gate split (screen-scope bool selects + row-scope content
  /// watches): full watches here repaint the icon alone — the cost class
  /// the old row's Consumer already paid. Hidden while neither half has
  /// data (checklist unresolved or viewer-empty, and no leg with weather),
  /// matching the old row's gate. Not _inBudgetView-gated: that gate
  /// belonged to the scroll body, and health set the precedent that
  /// app-bar icons stay put across views.
  /// Whether wear & pack has anything to show, and the regions it would show.
  ///
  /// One derivation with two entry points — the app-bar icon at wide widths
  /// and the overflow item at narrow ones — so the gate can never disagree
  /// with itself about whether the surface is worth offering. [ref] must be a
  /// Consumer's, never the State's: the weather watches inside
  /// [_legClothingRecs] subscribe whatever ref they are handed, and the whole
  /// point is to subscribe one app-bar widget rather than the screen.
  ({bool available, List<WearRegionRec> regions}) _wearState(
      WidgetRef ref, Trip trip) {
    final items = ref.watch(checklistProvider(trip.id)).valueOrNull;
    final showChecklist = items != null && !(items.isEmpty && _readOnly);
    final recs = _legClothingRecs(trip, ref);
    return (available: recs.isNotEmpty || showChecklist, regions: recs);
  }

  void _openWearSheet(Trip trip, List<WearRegionRec> regions) =>
      showWearPackSheet(
        context,
        tripId: trip.id,
        // Snapshot: regions freeze at open (reopen refreshes); the
        // checklist half stays live via its own provider watch.
        regions: regions,
        canEdit: !_readOnly,
        // Live read, not a captured bool: the sheet route never
        // rebuilds on this screen's connectivity setState.
        isOffline: () => _isOffline,
      );

  Widget _wearAppBarAction(Trip trip) {
    return Consumer(
      builder: (context, ref, _) {
        final wear = _wearState(ref, trip);
        if (!wear.available) return const SizedBox.shrink();
        return IconButton(
          tooltip: context.l10n.wearSectionTitle,
          icon: const Icon(Icons.luggage_outlined),
          onPressed: () => _openWearSheet(trip, wear.regions),
        );
      },
    );
  }

  /// The share actions, grouped, factored out so the wide app bar's own share
  /// button and the narrow overflow that absorbs it can never drift into
  /// offering different things.
  ///
  /// "Turn off sharing" sits with the links it revokes rather than trailing
  /// the exports — it is a link action, and print/calendar are a different
  /// job. That adjacency is only safe because it confirms now; see
  /// [_revokeLink].
  List<List<TripAction>> _shareActionSections(AppLocalizations l10n) => [
        [
          TripAction(
            icon: shareUsesNativeSheet ? Icons.share_outlined : Icons.link,
            label: shareUsesNativeSheet
                ? l10n.tripShareLinkAction
                : l10n.tripCopyShareLink,
            onSelected: _shareLink,
          ),
          TripAction(
            icon: Icons.group_add_outlined,
            label: shareUsesNativeSheet
                ? l10n.tripShareInviteAction
                : l10n.tripCopyInviteLink,
            onSelected: _inviteCoPlanner,
          ),
          TripAction(
            icon: Icons.group_outlined,
            label: l10n.tripManageAccess,
            onSelected: _manageCoPlanners,
          ),
          TripAction(
            icon: Icons.link_off,
            label: l10n.tripTurnOffSharing,
            onSelected: _revokeLink,
          ),
        ],
        [
          TripAction(
            icon: Icons.description_outlined,
            label: l10n.tripPrintSavePdf,
            onSelected: _openPrintExport,
          ),
          TripAction(
            icon: Icons.calendar_month_outlined,
            label: l10n.tripAddToCalendar,
            onSelected: _openCalendarExport,
          ),
        ],
      ];

  /// The app bar's `⋮`. Always the home of the destructive exits — owners get
  /// delete, members (editors and viewer follows) get remove-from-my-list, so
  /// the owner's trip is untouched; both still confirm in their handlers.
  ///
  /// At narrow widths it also absorbs wear & pack and the whole share menu.
  /// That is what buys the ANEMOS wordmark its room: five icons on a 360px
  /// bar leave the title slot smaller than the wordmark itself.
  ///
  /// Narrow opens a bottom sheet, wide a popup, both rendered from the same
  /// [TripAction] sections — ten entries anchored in a phone's top-right
  /// corner was the one stack of choices on this screen that wasn't already a
  /// sheet. At wide the list is down to a single entry, and that is
  /// deliberate: the destructive exits live behind a menu so they cannot be
  /// hit by accident. Do not put the bare trash icon back.
  ///
  /// A Consumer rather than a bare button because the wear gate is a provider
  /// watch that must subscribe this button alone, not the screen — and the
  /// sections are built here rather than inside `itemBuilder` for the same
  /// reason: a menu builder has no ref to watch with.
  Widget _overflowAppBarAction(Trip trip, AppLocalizations l10n) {
    return Consumer(
      builder: (context, ref, _) {
        final wear = _narrow
            ? _wearState(ref, trip)
            : (available: false, regions: const <WearRegionRec>[]);
        final absorbsShare = _narrow && trip.isOwner && !_isOffline;
        // Offline hides the mutating exits; the read-only sheets stay.
        final canExit = !_isOffline;
        // Fold all / unfold all, narrow only (wide keeps it in the itinerary
        // header row). The one entry here with NO gate at all — folding is
        // view work, so viewers and offline-served copies get it, which is
        // also why it leads: the destructive exits own the bottom. It does
        // mean a narrow viewer reading offline now sees a `⋮` where every
        // entry used to be gated away and the button collapsed to nothing —
        // correct, since it finally has something they can do.
        final d = _derive(trip);
        final foldShown = _narrow && _foldControlShown(d);
        final foldCollapsed = foldShown && _allGroupsCollapsed(d);

        // Sections in order; the separators between them are DERIVED from
        // these boundaries and empty sections drop out, so nothing here
        // places a divider. What this replaced guarded each one with an `||`
        // chain that grew a term per feature and was already a term out of
        // step with the block it fenced.
        //
        // Trip airports deliberately has no entry: a derived home leg carries
        // its own "Change airport" link, which is where somebody looking to
        // change one actually looks.
        final sections = <List<TripAction>>[
          [
            if (foldShown)
              TripAction(
                icon: foldCollapsed ? Icons.unfold_more : Icons.unfold_less,
                label:
                    foldCollapsed ? l10n.tripExpandAll : l10n.tripCollapseAll,
                onSelected: () => _toggleAllGroups(trip),
              ),
            if (wear.available)
              TripAction(
                icon: Icons.luggage_outlined,
                label: l10n.wearSectionTitle,
                onSelected: () => _openWearSheet(trip, wear.regions),
              ),
          ],
          // Refine, narrow only — it held an app-bar icon until the header
          // needed that ~48px for the trip's own name. Its own section
          // because the group above is "look at this trip differently" and
          // this one changes it.
          //
          // Editors only (specs/collaborator-refine), and offline HIDES it
          // rather than disabling it: the icon could gray out, but a sheet row
          // has no disabled state, and hiding a mutating entry offline is
          // already this menu's vocabulary — same as share and the exits.
          [
            if (_narrow && trip.canEdit && !_isOffline)
              TripAction(
                icon: Icons.auto_awesome,
                label: l10n.tripRefineWithAI,
                onSelected: () => _openRefine(trip, const RefineTarget.trip()),
              ),
          ],
          if (absorbsShare) ..._shareActionSections(l10n),
          [
            if (canExit)
              trip.isOwner
                  ? TripAction(
                      icon: Icons.delete_outline,
                      label: l10n.tripDeleteTrip,
                      onSelected: _delete,
                      destructive: true,
                    )
                  : TripAction(
                      icon: Icons.bookmark_remove_outlined,
                      label: l10n.tripRemoveFromMyTrips,
                      onSelected: _leaveTrip,
                    ),
          ],
        ];
        if (sections.every((s) => s.isEmpty)) return const SizedBox.shrink();

        if (_narrow) {
          return IconButton(
            // share_plus needs a rect to point the iPad popover at, and the
            // anchor has to be whichever button is actually on screen — here
            // the button itself, since the sheet it opens is gone by the time
            // the share call fires.
            key: absorbsShare ? _shareMenuKey : null,
            icon: const Icon(Icons.more_vert),
            tooltip: l10n.tripMoreActions,
            onPressed: () async {
              final action =
                  await showTripActionsSheet(context, sections: sections);
              // Run after the sheet closes, never from inside it: its context
              // is dead, and share_plus must anchor on a live button.
              if (action != null && mounted) action.onSelected();
            },
          );
        }
        return PopupMenuButton<TripAction>(
          icon: const Icon(Icons.more_vert),
          tooltip: l10n.tripMoreActions,
          onSelected: (action) => action.onSelected(),
          itemBuilder: (context) => tripActionPopupEntries(context, sections),
        );
      },
    );
  }

  // Destination pins live in [TripDerivation.mapDestinations]: one per
  // location group with a real coordinate, in visit order, derived from the
  // FULL itinerary — never the day/category-filtered view, which would shift
  // the numbering (the home-leg doctrine in [_openFullMap]).

  /// Read-side clamp for [_focusedLegKey]: a refresh can remove the focused
  /// leg (or shrink the trip below two legs, where focus is disabled); a key
  /// with no current leg reads as All. Clamping at read — instead of writing
  /// the notifier during build — keeps build pure; the stale value is
  /// harmless because every consumer goes through here with the current
  /// derivation.
  String? _clampedLegKey(TripDerivation d) {
    final key = _focusedLegKey.value;
    if (key == null) return null;
    if (d.legs.length < 2 || d.legIndexOf(key) == null) return null;
    return key;
  }

  // Home-leg endpoints live in [TripDerivation.homeLegEndpoints] — the
  // trip's first/last location groups, the same derivation the
  // outbound/return booking todos trust — never the first/last mapped pin,
  // which shifts under leg focus.

  /// Pushes the full-screen interactive map. Root navigator so the map
  /// covers the bottom navigation bar; the closures read the live [_trip] so
  /// a silent refresh propagates on the next chip tap.
  void _openFullMap(Trip trip) {
    final rootNav = Navigator.of(context, rootNavigator: true);
    // Double-tap guard, and the one place isTopRoute cannot serve: it answers
    // about THIS tab's navigator, where the detail stays current no matter
    // what lands on the root one. The root navigator holds only the shell
    // (main.dart's one-initial-route invariant), so anything poppable there
    // is already covering it — including the map a first tap just opened.
    if (rootNav.canPop()) return;
    final derivation = _derive(trip);
    final endpoints = derivation.homeLegEndpoints;
    rootNav.push(
      MaterialPageRoute(
        fullscreenDialog: true,
        // Escape closes the map when focus rests on the route's own scope
        // (pin-less leg: the empty state has no focusable map): the
        // framework's Escape→DismissIntent handler pops any route with a
        // dismissible barrier (PageRoute.barrierDismissible docs), and the
        // barrier itself is never visible behind an opaque full-screen
        // route. Escape from inside the Scaffold is handled by the
        // CallbackShortcuts layer in TripMapScreen — see the comment there.
        barrierDismissible: true,
        builder: (_) => TripMapScreen(
          title: _displayTitle(trip),
          destinations: derivation.mapDestinations,
          homeAirport: _homeAirport,
          travelMode: trip.travelMode,
          tripOrigin: trip.origin,
          tripOriginAirport: trip.originAirport,
          tripReturnAirport: trip.returnAirport,
          firstCityPoint: endpoints.first,
          lastCityPoint: endpoints.last,
          itemsForLeg: (k) {
            final t = _trip;
            return t == null
                ? const <ItineraryItem>[]
                : _derive(t).legFilteredItems(k);
          },
          staysForLeg: (k) {
            final t = _trip;
            return t == null
                ? const <Accommodation>[]
                : _derive(t).legFilteredStays(k);
          },
          segmentLabels: _mapSegmentLabels(derivation),
          legChips: derivation.legChips,
          mappedLegKeys: derivation.mappedLegKeys,
          initialLegKey: _clampedLegKey(derivation),
          // A full-screen chip or region-pin tap reports here: the embedded
          // card's ListenableBuilder keeps its own chips in sync live, and
          // _setFocusedLeg pre-selects (un-collapses the target; on desktop
          // pre-scrolls) behind the modal, so focus survives close. On
          // phones _setFocusedLeg skips its scroll (the inline chips ride
          // the scroll-away preview), but a selection made INSIDE the full
          // map should land the list on that region when the modal closes —
          // there is no visible list to disturb — so pre-scroll here too.
          onLegSelected: (k) {
            final t = _trip;
            if (t == null) return;
            final d = _derive(t);
            _setFocusedLeg(d, k);
            if (k == null || _mapPinned) return;
            final groupKey = d.groupKeyForLeg(k);
            if (groupKey == null) return;
            _revealCityHeader(groupKey);
          },
          onAddPlace: (_isOffline || _readOnly)
              ? null
              : (k) {
                  final t = _trip;
                  _addPlace(day: t == null ? null : _derive(t).dayForLeg(k));
                },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final trip = _trip;

    // The agent can change the saved home airport mid-session
    // (save_preferences), and the plan stream re-reads preferences when it
    // reports profile_updated. Both the map's endpoint pins and the
    // checklist's fallback label read _homeAirport, so mirror the change here
    // instead of leaving the open page showing the old airport until restart.
    // Guarded, like the load path's own write: an unrelated preferences save
    // must not re-sync the checklist.
    ref.listen(preferencesProvider.select((s) => s.prefs?.homeAirport),
        (_, next) {
      if (!mounted || next == _homeAirport) return;
      setState(() => _homeAirport = next);
      final t = _trip;
      if (t != null && (t.items ?? const []).isNotEmpty) {
        unawaited(_syncBookingTodos(t));
      }
    });

    // The trip-update listener lives HERE, not in TripRefinePanel: back closes
    // the panel (see the PopScope below) and a turn keeps streaming after it,
    // so a patch that lands once the panel is gone must still refresh the
    // itinerary. Monotonic counter — see chat-panel-architecture.
    ref.listen(
        tripRefineProvider(widget.tripId).select((s) => s.tripUpdateCount),
        (prev, next) {
      if (mounted && next > (prev ?? 0)) {
        // Snapshot BEFORE the refetch — _trip is still the pre-turn state
        // here — so the reveal can tell what this turn added. Without it a
        // chat that reports "added 4 places" leaves them inside folded
        // cities and the list appears not to have moved.
        _armRevealOfNewItems();
        _refresh();
      }
    });
    // A turn still running behind a closed panel: the FAB says so, or an
    // accidental back reads as "did that kill it?".
    final chatStreaming = ref.watch(
        tripRefineProvider(widget.tripId).select((s) => s.isStreaming));

    return LayoutBuilder(builder: (context, constraints) {
      // Same width the body LayoutBuilder sees (Scaffold adds no horizontal
      // chrome), so this always agrees with _mapPinned. Plain assignment:
      // we're in build, like _mapPinned's own write.
      _narrow = constraints.maxWidth < kRailBreakpoint;
      return PopScope(
        // Back closes the chat before it leaves the trip. The panel is drawn
        // inside the screen rather than pushed as a route, and on narrow it
        // looks like a sheet — so back is the obvious gesture for dismissing
        // it, and used to throw away the whole page instead
        // (specs/trip-refine-memory). Composes with AppShell's own
        // PopScope(canPop: false), which forwards to this tab navigator's
        // maybePop(); that consults the top route's PopScope, i.e. this one.
        canPop: !_panelOpen,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _panelOpen) setState(() => _panelOpen = false);
        },
        child: Scaffold(
      // Always-reachable chat entry, mirroring the _openRefine guards so it's
      // never a dead button. Hidden while the panel is open: on wide layouts
      // the panel is docked (redundant), on narrow it would overlap the sheet.
      //
      // A saved conversation ALSO opens the gate: the zero-item plan_itinerary
      // Next Step seeds a chat on an empty trip, so requiring items would make
      // the saved chat unreachable on exactly the trips that most need it.
      floatingActionButton: (trip != null &&
              !_panelOpen &&
              trip.canEdit &&
              !_isOffline &&
              ((trip.items?.isNotEmpty ?? false) || trip.refineChat != null))
          ? FloatingActionButton(
              tooltip: l10n.tripAskAI,
              onPressed: () => _openChat(trip),
              child: chatStreaming
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chat_bubble_outline),
            )
          : null,
      appBar: GradientAppBar(
        title: trip != null ? _displayTitle(trip) : l10n.tripTitleFallback,
        actions: [
          // This is the app's width-budget boss: five icons beside the brand
          // fit at rail widths and nowhere near it on a phone. At narrow
          // everything that is already a menu or a sheet folds into the
          // overflow (see [_overflowAppBarAction]) and the icon row drops to
          // TWO — health plus the `⋮` itself.
          //
          // Health is the one action that earns an icon on a phone: its
          // severity count is a glanceable badge, and a badge inside a menu is
          // a badge nobody sees. Everything else is one tap further away and
          // the trip's NAME gets the ~48px back — at 375px that is the
          // difference between "Big Su…" and a name you can read, which is
          // what the traveler actually needed the header for.
          //
          // Refine used to hold an icon here at narrow — it is the header
          // card's own Refine button relocated, since narrow drops it down
          // there for one clean chip row. It now rides the `⋮` instead, and
          // the header card must STAY as it is: putting its button back is
          // what #457's chip row was tidying away.
          if (trip != null) _healthAppBarAction(trip, theme),
          if (trip != null && !_narrow) _wearAppBarAction(trip),
          // Sharing is an owner-only surface; it mutates, so it's hidden
          // while offline-serving.
          if (trip != null && trip.isOwner && !_isOffline && !_narrow)
            PopupMenuButton<TripAction>(
              key: _shareMenuKey,
              icon: const Icon(Icons.share_outlined),
              tooltip: l10n.tripShareTrip,
              onSelected: (action) => action.onSelected(),
              itemBuilder: (context) =>
                  tripActionPopupEntries(context, _shareActionSections(l10n)),
            ),
          if (trip != null) _overflowAppBarAction(trip, l10n),
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
                      const SizedBox(height: 4),
                      // Status-aware subtitle: a residual 429 reads as "slow
                      // down a moment", offline as a network problem — not
                      // one opaque dead end for every failure.
                      Text(
                        friendlyError(l10n, _error),
                        style: Theme.of(context).textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
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
                      final panelDocked =
                          _panelOpen && constraints.maxWidth >= 900;
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
                      final groups = derivation.groups;
                      // Shared per-build chip width — see _dateChipWidth's
                      // doc for why this must stay a build-local. Narrow
                      // stacks the dates under the name instead of rendering
                      // the chip, so nothing consumes the measurement and the
                      // TextPainter sweep over every group is skipped.
                      final dateChipWidth =
                          _narrow ? 0.0 : _dateChipWidth(groups, theme);
                      // Day-header GlobalKeys for the CURRENT groups' day
                      // keys, not just whatever happens to be built: a
                      // collapsed group's day headers don't exist yet, but
                      // their keys must still resolve so _scrollToDay can
                      // expand the group and land (specs/today-mode).
                      for (final key in derivation.liveDayKeys) {
                        _dayHeaderKeys.putIfAbsent(key, GlobalKey.new);
                      }
                      // Date window per city group for the embedded weather and
                      // events lookups: the VISIBLE ranges, index-aligned with
                      // [groups] — the same window the group's header chip
                      // renders. Anything else means a section can promise
                      // "while you're here" over dates the traveler was never
                      // shown; the raw ranges did exactly that (friction-log
                      // 2026-08-14). Per-index, so a revisited city gets its
                      // own visit's window instead of a label collision.
                      final groupRanges = derivation.visibleRanges;
                      ({DateTime? start, DateTime? end})? rangeFor(int gi) =>
                          gi < groupRanges.length
                              ? (
                                  start: groupRanges[gi].start,
                                  end: groupRanges[gi].end
                                )
                              : null;
                      final tripStart = DateTime.tryParse(trip.startDate ?? '');
                      // Map leg chips (specs/map-city-focus) read straight
                      // off the derivation inside _mapCard: legChips and
                      // mappedLegKeys are trip-wide, and a stale focused key
                      // (a refresh can drop a leg) is clamped read-side by
                      // every consumer via _clampedLegKey; build never
                      // writes it.
                      // Today mode: the jump chip renders only when today
                      // falls inside the trip's dates AND some item carries a
                      // day tag (the same gate as the auto-scroll, so the
                      // chip never points at nothing).
                      final todayDay =
                          tripDayOn(trip.startDate, trip.endDate, DateTime.now());
                      final hasTodayTarget = todayDay != null &&
                          (trip.items ?? const <ItineraryItem>[])
                              .any((i) => i.day != null);
                      // Fold-all control: WIDE only. On narrow it moves into
                      // the app-bar overflow (the wear & pack / share
                      // precedent) — the phone row's three tabs, Today chip
                      // and add button are already the FittedBox budget that
                      // cost the Bookings count pill its place.
                      final foldShown =
                          !_narrow && _foldControlShown(derivation);
                      final foldCollapsed =
                          foldShown && _allGroupsCollapsed(derivation);
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
                                  TripHeaderCard(
                                    trip: trip,
                                    narrow: _narrow,
                                    isOffline: _isOffline,
                                    readOnly: _readOnly,
                                    panelOpen: _panelOpen,
                                    displayTitle: _displayTitle(trip),
                                    overview: _overviewText(trip),
                                    onEditDetails: _editTripDetails,
                                    onEditDates: _editDates,
                                    onRefine: () => _openRefine(
                                        trip, const RefineTarget.trip()),
                                    onNextStepAction: (step) =>
                                        _onNextStepAction(trip, step),
                                    onOpenHealthSheet: () =>
                                        _openHealthSheet(trip),
                                    transportHandsOff: _transportHandsOff,
                                    onOpenChat: () => _openChat(trip),
                                    onNewChat: () => _newChat(trip),
                                  ),
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
                            tripDetailMapBandSliver(
                              pinned: _mapPinned,
                              gutter: gutter,
                              backgroundColor:
                                  theme.scaffoldBackgroundColor,
                              cardBuilder: (expandable) =>
                                  TripDetailMapBand(
                                trip: trip,
                                derivation: derivation,
                                expandable: expandable,
                                focusedLegKey: _focusedLegKey,
                                selectedPosition: _selectedPosition,
                                homeAirport: _homeAirport,
                                isOffline: _isOffline,
                                readOnly: _readOnly,
                                segmentLabels:
                                    _mapSegmentLabels(derivation),
                                onAddPlace: (day) => _addPlace(day: day),
                                onRevealGroup: (groupKey) {
                                  if (_collapsedGroups.remove(groupKey)) {
                                    setState(() {});
                                  }
                                },
                                onRevealCityHeader: _revealCityHeader,
                                onSetFocusedLeg: (k) =>
                                    _setFocusedLeg(derivation, k),
                                onOpenFullMap: () => _openFullMap(trip),
                                onShowSnack: _showSnack,
                                clampLegKey: _clampedLegKey,
                              ),
                              pinnedDelegateBuilder: (
                                      {required height,
                                      required backgroundColor,
                                      required padding,
                                      required child}) =>
                                  _PinnedHeaderDelegate(
                                height: height,
                                backgroundColor: backgroundColor,
                                padding: padding,
                                child: child,
                              ),
                            ),
                          // Itinerary/Bookings tab row; pins beneath the map
                          // so the view tabs, Today jump, and the view's add
                          // button stay reachable while scrolling. One
                          // fixed-height row keeps the pinned chrome (and
                          // the Today scroll math) constant.
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
                                  height: 44,
                                  child: Row(
                                    children: [
                                      Expanded(
                                        // View tabs (pure view work, so not
                                        // offline-gated). Composition and
                                        // per-tab gating live in _viewTabs.
                                        child: _viewTabs(trip, theme),
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
                                          // scroll): allowed offline and
                                          // while the refine panel is
                                          // open. _scrollToDay owns the
                                          // map-focus write (the
                                          // landed-on day's leg) — no
                                          // duplicate focus write here.
                                          onPressed: () =>
                                              _scrollToDay(todayDay),
                                        ),
                                        const SizedBox(width: 4),
                                      ],
                                      // Fold or unfold every destination in
                                      // one tap. PURE VIEW WORK, so — like
                                      // the view tabs and the Today chip
                                      // above — it is NOT gated on offline,
                                      // canEdit or the refine panel: viewers
                                      // and offline-served copies fold too,
                                      // and a long itinerary you can only
                                      // read is exactly where this helps
                                      // most. Do not copy the add CTAs'
                                      // gates below.
                                      //
                                      // Compact density is load-bearing: the
                                      // row is a hard 44px SizedBox feeding
                                      // _listHeaderHeight (56) and the
                                      // Today-scroll chrome math, and a
                                      // default-density IconButton is 48.
                                      if (foldShown)
                                        IconButton(
                                          onPressed: () =>
                                              _toggleAllGroups(trip),
                                          tooltip: foldCollapsed
                                              ? l10n.tripExpandAll
                                              : l10n.tripCollapseAll,
                                          visualDensity:
                                              VisualDensity.compact,
                                          icon: Icon(
                                              foldCollapsed
                                                  ? Icons.unfold_more
                                                  : Icons.unfold_less,
                                              size: 20),
                                        ),
                                      // One add CTA per view: Add place on
                                      // the itinerary, the Add-booking menu
                                      // in the Bookings view (a swap, not an
                                      // addition), NOTHING in the Budget
                                      // view — its body owns the add-expense
                                      // row. Icon-only on phones: the
                                      // tab trio + Today + a labeled button
                                      // can't all fit a 390px row with
                                      // Spanish labels (precedent: the
                                      // header Refine button becomes the
                                      // app-bar sparkle on narrow).
                                      if (!_readOnly && _inBookingsView)
                                        _addBookingMenu()
                                      else if (!_readOnly &&
                                          !_inBudgetView &&
                                          _narrow)
                                        IconButton(
                                          onPressed: _isOffline
                                              ? null
                                              : _addPlace,
                                          tooltip: l10n.tripAddPlace,
                                          visualDensity:
                                              VisualDensity.compact,
                                          icon:
                                              const Icon(Icons.add, size: 20),
                                        )
                                      else if (!_readOnly && !_inBudgetView)
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
                          // Budget view: one plain box sliver (no pinned
                          // header, so the zero-body pinned-sliver hazard
                          // can never arise). First so it wins over the
                          // items-empty branch — the Budget tab is offered
                          // on place-less trips. Bottom pad clears the chat
                          // FAB like the trailing cluster's.
                          if (_inBudgetView)
                            SliverPadding(
                              padding:
                                  EdgeInsets.fromLTRB(gutter, 4, gutter, 96),
                              sliver: SliverToBoxAdapter(
                                child: BudgetSection(
                                  tripId: trip.id,
                                  canEdit: !_readOnly,
                                  isOffline: _isOffline,
                                  legChips: derivation.legChips,
                                ),
                              ),
                            )
                          else if ((trip.items ?? []).isEmpty)
                            SliverPadding(
                              padding:
                                  EdgeInsets.symmetric(horizontal: gutter),
                              sliver: SliverToBoxAdapter(
                                child: SizedBox(
                                  // Taller than the bare state was: the action
                                  // below needs room above EmptyState's own
                                  // scroll-clip floor.
                                  height: 320,
                                  child: EmptyState(
                                    icon: Icons.place_outlined,
                                    title: l10n.tripNoPlacesYet,
                                    message: l10n.tripNoPlacesYetMessage,
                                    // The message names a door ("Refine with AI
                                    // or add a place") and used to hand over
                                    // none. EmptyState has supported actions all
                                    // along.
                                    actions: [
                                      FilledButton.icon(
                                        key: const ValueKey('empty-trip-plan'),
                                        icon: const Icon(Icons.auto_awesome,
                                            size: 18),
                                        label: Text(l10n.tripPlanWithAI),
                                        onPressed:
                                            (trip.canEdit && !_isOffline)
                                                ? () => _openRefine(trip,
                                                    const RefineTarget.trip())
                                                : null,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            )
                          else if (_itemFilter == 'unbooked')
                            // Bookings view, left-to-book scope: a flat list
                            // in place of the city groups. The filter row
                            // renders above BOTH arms — selected atop the
                            // celebration it says why the list is empty
                            // and is the one-tap way back to every booking.
                            SliverPadding(
                              padding:
                                  EdgeInsets.fromLTRB(gutter, 4, gutter, 0),
                              sliver: _boxSliver(
                                  _unbookedViewBody(grouped, legLabels)),
                            )
                          else if (_itemFilter == 'bookings')
                            // All-bookings lens: the whole trip's bookings
                            // (booked and unbooked) in place of the city
                            // groups, filterable by destination. One surface
                            // at a time — the inline rows render only in the
                            // itinerary view, so booked-state never shows on
                            // two surfaces at once (the PR #274 bar).
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
                          // Explicitly == 'all', not a bare else: a future
                          // fifth view state renders nothing here (loudly
                          // missing) instead of the itinerary body — whose
                          // embedded booking rows under another view would
                          // re-break the one-surface bar (PR #274).
                          else if (_itemFilter == 'all')
                            // Each city is a MultiSliver whose header pins
                            // beneath the tab row while the city's items
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
                                  // An expanded group always has a body (a
                                  // CityGroup exists only because its leg
                                  // has items, and _buildGroupItemSlivers
                                  // emits at least the day rows), so the
                                  // pinned branch can never go zero-body.
                                  // N groups expand at once now (all, by
                                  // default): each inner containing
                                  // MultiSliver pushes its own header off
                                  // at its group's end, so headers hand off
                                  // edge-to-edge and exactly one obstructs
                                  // at rest — the outer MultiSliver must
                                  // stay NON-containing (no
                                  // pushPinnedChildren), or every header
                                  // would pin to the end of the itinerary
                                  // and stack.
                                  if (_collapsedGroups.contains(group.key))
                                    SliverToBoxAdapter(
                                        child: KeyedSubtree(
                                            // Keyed by the run, not the city:
                                            // a revisited city renders two
                                            // headers at once and a shared
                                            // GlobalKey would break the build.
                                            key: _cityHeaderKeys.putIfAbsent(
                                                group.key, GlobalKey.new),
                                            child: _cityHeader(
                                                trip, group, theme,
                                                dateChipWidth,
                                                cityCollapsed: true)))
                                  else
                                    MultiSliver(
                                      pushPinnedChildren: true,
                                      children: [
                                        SliverPinnedHeader(
                                            child: KeyedSubtree(
                                                key: _cityHeaderKeys
                                                    .putIfAbsent(group.key,
                                                        GlobalKey.new),
                                                child: _cityHeader(
                                                    trip, group, theme,
                                                    dateChipWidth,
                                                    cityCollapsed: false))),
                                        // The city's embedded booking rows —
                                        // slots are index-aligned with groups.
                                        if (gi < grouped.slots.length)
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
                                            range: rangeFor(gi),
                                            emptyDays: group.emptyDays),
                                        // Curated local recommendations for this
                                        // city — the "legit info you can't
                                        // google" surface. Leads the events
                                        // section.
                                        _localIntelSliver(group.label, theme),
                                        // Local events for this city's dates.
                                        _eventsSliver(trip, group.label,
                                            rangeFor(gi), theme),
                                        if (gi == groups.length - 1 &&
                                            gi < grouped.slots.length)
                                          _boxSliver(_bookingRowWidgets(
                                              grouped.slots[gi],
                                              departureOnly: true)),
                                      ],
                                    ),
                              ]),
                            ),
                          // Residual bookings, at the tail of the
                          // itinerary — itinerary view only (the Bookings
                          // and Budget views swap in their own bodies
                          // above).
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
                          // Keeps the chat FAB off the last row. Stays
                          // gated: the Budget view's sliver above pads its
                          // own 96, so an unconditional spacer would
                          // double-pad it. The trailing section cluster
                          // that lived here is gone — Wear & pack was its
                          // last row and now opens from the app bar
                          // (_wearAppBarAction).
                          if (!_inBudgetView)
                            const SliverToBoxAdapter(
                                child: SizedBox(height: 96)),
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

                      if (!_panelOpen) {
                        return refreshable;
                      }
                      // Escape is back's desktop twin: the panel is where focus
                      // lives while chatting, so the binding rides it rather
                      // than the whole screen (the map's own Escape layer is a
                      // pushed route and never collides).
                      final panel = CallbackShortcuts(
                        bindings: {
                          const SingleActivator(LogicalKeyboardKey.escape): () =>
                              setState(() => _panelOpen = false),
                        },
                        // The binding only fires along the focus chain, and the
                        // composer isn't focused until the traveler clicks it —
                        // so the panel takes focus on open and every descendant
                        // (composer included) still bubbles Escape up through
                        // here. skipTraversal keeps it out of the tab order.
                        child: Focus(
                          autofocus: true,
                          skipTraversal: true,
                          child: TripRefinePanel(
                            tripId: widget.tripId,
                            phase: _chatPhase,
                            error: _chatError,
                            onClose: () => setState(() => _panelOpen = false),
                            onNewChat: () => _newChat(trip),
                            onRetry: _chatPhase == RefineChatPhase.failed
                                ? () {
                                    _chatResumeTried = false;
                                    _ensureRefineHydrated(trip);
                                  }
                                : null,
                          ),
                        ),
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
                      // Narrow: the chat OPENS FULL — everything between the app
                      // bar and the nav bar. It used to open at 0.45, where the
                      // panel's own header and composer are fixed costs that
                      // left ~200px of transcript: one quick-reply chip and a
                      // clipped bubble, on the surface the whole feature lives
                      // on. Shrinking it is now a deliberate drag, not the
                      // state you land in.
                      //
                      // snap with no snapSizes snaps to [min, max], so there
                      // are exactly two resting places: full, and a 0.4 peek
                      // that still shows the header and composer over a slice
                      // of the itinerary. (0.45 wasn't even a snap target,
                      // which is why the old sheet felt arbitrary.) Nothing is
                      // remembered — every open starts full, so a peek can't
                      // silently become the next open's default.
                      return Stack(
                        children: [
                          refreshable,
                          DraggableScrollableSheet(
                            initialChildSize: 1.0,
                            minChildSize: 0.4,
                            maxChildSize: 1.0,
                            snap: true,
                            builder: (context, scrollController) => Material(
                              elevation: 8,
                              borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(16)),
                              clipBehavior: Clip.antiAlias,
                              // No keyboard padding here: the Scaffold's
                              // resizeToAvoidBottomInset (unset => true) hands
                              // the body a MediaQuery with viewInsets.bottom
                              // already removed, so the EdgeInsets.only that
                              // used to sit here read 0 on every platform and
                              // the composer was kept above the keyboard by the
                              // body shrinking, not by this. It mattered more
                              // once the sheet went full-height, so it was
                              // checked rather than inherited.
                              child: Column(
                                children: [
                                  // Drag handle (also a scrollable so the sheet
                                  // responds to drags at its header). This strip
                                  // is the ONLY place a drag resizes the sheet —
                                  // the transcript's ListView has its own
                                  // controller by design, so scrolling messages
                                  // can't collapse the chat — and now that the
                                  // sheet opens full, it is also the only way
                                  // back down. The margin is the grab area, not
                                  // decoration: 8 left a ~20px target at the
                                  // very top edge of the screen.
                                  SingleChildScrollView(
                                    key: const Key('refineSheetHandle'),
                                    controller: scrollController,
                                    child: Center(
                                      child: Container(
                                        width: 36,
                                        height: 4,
                                        margin: const EdgeInsets.symmetric(
                                            vertical: 14),
                                        decoration: BoxDecoration(
                                          color:
                                              theme.colorScheme.outlineVariant,
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
                        ],
                      );
                    }),
        ),
      );
    });
  }

  /// Resolves a Next Step transport fix to its client-synced checklist row.
  /// The fix's [FindingFix.origin]/[FindingFix.destination] are cased display
  /// labels (the server splits the todo's 'A → B' title back apart), while
  /// todo keys follow the documented lowercase
  /// 'transport:origin>>destination' convention (specs/next-step-cta) —
  /// lowercasing both sides absorbs the round trip. Null when the fix isn't a
  /// transport one, an endpoint is missing (an older server's fix-less step),
  /// or no synced todo matches; the caller falls back to the seeded chat.
  /// Whether a transport step's tap will hand off to a provider rather than
  /// open the seeded chat — the SAME resolution [_onNextStepAction] performs,
  /// so the card's label can never promise a handoff the action won't make.
  /// Building the callback is side-effect free (the tracking rides inside the
  /// returned closure), so it is safe to ask during build.
  bool _transportHandsOff(NextStep step) {
    if (step.kind != 'add_transport') return false;
    final todo = _transportTodoForFix(step.fix);
    return todo != null && _openCallbackFor(todo) != null;
  }

  BookingTodo? _transportTodoForFix(FindingFix? fix) {
    if (fix == null || fix.action != 'add_transport') return null;
    final origin = fix.origin;
    final destination = fix.destination;
    if (origin == null || origin.isEmpty) return null;
    if (destination == null || destination.isEmpty) return null;
    final key =
        'transport:${origin.toLowerCase()}>>${destination.toLowerCase()}';
    for (final t in _bookingTodos) {
      if (t.kind == 'transport' && t.todoKey.toLowerCase() == key) return t;
    }
    return null;
  }

  /// The open action for a booking item: a transport item with a known flight
  /// leg opens the in-app Find Flights screen prefilled; everything else falls
  /// back to its external provider search link. [surface] is the analytics
  /// attribution for where the tap came from — the checklist rows keep the
  /// default; the Next Step card passes its own.
  VoidCallback? _openCallbackFor(BookingTodo todo,
      {String surface = 'booking_checklist'}) {
    // The attach-rate numerator (specs/instrumentation-events): opening any
    // booking handoff counts as a click. External links record-then-launch via
    // trackedLaunchUrl; the one in-app handoff (Find Flights) records via the
    // same helper before navigating. Fire-and-forget either way.
    if (todo.kind == 'transport') {
      final ferry = _ferryLegs[todo.todoKey];
      if (ferry != null) {
        return () => _openFerry(ferry, todo, surface: surface);
      }
      final leg = _flightLegs[todo.todoKey];
      if (leg != null) {
        return () {
          trackBookingLinkClick(
            context,
            provider: 'duffel',
            surface: surface,
            tripId: widget.tripId,
            todoKey: todo.todoKey,
            kind: todo.kind,
          );
          pushOnce(
              context,
              MaterialPageRoute(
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
          surface: surface,
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
      ({String origin, String destination, String? date}) leg, BookingTodo todo,
      {String surface = 'booking_checklist'}) async {
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
          surface: surface,
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
      // Repaint-isolate the pinned chrome (map band, tab row): while pinned
      // it would otherwise re-record into the viewport picture every scroll
      // frame. Child identity is what keeps the layer valid — this method
      // runs per shrinkOffset change, so never build the child inside it;
      // always construct it once and pass it in by instance.
      RepaintBoundary(
        child: Container(
          color: backgroundColor,
          padding: padding,
          child: child,
        ),
      );

  @override
  bool shouldRebuild(_PinnedHeaderDelegate oldDelegate) =>
      oldDelegate.child != child ||
      oldDelegate.height != height ||
      oldDelegate.backgroundColor != backgroundColor ||
      oldDelegate.padding != padding;
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
