import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/trip.dart';

/// A cached payload plus the moment it was saved, so the UI can say how
/// stale the copy is ("saved 2 hours ago").
typedef CachedTrips = ({List<Trip> trips, DateTime savedAt});
typedef CachedTrip = ({Trip trip, DateTime savedAt});

/// On-device, per-user cache of previously fetched trips so they stay
/// viewable (read-only) without a network. Backed by shared_preferences —
/// the same storage and user-scoped keying as `recent_trip_provider.dart` —
/// which is acceptable for v1 payload sizes (see specs/offline-trips).
///
/// Writes are best-effort: every write swallows storage errors so a cache
/// problem can never affect the online path. Reads treat any malformed entry
/// as a miss.
class TripCache {
  /// Signed-in user the cache belongs to; null when anonymous, in which case
  /// every operation no-ops (trips require sign-in anyway).
  final String? userId;

  TripCache(this.userId);

  /// Most-recently-viewed trip details kept per user; older ones are evicted.
  static const int maxCachedTrips = 10;

  static String _prefix(String userId) => 'trip_cache.$userId.';

  String get _listKey => '${_prefix(userId!)}list';
  String get _indexKey => '${_prefix(userId!)}index';
  String _tripKey(String tripId) => '${_prefix(userId!)}trip.$tripId';

  /// True when [e] is a network-level failure (no connection, timeout) as
  /// opposed to an HTTP error response. `package:http` >=1.0 wraps socket/IO
  /// failures in [http.ClientException] on every platform; the string check
  /// is belt-and-braces for raw dart:io SocketExceptions (dart:io itself is
  /// not importable on web). HTTP non-200s in TripsApiService are thrown as
  /// plain `Exception('... (status)')` and therefore never match — a
  /// 403/404/500 must NOT fall back to the cache.
  static bool isNetworkError(Object e) =>
      e is http.ClientException ||
      e is TimeoutException ||
      e.toString().contains('SocketException');

  // ---- Deferred, coalesced writes -----------------------------------------
  //
  // On web shared_preferences is SYNCHRONOUS localStorage, and a cache write
  // jsonEncodes a full trip (items/accommodations/segments/todos/legs) — work
  // that used to run on the UI isolate at the exact moment a screen builds.
  // Writes are therefore queued per prefs key and drained by one deferred
  // event-loop task (see [_queueWrite]): N rapid writes to the same key
  // collapse to the last value, and the encode runs after the triggering
  // frame's event has yielded, not during build. Callers were already
  // fire-and-forget (`unawaited`), so the returned future now completing at
  // "queued" rather than "stored" changes no caller-visible semantics.
  //
  // Read-after-write choice: reads DRAIN the whole pending queue first (not
  // "peek this key's pending slot"), because a queued [writeTrip] also
  // mutates the shared MRU index — and [removeTrip] the cached list row — so
  // replaying a single key out of order could evict or order wrongly. The
  // queue is a LinkedHashMap drained FIFO, with a re-written key moved to the
  // tail, which is exactly MRU order. In-app the read paths (offline
  // fallback) never race writes in practice; the drain makes the guarantee
  // explicit instead of conventional.

  /// Pending write bodies by prefs key, in execution order. A re-queued key
  /// moves to the tail so the MRU index sees writes in last-write order.
  static final Map<String, Future<void> Function()> _pendingWrites =
      <String, Future<void> Function()>{};

  /// Whether an idle-time drain is already requested.
  static bool _drainScheduled = false;

  static void _queueWrite(String key, Future<void> Function() write) {
    _pendingWrites.remove(key); // Coalesce: last value wins, moves to tail.
    _pendingWrites[key] = write;
    if (_drainScheduled) return;
    _drainScheduled = true;
    // A plain event-loop task, NOT SchedulerBinding.scheduleTask: the encode
    // runs on the next event-loop turn, after the current frame's event has
    // yielded — which is all the deferral the UI needs. scheduleTask's
    // priority gate re-arms its internal zero-duration timer until the
    // scheduler goes idle, and fake-async test pumps can spin on that
    // re-arm loop forever (this hung CI).
    Timer.run(() {
      _drainScheduled = false;
      _flushPendingWrites();
    });
  }

  /// Executes every queued write in order. Entry failures are swallowed
  /// (best-effort — a failed cache write must never surface).
  ///
  /// Deliberately NOT serialized through a shared chained Future: widget
  /// tests run inside fake-async zones, and a static Future chained across
  /// zones deadlocks the next test that awaits it (a queued write left
  /// unpumped when a test ends can never complete, and `testWidgets` has no
  /// timeout — the whole suite wedges). The queue itself is the
  /// synchronization point instead: an entry is removed only AFTER its write
  /// lands, so a flush cannot observe "empty" while the tail write is still
  /// in flight (read-after-write holds), and each closure is a last-value
  /// snapshot, so two racing drains executing the same entry write identical
  /// bytes — harmless.
  static Future<void> _flushPendingWrites() async {
    while (_pendingWrites.isNotEmpty) {
      final key = _pendingWrites.keys.first;
      final write = _pendingWrites[key]!;
      try {
        await write();
      } catch (_) {
        // Best-effort — a failed cache write must never surface.
      }
      // Drop the entry unless it was re-queued with a newer value while the
      // write was in flight — the newer closure must still run.
      if (identical(_pendingWrites[key], write)) {
        _pendingWrites.remove(key);
      }
    }
  }

  /// Remembers the trips list. Deferred to an idle-time task and coalesced
  /// (see the deferred-writes note above). Fire-and-forget: never throws.
  Future<void> writeList(List<Trip> trips) async {
    if (userId == null) return;
    final key = _listKey;
    _queueWrite(key, () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        key,
        jsonEncode({
          'saved_at': DateTime.now().toIso8601String(),
          'trips': [for (final t in trips) t.toJson()],
        }),
      );
    });
  }

  /// The last successfully fetched trips list, or null on miss/corruption.
  Future<CachedTrips?> readList() async {
    if (userId == null) return null;
    await _flushPendingWrites(); // Reads must see just-queued writes.
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_listKey);
      if (raw == null) return null;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final savedAt = DateTime.parse(m['saved_at'] as String);
      final trips = [
        for (final e in m['trips'] as List<dynamic>)
          Trip.fromJson(e as Map<String, dynamic>)
      ];
      return (trips: trips, savedAt: savedAt);
    } catch (_) {
      return null; // Malformed entry — treat as a miss.
    }
  }

  /// Remembers one trip's full detail and bumps it to the front of the MRU
  /// index, evicting beyond [maxCachedTrips]. Deferred to an idle-time task
  /// and coalesced per trip (see the deferred-writes note above).
  /// Fire-and-forget: never throws.
  Future<void> writeTrip(Trip trip) async {
    if (userId == null) return;
    final key = _tripKey(trip.id);
    _queueWrite(key, () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        key,
        jsonEncode({
          'saved_at': DateTime.now().toIso8601String(),
          'trip': trip.toJson(),
        }),
      );
      final index = _readIndex(prefs)..remove(trip.id);
      index.insert(0, trip.id);
      for (final evicted in index.skip(maxCachedTrips)) {
        await prefs.remove(_tripKey(evicted));
      }
      await prefs.setStringList(
          _indexKey, index.take(maxCachedTrips).toList());
    });
  }

  /// The last successfully fetched detail for [tripId], or null.
  Future<CachedTrip?> readTrip(String tripId) async {
    if (userId == null) return null;
    await _flushPendingWrites(); // Reads must see just-queued writes.
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_tripKey(tripId));
      if (raw == null) return null;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return (
        trip: Trip.fromJson(m['trip'] as Map<String, dynamic>),
        savedAt: DateTime.parse(m['saved_at'] as String),
      );
    } catch (_) {
      return null; // Malformed entry — treat as a miss.
    }
  }

  /// Forgets a deleted trip so offline mode can't reopen it: drops its
  /// detail entry, its index slot, and its row in the cached list.
  Future<void> removeTrip(String tripId) async {
    if (userId == null) return;
    // Land any queued write for this trip first, then remove — otherwise a
    // deferred write could resurrect the trip after this delete.
    await _flushPendingWrites();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_tripKey(tripId));
      final index = _readIndex(prefs)..remove(tripId);
      await prefs.setStringList(_indexKey, index);
      final raw = prefs.getString(_listKey);
      if (raw != null) {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        final trips = (m['trips'] as List<dynamic>)
            .where((e) => (e as Map<String, dynamic>)['id'] != tripId)
            .toList();
        await prefs.setString(
            _listKey, jsonEncode({'saved_at': m['saved_at'], 'trips': trips}));
      }
    } catch (_) {
      // Best-effort.
    }
  }

  List<String> _readIndex(SharedPreferences prefs) =>
      prefs.getStringList(_indexKey)?.toList() ?? <String>[];

  /// Removes every cached entry belonging to [userId]. Called on sign-out
  /// and account deletion (privacy: shared devices).
  static Future<void> clearForUser(String userId) async {
    final prefix = _prefix(userId);
    // Drop this user's queued writes first — a deferred write landing after
    // the clear would resurrect their data (privacy: shared devices) — then
    // flush the rest so an already-in-flight write (still in the map until it
    // lands) settles before the storage sweep below.
    _pendingWrites.removeWhere((key, _) => key.startsWith(prefix));
    await _flushPendingWrites();
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys().toList()) {
        if (key.startsWith(prefix)) await prefs.remove(key);
      }
    } catch (_) {
      // Best-effort.
    }
  }
}
