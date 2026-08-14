import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/trip.dart';
import '../utils/trip_days.dart';
import '../utils/trip_format.dart';
import 'auth_provider.dart';
import 'live_trip_provider.dart';
import 'trip_cache_provider.dart';
import 'trips_provider.dart';

/// The trip detail screen the user last opened, remembered on-device so the
/// home screen can offer a one-tap way back into it. Carries a snapshot of the
/// date range so the tile can surface state, not just a name.
class RecentTrip {
  final String tripId;
  final String title;
  final String? dateRange;

  const RecentTrip({
    required this.tripId,
    required this.title,
    this.dateRange,
  });
}

class RecentTripNotifier extends StateNotifier<RecentTrip?> {
  /// Signed-in user the stored value belongs to; null when anonymous, in which
  /// case nothing is recorded (trips require sign-in anyway).
  final String? _userId;

  RecentTripNotifier(this._userId) : super(null);

  String get _key => 'recent_trip.$_userId';

  /// Restore the last viewed trip for this user from device storage. Older
  /// snapshots may carry extra keys (e.g. the retired trip status) — they are
  /// simply ignored.
  Future<void> load() async {
    if (_userId == null) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final id = m['id'] as String?;
      final title = m['title'] as String?;
      if (id != null && id.isNotEmpty && title != null) {
        state = RecentTrip(
          tripId: id,
          title: title,
          dateRange: m['dateRange'] as String?,
        );
      }
    } catch (_) {
      // Malformed value — ignore and stay empty.
    }
  }

  /// Remember [tripId] as the most recently viewed trip. Call after a trip
  /// detail screen successfully loads. [dateRange] is a snapshot for the home
  /// tile.
  Future<void> record(
    String tripId,
    String title, {
    String? dateRange,
  }) async {
    if (_userId == null) return;
    state = RecentTrip(
      tripId: tripId,
      title: title,
      dateRange: dateRange,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode({
        'id': tripId,
        'title': title,
        if (dateRange != null) 'dateRange': dateRange,
      }),
    );
  }

  /// Forget the recent trip if it points at [tripId] (used when a trip is
  /// deleted, so the home tile never targets a dead trip).
  Future<void> clearIfMatches(String tripId) async {
    if (_userId == null || state?.tripId != tripId) return;
    state = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

/// Rebuilds on sign-in/out so each user only ever sees their own recent trip.
final recentTripProvider =
    StateNotifierProvider<RecentTripNotifier, RecentTrip?>((ref) {
  final userId = ref.watch(authProvider.select((s) => s.user?.id));
  return RecentTripNotifier(userId)..load();
});

/// Full cached detail of a trip, feeding a card's map band (TripMapBand).
/// Cache-first and cache-ONLY: a miss (MRU eviction, fresh device) yields
/// null and the host card renders its plain row — list surfaces never fetch,
/// they only decorate what other screens load. The band therefore shows the
/// trip *as of the last time this device viewed its detail* (accepted
/// staleness: a collaborator's edit elsewhere appears on the next detail
/// open).
///
/// Watches the WHOLE [recentTripProvider] state on purpose: [record] mints a
/// fresh [RecentTrip] instance on every successful detail load, so this
/// re-reads the just-rewritten cache after each detail view (edit → back
/// shows the new route). [TripCache.readTrip] drains queued writes first, so
/// that read-after-write is safe. Watching [tripCacheProvider] (auth-keyed)
/// re-resolves to null on sign-out.
final cachedTripDetailProvider =
    FutureProvider.family<Trip?, String>((ref, tripId) async {
  ref.watch(recentTripProvider);
  final cached = await ref.watch(tripCacheProvider).readTrip(tripId);
  return cached?.trip;
});

/// What Home's "Continue where you left off" card renders: enough to draw the
/// tile, nothing more. A record, so equal contents compare equal and the
/// derivation below can recompute freely without rebuilding the card.
typedef ContinueTrip = ({String tripId, String title, String? dateRange});

/// The trip Home offers as a way back in, or null when there is nothing to
/// continue.
///
/// [recorded] is the *preferred* answer — it is the only thing that knows
/// which trip this traveler actually looked at. But on web it lives in
/// origin-scoped storage, so it is absent on a new device, after a storage
/// clear, and after a domain move (the anemos.travel cutover emptied it for
/// every existing session). The trips list is the durable backstop: the
/// server already knows which trip was touched last, so a signed-in traveler
/// with saved trips is never left with nothing to continue.
///
/// Precedence, most specific first:
///  1. [recorded] found in [trips] — that trip, carrying the **live** title
///     and dates rather than the stored snapshot, so a rename made anywhere
///     else can't surface stale text here.
///  2. [recorded] not found — the snapshot verbatim. Absence is deliberately
///     NOT read as "the trip was deleted": [trips] is the OWNED list, so a
///     trip shared with this traveler is never in it, and the list is also
///     empty before its first load and stale offline. A card pointing at a
///     trip deleted on another device is the accepted cost of not dropping
///     those three.
///  3. No record at all — the most recently updated trip that hasn't already
///     happened, newest [Trip.createdAt] breaking an exact tie.
///  4. Nothing left — null. An all-past account gets an honest empty state;
///     the section can still fill with resumable chats.
///
/// [liveTrip] is excluded at every rung: it already has its own card directly
/// above this one, and the same trip must never stack twice.
ContinueTrip? continueTripOf(
  RecentTrip? recorded,
  List<Trip> trips,
  Trip? liveTrip,
  DateTime today,
) {
  ContinueTrip of(Trip t) => (
        tripId: t.id,
        title: t.title,
        dateRange: tripDateRange(t.startDate, t.endDate),
      );

  if (recorded != null && recorded.tripId != liveTrip?.id) {
    for (final t in trips) {
      if (t.id == recorded.tripId) return of(t);
    }
    return (
      tripId: recorded.tripId,
      title: recorded.title,
      dateRange: recorded.dateRange,
    );
  }

  Trip? best;
  for (final t in trips) {
    if (t.id == liveTrip?.id) continue;
    if (tripIsPast(t.startDate, t.endDate, today)) continue;
    // updatedAt/createdAt are required ISO-8601 strings off the wire, so
    // lexicographic order is chronological order — the convention
    // trip_list_order.dart already sorts by.
    if (best == null ||
        t.updatedAt.compareTo(best.updatedAt) > 0 ||
        (t.updatedAt == best.updatedAt &&
            t.createdAt.compareTo(best.createdAt) > 0)) {
      best = t;
    }
  }
  return best == null ? null : of(best);
}

/// The trip Home's "Continue where you left off" card points at. Derived in
/// this one place from device memory + the loaded trips list — see
/// [continueTripOf] for the precedence.
///
/// Watches the WHOLE [recentTripProvider] state rather than a select, for the
/// same reason [cachedTripDetailProvider] does: [RecentTripNotifier.record]
/// mints a fresh [RecentTrip] (no `==`) on every detail load, and that new
/// instance *is* the signal that the last-viewed trip changed.
///
/// Returns a record, so the recompute that every trips refresh triggers only
/// rebuilds Home when the answer actually changed — the narrow-watch doctrine
/// the home screen documents at the top of its build.
final continueTripProvider = Provider<ContinueTrip?>((ref) {
  final recorded = ref.watch(recentTripProvider);
  final trips = ref.watch(tripsProvider.select((s) => s.trips));
  final liveTrip = ref.watch(liveTripProvider);
  // Sampled at build time, exactly like liveTripProvider: a trip that ages
  // into "past" at midnight drops out on the next list refresh, not
  // spontaneously.
  return continueTripOf(recorded, trips, liveTrip, DateTime.now());
});
