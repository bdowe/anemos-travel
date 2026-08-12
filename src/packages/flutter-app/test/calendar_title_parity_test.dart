import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/l10n/l10n.dart';

/// Calendar event titles are a CROSS-LANGUAGE CONTRACT.
///
/// The traveler chooses between a Google Calendar link built by the Flutter
/// client and an `.ics` file built by the Go API — for the same event. If the
/// two disagree, the same trip shows up under two different names depending on
/// which button was pressed.
///
/// These expectations are duplicated in the Go suite
/// (api/calendar_event_test.go). Pinning both sides to the same literals means
/// a drift on either side fails a test rather than shipping silently.
void main() {
  Future<AppLocalizations> load(String code) =>
      AppLocalizations.delegate.load(Locale(code));

  test('stay titles match the Go .ics export (ics.stayTitle)', () async {
    final en = await load('en');
    final es = await load('es');
    expect(en.calendarStayTitle('Hotel Grande Bretagne'),
        'Stay: Hotel Grande Bretagne');
    expect(es.calendarStayTitle('Hotel Grande Bretagne'),
        'Alojamiento: Hotel Grande Bretagne');
  });

  test('segment titles match the Go .ics export (ics.segmentTitle)', () async {
    final en = await load('en');
    final es = await load('es');
    expect(en.calendarSegmentTitle('Flight', 'JFK → ATH'), 'Flight: JFK → ATH');
    expect(es.calendarSegmentTitle('Vuelo', 'JFK → ATH'), 'Vuelo: JFK → ATH');
  });

  test('mode labels match the Go .ics export (ics.mode.*)', () async {
    final en = await load('en');
    final es = await load('es');
    expect(
      [
        en.calendarModeFlight,
        en.calendarModeTrain,
        en.calendarModeBus,
        en.calendarModeCar,
        en.calendarModeFerry,
        en.calendarModeOther,
      ],
      ['Flight', 'Train', 'Bus', 'Car', 'Ferry', 'Other'],
    );
    expect(
      [
        es.calendarModeFlight,
        es.calendarModeTrain,
        es.calendarModeBus,
        es.calendarModeCar,
        es.calendarModeFerry,
        es.calendarModeOther,
      ],
      ['Vuelo', 'Tren', 'Autobús', 'Coche', 'Ferri', 'Otro'],
    );
  });

  // The app had shipped both "ferri" (lowercase, inline) and "Ferry"
  // (capitalized, standalone) as the Spanish for the same mode. They should be
  // the same word in either casing. (The trip-pill label set is gone — mode is
  // per-leg now — leaving these two sets.)
  test('the Spanish ferry term is consistent across mode label sets', () async {
    final es = await load('es');
    expect(es.bookingsModeFerry.toLowerCase(), 'ferri');
    expect(es.calendarModeFerry.toLowerCase(), 'ferri');
  });
}
