// Which of a city's live events the trip-detail rail shows, and in what order.
//
// Pure like trip_legs.dart / leg_ranges.dart: no widget/l10n imports, so the
// selection is unit-testable without pumping a screen. ONE definition — the
// rail is the only caller; the "see all" sheet deliberately shows the
// unfiltered list (docs/zen.md: one obvious way to do it).

import '../models/event.dart';

/// How many event cards the trip-detail rail shows. Matches the chat strip's
/// per-rail cap (`_ResultStrips._maxCards` in chat_panel.dart) so the two
/// event surfaces show the same number of cards.
const int kEventRailCards = 8;

/// How many events `/events/search` can return for one city window
/// (`maxEvents` in events_service.go). The server truncates silently and the
/// response carries no total, so a count rendered at exactly this many is
/// "30+", never "30" — pinned on both sides by tests.
const int kEventsServerCap = 30;

/// Up to [limit] of [events], spread across the days they fall on, returned in
/// chronological order.
///
/// Ticketmaster is sorted date-ascending, so a plain `take(N)` hands back N
/// events from whichever day comes first — a busy Tuesday can fill every slot
/// and a four-night stay shows nothing after day one. Bucket by
/// [Event.startDate] and hand out one slot per day before anyone's second, so
/// a short list still covers the whole stay.
///
/// The picks are re-sorted chronologically afterwards, so the rail reads
/// left-to-right in time regardless of the round-robin visit order. Selection
/// only ever reorders and truncates — it never filters, so nothing the server
/// returned can become unreachable through the rail's "see all".
List<Event> spreadEventsByDay(List<Event> events, {required int limit}) {
  if (limit <= 0 || events.isEmpty) return const <Event>[];

  // Bucket by local calendar date. [Event.startDate] is the server's already
  // window-filtered YYYY-MM-DD, so string equality IS date equality and
  // string order IS date order — no parsing, no timezone.
  final byDay = <String, List<int>>{};
  for (var i = 0; i < events.length; i++) {
    byDay.putIfAbsent(events[i].startDate, () => <int>[]).add(i);
  }

  final days = byDay.keys.toList()
    ..sort((a, b) => _daySortKey(a).compareTo(_daySortKey(b)));

  // Round-robin: everyone's first before anyone's second.
  final picked = <int>[];
  for (var round = 0; picked.length < limit; round++) {
    var tookAny = false;
    for (final day in days) {
      final onThatDay = byDay[day]!;
      if (round >= onThatDay.length) continue;
      picked.add(onThatDay[round]);
      tookAny = true;
      if (picked.length == limit) break;
    }
    // Every bucket is exhausted — fewer events than [limit].
    if (!tookAny) break;
  }

  picked.sort((a, b) {
    final byDate =
        _daySortKey(events[a].startDate).compareTo(_daySortKey(events[b].startDate));
    if (byDate != 0) return byDate;
    final byTime = events[a].startTime.compareTo(events[b].startTime);
    if (byTime != 0) return byTime;
    // Input order is the final tiebreak, so the result is fully deterministic.
    return a.compareTo(b);
  });
  return [for (final i in picked) events[i]];
}

/// Sort key for a `start_date`. A blank date can only come from a malformed
/// upstream row; `~` (0x7E) sorts after every ISO digit, so such a row lands
/// last instead of first. It is kept, not dropped — it costs its own slot and
/// never silently hides a good event.
String _daySortKey(String startDate) => startDate.isEmpty ? '~' : startDate;
