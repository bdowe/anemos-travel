import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/traveler_preferences.dart';
import '../services/preferences_api_service.dart';
import 'api_client_provider.dart';

final preferencesApiServiceProvider = Provider<PreferencesApiService>((ref) {
  return PreferencesApiService(ref.watch(apiClientProvider));
});

class PreferencesState {
  final TravelerPreferences? prefs;
  final bool loading;
  final bool saving;
  final String? error;

  const PreferencesState({this.prefs, this.loading = false, this.saving = false, this.error});

  PreferencesState copyWith({
    TravelerPreferences? prefs,
    bool? loading,
    bool? saving,
    Object? error = _sentinel,
  }) {
    return PreferencesState(
      prefs: prefs ?? this.prefs,
      loading: loading ?? this.loading,
      saving: saving ?? this.saving,
      error: error == _sentinel ? this.error : error as String?,
    );
  }
}

const _sentinel = Object();

class PreferencesNotifier extends StateNotifier<PreferencesState> {
  final PreferencesApiService _service;

  PreferencesNotifier(this._service) : super(const PreferencesState());

  Future<void> load() async {
    state = state.copyWith(loading: true, error: null);
    try {
      final prefs = await _service.getPreferences();
      state = state.copyWith(prefs: prefs, loading: false);
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  /// Loads preferences only when they aren't already in state. Preferences
  /// change in-session solely through [save] (profile sheet / onboarding),
  /// which updates state here, so a loaded copy never goes stale — this
  /// method is the one place that decides whether a network load is needed.
  /// A previous failed load (prefs still null) retries, matching [load].
  Future<void> loadIfNeeded() async {
    if (state.prefs != null) return;
    await load();
  }

  Future<bool> save({
    String? budget,
    String? pace,
    required List<String> interests,
    String? homeAirport,
    String? profileNotes,
    String? workStyle,
    String? fitnessRoutine,
    String? outdoorIntensity,
    String? companions,
  }) async {
    state = state.copyWith(saving: true, error: null);
    try {
      final prefs = await _service.savePreferences(
          budget: budget,
          pace: pace,
          interests: interests,
          homeAirport: homeAirport,
          profileNotes: profileNotes,
          workStyle: workStyle,
          fitnessRoutine: fitnessRoutine,
          outdoorIntensity: outdoorIntensity,
          companions: companions);
      state = state.copyWith(prefs: prefs, saving: false);
      return true;
    } catch (e) {
      state = state.copyWith(saving: false, error: e.toString());
      return false;
    }
  }
}

final preferencesProvider =
    StateNotifierProvider<PreferencesNotifier, PreferencesState>((ref) {
  return PreferencesNotifier(ref.watch(preferencesApiServiceProvider));
});
