import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/trip_finding.dart';
import 'package:travel_route_planner/widgets/before_you_go_section.dart';

/// "Before you go" orders the trip's open items the way the trip is actually
/// travelled — the same walk the next-step ladder's phase 3 makes — not by
/// severity, and not by category.
TripFinding lodging(String city, String checkIn, {String sev = 'warn'}) =>
    TripFinding(
      severity: sev,
      category: 'lodging',
      message: 'No lodging in $city',
      tripId: 't1',
      fix: FindingFix(
        action: 'add_lodging',
        label: 'Find a stay',
        city: city,
        checkIn: checkIn,
        checkOut: checkIn,
      ),
    );

TripFinding transit(String from, String to, String date) => TripFinding(
      severity: 'warn',
      category: 'transit',
      message: 'No transport from $from to $to',
      tripId: 't1',
      fix: FindingFix(
        action: 'add_transport',
        label: 'Find flights',
        origin: from,
        destination: to,
        date: date,
      ),
    );

TripFinding chore(String category, String message, {String sev = 'info'}) =>
    TripFinding(
      severity: sev,
      category: category,
      message: message,
      tripId: 't1',
    );

void main() {
  test('walks the trip in order: stay, then the leg out, then the next stay',
      () {
    // Deliberately shuffled on the way in — the server groups findings by
    // check, so they never arrive in itinerary order.
    final ordered = BeforeYouGoSection.openItems([
      transit('Copenhagen', 'Berlin', '2026-09-08'),
      lodging('Copenhagen', '2026-09-03'),
      lodging('Kraków', '2026-08-29'),
      transit('Kraków', 'Copenhagen', '2026-09-03'),
    ]);

    expect(ordered.map((f) => f.message).toList(), [
      'No lodging in Kraków',
      'No transport from Kraków to Copenhagen',
      'No lodging in Copenhagen',
      'No transport from Copenhagen to Berlin',
    ]);
  });

  test('you travel before you sleep there, on a shared date', () {
    final ordered = BeforeYouGoSection.openItems([
      lodging('Copenhagen', '2026-09-03'),
      transit('Kraków', 'Copenhagen', '2026-09-03'),
    ]);

    expect(ordered.first.category, 'transit');
    expect(ordered.last.category, 'lodging');
  });

  test('undated chores fall to the tail, in severity order', () {
    final ordered = BeforeYouGoSection.openItems([
      chore('budget', 'Budget looks thin', sev: 'info'),
      chore('packing', 'Nothing packed', sev: 'warn'),
      lodging('Kraków', '2026-08-29'),
    ]);

    expect(ordered.map((f) => f.category).toList(),
        ['lodging', 'packing', 'budget']);
  });

  test('the promoted step drops ONE row, not its whole category', () {
    // The regression this test exists for: filtering by category deleted every
    // lodging gap the moment the ladder reached lodging, so the section
    // listed nothing but transport.
    final ordered = BeforeYouGoSection.openItems(
      [
        lodging('Kraków', '2026-08-29'),
        transit('Kraków', 'Copenhagen', '2026-09-03'),
        lodging('Copenhagen', '2026-09-03'),
      ],
      promoted: NextStep(
        kind: 'add_lodging',
        title: 'Book your stay in Kraków',
        fix: FindingFix(
          action: 'add_lodging',
          label: 'Find a stay',
          city: 'Kraków',
          checkIn: '2026-08-29',
        ),
      ),
    );

    // Kraków's stay is the one in the band above; Copenhagen's survives.
    expect(ordered.map((f) => f.message).toList(), [
      'No transport from Kraków to Copenhagen',
      'No lodging in Copenhagen',
    ]);
  });

  test('a promoted step matching nothing removes nothing', () {
    final rows = [lodging('Kraków', '2026-08-29')];
    final ordered = BeforeYouGoSection.openItems(
      rows,
      promoted: NextStep(
        kind: 'add_lodging',
        title: 'Book your stay in Rome',
        fix: FindingFix(
          action: 'add_lodging',
          label: 'Find a stay',
          city: 'Rome',
          checkIn: '2026-09-20',
        ),
      ),
    );

    expect(ordered, hasLength(1));
  });

  test('a step with no fix (a chat-seeded rung) filters nothing', () {
    final ordered = BeforeYouGoSection.openItems(
      [lodging('Kraków', '2026-08-29')],
      promoted: const NextStep(kind: 'plan_itinerary', title: 'Plan your days'),
    );

    expect(ordered, hasLength(1));
  });
}
