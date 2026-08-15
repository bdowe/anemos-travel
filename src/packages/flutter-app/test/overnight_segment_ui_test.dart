import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/trip_segment.dart';
import 'package:travel_route_planner/providers/analytics_provider.dart';
import 'package:travel_route_planner/services/analytics_api_service.dart';
import 'package:travel_route_planner/widgets/booking_detail_row.dart';
import 'package:travel_route_planner/widgets/booking_sheets.dart';

import 'support/l10n_test_app.dart';

/// The two writers of the overnight fact, and the row that reads it back.
///
/// `trip_segments` has carried depart_date AND arrive_date since migration
/// 00007 — the only pair in the schema — and the calendar export, the print
/// packet and get_trip all already consume it. Nothing in the product could
/// WRITE it: the agent tool had no parameter and this sheet had no field.

class _NoopAnalytics implements AnalyticsApiService {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future.value();
}

Widget _host(Widget child) => ProviderScope(
      overrides: [
        analyticsApiServiceProvider.overrideWithValue(_NoopAnalytics()),
      ],
      child: MaterialApp(
        localizationsDelegates: testLocalizationsDelegates,
        home: Scaffold(body: child),
      ),
    );

void main() {
  group('BookingDetailRow', () {
    testWidgets('an overnight segment shows both of its days', (tester) async {
      await tester.pumpWidget(_host(const SingleChildScrollView(
        child: BookingDetailRow.segment(
          tripId: 't1',
          segment: TripSegment(
            id: 's1',
            mode: 'flight',
            origin: 'EWR',
            destination: 'Amsterdam',
            departDate: '2026-08-23',
            arriveDate: '2026-08-24',
          ),
        ),
      )));

      // The same line the derived checklist row above it prints — one screen
      // must never show a span on one row and a single date on the record
      // directly beneath it.
      expect(find.textContaining('Aug 23 → Aug 24'), findsOneWidget);
    });

    testWidgets('a same-day segment still shows one date', (tester) async {
      await tester.pumpWidget(_host(const SingleChildScrollView(
        child: BookingDetailRow.segment(
          tripId: 't1',
          segment: TripSegment(
            id: 's1',
            mode: 'train',
            origin: 'Amsterdam',
            destination: 'Rome',
            departDate: '2026-08-26',
            arriveDate: '2026-08-26',
          ),
        ),
      )));

      expect(find.textContaining('Aug 26'), findsOneWidget);
      expect(find.textContaining('→ Aug'), findsNothing);
    });
  });

  group('AddSegmentSheet', () {
    testWidgets('round-trips an existing arrival date through the edit path',
        (tester) async {
      // The sheet is also the EDIT path. Omitting the field would leave
      // UpdateSegment's COALESCE holding a stored arrival the traveler can no
      // longer see — while they move the departure past it.
      await tester.pumpWidget(_host(const AddSegmentSheet(
        initial: TripSegment(
          id: 's1',
          mode: 'flight',
          origin: 'EWR',
          destination: 'Amsterdam',
          departDate: '2026-08-23',
          arriveDate: '2026-08-24',
        ),
      )));
      await tester.pumpAndSettle();

      expect(find.text('2026-08-23'), findsOneWidget);
      expect(find.text('2026-08-24'), findsOneWidget);
    });

    testWidgets('offers an arrival picker on a fresh sheet', (tester) async {
      await tester.pumpWidget(_host(const AddSegmentSheet(
        initialOrigin: 'EWR',
        initialDestination: 'Amsterdam',
      )));
      await tester.pumpAndSettle();

      // Unset, it reads as the optional thing it is — only worth filling in
      // for a leg that lands the next day.
      expect(
          find.text('Arrival date (if it lands the next day)'), findsOneWidget);
    });

    testWidgets('a prefilled arrival appears without a prefilled departure',
        (tester) async {
      // The unknown-departure outbound leg: "Add details…" now opens with the
      // departure BLANK and the arrival filled, so the app never asks the
      // traveler to confirm a departure date it invented.
      await tester.pumpWidget(_host(const AddSegmentSheet(
        initialOrigin: 'EWR',
        initialDestination: 'Amsterdam',
        initialArriveDate: '2026-08-24',
      )));
      await tester.pumpAndSettle();

      expect(find.text('2026-08-24'), findsOneWidget);
      expect(find.text('Departure date'), findsOneWidget);
    });
  });
}
