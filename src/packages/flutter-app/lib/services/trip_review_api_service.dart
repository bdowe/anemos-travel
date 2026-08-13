import 'dart:convert';
import '../models/trip_finding.dart';
import 'api_client.dart';

/// Wraps the per-trip health review endpoint (`GET /trips/{id}/review`).
/// Read-only; mirrors [ChecklistApiService] conventions. The optional
/// [checkHours] flag opts into the slower opening-hours check (real Google
/// lookups land in a later PR — a harmless no-op until then).
class TripReviewApiService {
  final ApiClient apiClient;

  TripReviewApiService(this.apiClient);

  /// Boot-critical (the health app-bar icon watches this): [ApiClient.send]
  /// gives it a timeout + bounded retry; HTTP failures — including the
  /// viewer's stable 404 — throw a typed [ApiException]. Returns the whole
  /// payload — findings plus the Next Step projection (specs/next-step-cta).
  Future<TripReview> getReview(String tripId, {bool checkHours = false}) async {
    final res = await apiClient.send('GET', '/trips/$tripId/review',
        query: {'check_hours': '$checkHours'});
    return TripReview.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }
}
