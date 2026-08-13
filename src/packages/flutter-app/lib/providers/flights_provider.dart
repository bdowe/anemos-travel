import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/airport.dart';
import '../models/flight_offer.dart';
import '../models/flight_search_request.dart';
import '../services/api_client.dart';
import '../services/flights_api_service.dart';
import 'api_client_provider.dart';

final flightsApiServiceProvider = Provider<FlightsApiService>((ref) {
  return FlightsApiService(ref.watch(apiClientProvider));
});

/// Airport/city autocomplete for origin & destination fields.
final airportSearchProvider =
    FutureProvider.family<List<Airport>, String>((ref, query) async {
  if (query.trim().length < 2) return [];
  final service = ref.watch(flightsApiServiceProvider);
  return service.searchAirports(query.trim());
});

/// Resolves a saved home-airport IATA code to map coordinates (a record, not
/// LatLng, so the providers layer stays free of map imports).
///
/// `null` means CONFIRMED empty — the lookup succeeded and found no
/// coordinates for the code — and is correctly cached for the session.
/// Transport/HTTP failures surface as AsyncError instead (the map renders
/// them identically via `valueOrNull`), and transient ones arm a one-shot
/// 30s `invalidateSelf` so the overlay self-heals while watched. Without
/// that, this non-autoDispose family would pin one bad boot-time request —
/// and an empty home overlay — for the whole session; autoDispose alone
/// can't help because the map watches continuously, so a cached error is
/// never released.
final homeAirportPointProvider =
    FutureProvider.family<({double lat, double lng})?, String>(
        (ref, iata) async {
  final code = iata.trim().toUpperCase();
  if (code.isEmpty) return null;
  final List<Airport> results;
  try {
    results = await ref.watch(flightsApiServiceProvider).searchAirports(code);
  } catch (e) {
    if (isTransientError(e)) {
      final retry = Timer(const Duration(seconds: 30), ref.invalidateSelf);
      ref.onDispose(retry.cancel);
    }
    rethrow;
  }
  Airport? match;
  for (final a in results) {
    if (a.iataCode.toUpperCase() != code) continue;
    if (a.latitude == null || a.longitude == null) continue;
    if (a.subType == 'airport') {
      match = a;
      break;
    }
    match ??= a; // city-type fallback when it happens to carry coords
  }
  return match == null ? null : (lat: match.latitude!, lng: match.longitude!);
});

class FlightsState {
  final List<FlightOffer> offers;
  final String? bestOfferId;
  final String optimizeFor;
  final bool loading;
  // Holds the raw caught error (an ApiException, usually) so the UI can render
  // it via friendlyError(l10n, ...); providers have no BuildContext/l10n.
  final Object? error;
  final bool hasSearched;

  const FlightsState({
    this.offers = const [],
    this.bestOfferId,
    this.optimizeFor = 'balanced',
    this.loading = false,
    this.error,
    this.hasSearched = false,
  });

  FlightsState copyWith({
    List<FlightOffer>? offers,
    Object? bestOfferId = _sentinel,
    String? optimizeFor,
    bool? loading,
    Object? error = _sentinel,
    bool? hasSearched,
  }) {
    return FlightsState(
      offers: offers ?? this.offers,
      bestOfferId:
          bestOfferId == _sentinel ? this.bestOfferId : bestOfferId as String?,
      optimizeFor: optimizeFor ?? this.optimizeFor,
      loading: loading ?? this.loading,
      error: error == _sentinel ? this.error : error,
      hasSearched: hasSearched ?? this.hasSearched,
    );
  }
}

const _sentinel = Object();

class FlightsNotifier extends StateNotifier<FlightsState> {
  final FlightsApiService _service;

  FlightsNotifier(this._service) : super(const FlightsState());

  Future<void> search(FlightSearchRequest request) async {
    state = state.copyWith(
      loading: true,
      error: null,
      optimizeFor: request.optimizeFor,
      hasSearched: true,
    );
    try {
      final res = await _service.searchFlights(request);
      state = state.copyWith(
        offers: res.offers,
        bestOfferId: res.bestOfferId,
        optimizeFor: res.optimizeFor,
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e);
    }
  }

  void reset() {
    state = const FlightsState();
  }
}

final flightsProvider =
    StateNotifierProvider<FlightsNotifier, FlightsState>((ref) {
  return FlightsNotifier(ref.watch(flightsApiServiceProvider));
});
