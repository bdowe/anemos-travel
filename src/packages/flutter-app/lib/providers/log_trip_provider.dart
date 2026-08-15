import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/trip.dart';
import '../services/trips_api_service.dart';
import 'trips_provider.dart';

/// State for the "Log a past trip" form (specs/log-past-trip). One in-flight
/// save at a time; [error] carries the server's message when it wrote one for
/// end users (the trip-cap 422), and an empty string means "show the generic
/// copy" — the same convention [ImportTripState] uses.
class LogTripState {
  final bool saving;
  final String? error;

  const LogTripState({this.saving = false, this.error});
}

class LogTripNotifier extends StateNotifier<LogTripState> {
  final Ref _ref;

  LogTripNotifier(this._ref) : super(const LogTripState());

  /// Saves the trip and returns it, or null on failure (state.error is set).
  /// The trips list is reloaded before returning so the new trip — and the
  /// "Your travels" totals it feeds — are already current when the user lands
  /// back on My Trips.
  Future<Trip?> save({
    required List<Map<String, dynamic>> destinations,
    required String startDate,
    required String endDate,
    String? title,
  }) async {
    if (state.saving) return null;
    state = const LogTripState(saving: true);
    try {
      final trip = await _ref.read(tripsApiServiceProvider).createTrip(
            destinations: destinations,
            startDate: startDate,
            endDate: endDate,
            title: title,
          );
      await _ref.read(tripsProvider.notifier).loadTrips();
      state = const LogTripState();
      return trip;
    } on CreateTripException catch (e) {
      // Only the 422 (trip cap) message is written for people. A 400 means the
      // client sent a body its own gating should have blocked, and a 5xx is
      // operator-facing — both get the generic copy.
      state = LogTripState(error: e.statusCode == 422 ? e.message : '');
      return null;
    } catch (_) {
      state = const LogTripState(error: '');
      return null;
    }
  }
}

final logTripProvider =
    StateNotifierProvider.autoDispose<LogTripNotifier, LogTripState>(
  (ref) => LogTripNotifier(ref),
);
