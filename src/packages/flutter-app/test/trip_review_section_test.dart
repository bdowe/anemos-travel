import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip_finding.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trip_review_api_service.dart';
import 'package:travel_route_planner/providers/trip_review_provider.dart';
import 'package:travel_route_planner/widgets/trip_review_section.dart';
import 'package:travel_route_planner/widgets/collapsible_section.dart';
import 'package:travel_route_planner/widgets/empty_state.dart';

import 'support/l10n_test_app.dart';

/// A fake that returns a fixed list and records the checkHours values it was
/// asked for, so tests can assert the opt-in extra check re-fetches.
class _FakeTripReviewApiService extends TripReviewApiService {
  final List<TripFinding> findings;
  final List<bool> checkHoursCalls = [];

  _FakeTripReviewApiService(this.findings)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<TripFinding>> getReview(String tripId,
      {bool checkHours = false}) async {
    checkHoursCalls.add(checkHours);
    return List.of(findings);
  }
}

TripFinding _f(String severity, String category, String message,
        {int? day, String? itemId, FindingFix? fix}) =>
    TripFinding(
      severity: severity,
      category: category,
      message: message,
      tripId: 't1',
      day: day,
      itemId: itemId,
      fix: fix,
    );

Future<_FakeTripReviewApiService> _pump(
  WidgetTester tester,
  List<TripFinding> findings, {
  bool isOffline = false,
  void Function(int day)? onScrollToDay,
  int? Function(String itemId)? dayForItem,
  Future<void> Function(TripFinding finding)? onApplyFix,
}) async {
  final fake = _FakeTripReviewApiService(findings);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tripReviewApiServiceProvider.overrideWithValue(fake),
      ],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,
        home: Scaffold(
          body: SingleChildScrollView(
            child: TripReviewSection(
              tripId: 't1',
              isOffline: () => isOffline,
              onScrollToDay: onScrollToDay,
              dayForItem: dayForItem,
              onApplyFix: onApplyFix,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

void main() {
  testWidgets(
      'partitions findings: attention visible worst-first, suggestions collapsed',
      (tester) async {
    await _pump(tester, [
      _f('info', 'packing', 'Consider a rain jacket'),
      _f('critical', 'dates', 'Trip has no dates set'),
      _f('warn', 'lodging', 'No lodging on day 2'),
    ]);

    expect(find.text('Trip health'), findsOneWidget);
    // The count pill frames the attention tier, not the total.
    expect(find.text('Mostly ready — 2 to fix'), findsOneWidget);
    // Attention severity chips render; the info row starts collapsed.
    expect(find.text('Critical'), findsOneWidget);
    expect(find.text('Warning'), findsOneWidget);
    expect(find.text('Info'), findsNothing);
    expect(find.text('Consider a rain jacket'), findsNothing);

    // Worst-first within attention; the Suggestions header sits below.
    final header = tester.getTopLeft(find.text('Needs attention')).dy;
    final critical = tester.getTopLeft(find.text('Trip has no dates set')).dy;
    final warn = tester.getTopLeft(find.text('No lodging on day 2')).dy;
    final suggestions = tester.getTopLeft(find.text('Suggestions')).dy;
    expect(header, lessThan(critical));
    expect(critical, lessThan(warn));
    expect(warn, lessThan(suggestions));

    // One tap opens the suggestions tier.
    await tester.tap(find.text('Suggestions'));
    await tester.pumpAndSettle();
    expect(find.text('Info'), findsOneWidget);
    expect(find.text('Consider a rain jacket'), findsOneWidget);
  });

  testWidgets('info-only: calm framing, count pill, and re-collapse',
      (tester) async {
    await _pump(tester, [
      _f('info', 'weather', 'Pack an umbrella'),
      _f('info', 'bookings', 'Stay not booked yet'),
    ]);

    expect(find.text('In good shape — 2 suggestions'), findsOneWidget);
    expect(find.text('Needs attention'), findsNothing);
    expect(
        find.descendant(
            of: find.byType(CollapsibleSection), matching: find.text('2')),
        findsOneWidget);

    await tester.tap(find.text('Suggestions'));
    await tester.pumpAndSettle();
    expect(find.text('Pack an umbrella'), findsOneWidget);

    await tester.tap(find.text('Suggestions'));
    await tester.pumpAndSettle();
    expect(find.text('Pack an umbrella'), findsNothing);
  });

  testWidgets('empty findings shows the positive "Looks good" empty state',
      (tester) async {
    await _pump(tester, []);

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('Looks good'), findsOneWidget);
    expect(find.textContaining('to fix'), findsNothing);
    expect(find.text('Suggestions'), findsNothing);
  });

  testWidgets('tapping a finding with a day invokes the scroll callback',
      (tester) async {
    int? scrolledTo;
    await _pump(
      tester,
      [_f('warn', 'unscheduled', 'Nothing planned on day 3', day: 3)],
      onScrollToDay: (day) => scrolledTo = day,
    );

    await tester.tap(find.text('Nothing planned on day 3'));
    await tester.pumpAndSettle();

    expect(scrolledTo, 3);
  });

  testWidgets('tapping an item-only finding resolves its day via dayForItem',
      (tester) async {
    int? scrolledTo;
    await _pump(
      tester,
      [_f('warn', 'transit', 'Long gap before this stop', itemId: 'item-x')],
      onScrollToDay: (day) => scrolledTo = day,
      dayForItem: (id) => id == 'item-x' ? 5 : null,
    );

    await tester.tap(find.text('Long gap before this stop'));
    await tester.pumpAndSettle();

    expect(scrolledTo, 5);
  });

  testWidgets('a finding with no anchor does not crash on tap', (tester) async {
    var scrollCount = 0;
    await _pump(
      tester,
      [_f('info', 'budget', 'Budget looks tight')],
      onScrollToDay: (_) => scrollCount++,
    );

    // Info rows live behind the collapsed Suggestions tier.
    await tester.tap(find.text('Suggestions'));
    await tester.pumpAndSettle();

    // Not tappable (no day/item) — the message renders and nothing scrolls.
    await tester.tap(find.text('Budget looks tight'));
    await tester.pumpAndSettle();
    expect(scrollCount, 0);
  });

  testWidgets('check-hours button triggers a checkHours=true refetch',
      (tester) async {
    final fake = await _pump(tester, [_f('info', 'packing', 'Bring sunscreen')]);

    // Initial load is hours-off.
    expect(fake.checkHoursCalls, contains(false));
    expect(fake.checkHoursCalls, isNot(contains(true)));

    await tester.tap(find.text('Also check opening hours'));
    await tester.pumpAndSettle();

    // Flipping the flag re-fetches with checkHours=true.
    expect(fake.checkHoursCalls, contains(true));
  });

  testWidgets('a finding with a fix renders a button with the fix label',
      (tester) async {
    await _pump(
      tester,
      [
        _f('warn', 'lodging', 'No lodging in Naxos',
            fix: const FindingFix(action: 'add_lodging', label: 'Add a stay')),
      ],
      onApplyFix: (_) async {},
    );

    expect(find.widgetWithText(FilledButton, 'Add a stay'), findsOneWidget);
    // The fix took the trailing slot from the chevron.
    expect(find.byIcon(Icons.chevron_right), findsNothing);
  });

  testWidgets('every fix action renders its labelled button', (tester) async {
    await _pump(
      tester,
      [
        _f('warn', 'lodging', 'a',
            fix: const FindingFix(action: 'add_lodging', label: 'Add a stay')),
        _f('warn', 'transit', 'b',
            fix: const FindingFix(
                action: 'add_transport', label: 'Add transport')),
        _f('warn', 'unscheduled', 'c',
            fix: const FindingFix(action: 'move_item', label: 'Move to Day 2')),
        _f('warn', 'bookings', 'd',
            fix: const FindingFix(action: 'mark_booked', label: 'Mark booked')),
        _f('info', 'packing', 'e',
            fix: const FindingFix(action: 'add_packing', label: 'Add to list')),
        _f('critical', 'dates', 'f',
            fix: const FindingFix(action: 'set_dates', label: 'Set dates')),
        _f('info', 'budget', 'g',
            fix:
                const FindingFix(action: 'raise_budget', label: 'Raise budget')),
      ],
      onApplyFix: (_) async {},
    );

    // The info-severity fixes sit behind the collapsed Suggestions tier.
    await tester.tap(find.text('Suggestions'));
    await tester.pumpAndSettle();

    for (final label in const [
      'Add a stay',
      'Add transport',
      'Move to Day 2',
      'Mark booked',
      'Add to list',
      'Set dates',
      'Raise budget',
    ]) {
      expect(find.widgetWithText(FilledButton, label), findsOneWidget);
    }
  });

  testWidgets('tapping the fix button calls onApplyFix, not the row scroll',
      (tester) async {
    TripFinding? applied;
    var scrollCount = 0;
    // Finding carries a day, so the row is also tap-to-scroll — the button must
    // win the gesture and never scroll.
    await _pump(
      tester,
      [
        _f('warn', 'unscheduled', 'Nothing on day 2', day: 2,
            fix: const FindingFix(
                action: 'move_item', label: 'Move here', targetDay: 2)),
      ],
      onScrollToDay: (_) => scrollCount++,
      onApplyFix: (f) async => applied = f,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Move here'));
    await tester.pumpAndSettle();

    expect(applied, isNotNull);
    expect(applied!.fix!.action, 'move_item');
    expect(scrollCount, 0);
  });

  testWidgets('no fix button when onApplyFix is null', (tester) async {
    await _pump(
      tester,
      [
        _f('warn', 'lodging', 'No lodging',
            fix: const FindingFix(action: 'add_lodging', label: 'Add a stay')),
      ],
      // onApplyFix omitted (null) — the button is hidden.
    );

    expect(find.widgetWithText(FilledButton, 'Add a stay'), findsNothing);
  });

  testWidgets('offline disables the check-hours action', (tester) async {
    final fake = await _pump(
      tester,
      [_f('info', 'packing', 'Bring sunscreen')],
      isOffline: true,
    );

    await tester.tap(find.text('Also check opening hours'));
    await tester.pumpAndSettle();

    // Button is disabled offline — no extra fetch.
    expect(fake.checkHoursCalls, isNot(contains(true)));
  });
}
