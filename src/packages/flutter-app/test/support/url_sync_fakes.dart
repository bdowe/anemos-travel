import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/trips_api_service.dart';

/// Shared fakes for the URL-persistence tests (specs/url-page-persistence):
/// they pump the real [TravelRoutePlannerApp], so the session and the trips
/// backend both need deterministic stand-ins.

/// Auth notifier whose state is fully script-controlled: starts resolved
/// (signed in when [user] is non-null), and flips via [signIn]/[signOut] so
/// tests can drive the auth transitions URL sync listens for.
class FakeAuthNotifier extends StateNotifier<AuthState>
    implements AuthNotifier {
  FakeAuthNotifier(UserModel? user)
      : super(AuthState(user: user, initialized: true));

  void signIn(UserModel user) => state = state.copyWith(user: user);

  void signOut() => state = state.copyWith(clearUser: true);

  @override
  void clearError() => state = state.copyWith(clearError: true);

  @override
  Future<bool> login(String email, String password) async => false;

  @override
  Future<bool> register(String email, String password,
          {String? displayName}) async =>
      false;

  @override
  Future<void> completeOnboarding() async {}

  @override
  Future<void> logout() async {}

  @override
  Future<void> signOutLocally() async {}

  @override
  void setUser(UserModel user) {}

  @override
  Future<void> adoptSession(String token, UserModel user) async {}
}

class FakeTripsApiService extends TripsApiService {
  final Trip trip;

  FakeTripsApiService(this.trip) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<Trip> getTrip(String id) async => trip;

  @override
  Future<List<Trip>> listTrips() async => [trip];

  @override
  Future<List<Trip>> listSharedWithMe() async => const [];
}

UserModel fakeUser() => UserModel(
      id: 'user-1',
      email: 'test@example.com',
      displayName: 'Brian',
      createdAt: DateTime(2026, 1, 1),
    );

Trip fakeTrip(String id) => Trip(
      id: id,
      title: 'Lisbon long weekend',
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
      items: const [],
    );
