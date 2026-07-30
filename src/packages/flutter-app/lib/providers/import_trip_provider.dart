import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/import_trip_result.dart';
import '../services/trips_api_service.dart';
import 'trips_provider.dart';

/// State for the paste-an-AI-chat import flow (specs/import-trip-from-ai-chat).
/// One in-flight import at a time; [error] carries the server's localized
/// message when one was provided (empty string means "show the generic copy").
class ImportTripState {
  final bool importing;
  final ImportTripResult? result;
  final String? error;

  const ImportTripState({this.importing = false, this.result, this.error});
}

class ImportTripNotifier extends StateNotifier<ImportTripState> {
  final Ref _ref;

  ImportTripNotifier(this._ref) : super(const ImportTripState());

  /// Runs the import and returns the result, or null on failure (state.error
  /// is set). The trips list is reloaded before returning so the new trip is
  /// already there when the user lands back on it.
  Future<ImportTripResult?> import(String text, {String? source}) async {
    if (state.importing) return null;
    state = const ImportTripState(importing: true);
    try {
      final res = await _ref
          .read(tripsApiServiceProvider)
          .importTrip(text, source: source);
      await _ref.read(tripsProvider.notifier).loadTrips();
      state = ImportTripState(result: res);
      return res;
    } on ImportTripException catch (e) {
      // Only 422 (no trip found / trip cap) and 429 (daily import cap) carry
      // server messages written for end users, localized via the API's tr()
      // catalog. Everything else (5xx, config errors like a missing provider
      // key) is operator-facing English — show the generic copy instead.
      final userFacing = e.statusCode == 422 || e.statusCode == 429;
      state = ImportTripState(error: userFacing ? e.message : '');
      return null;
    } catch (_) {
      state = const ImportTripState(error: '');
      return null;
    }
  }

  void reset() => state = const ImportTripState();
}

final importTripProvider =
    StateNotifierProvider.autoDispose<ImportTripNotifier, ImportTripState>(
  (ref) => ImportTripNotifier(ref),
);
