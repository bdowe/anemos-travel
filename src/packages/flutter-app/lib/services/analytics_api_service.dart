import 'dart:convert';
import 'api_client.dart';

/// First-party analytics: records the client-observed funnel moments (the
/// landing page rendering, opening a booking link, adding a browsed place to
/// a trip). Strictly fire-and-forget —
/// failures are swallowed, tracking must never slow down or break the
/// experience.
class AnalyticsApiService {
  final ApiClient apiClient;

  AnalyticsApiService(this.apiClient);

  /// Events the API accepts without authentication (mirrors the server's
  /// anonymousClientEventTypes whitelist). Anything else is silently dropped
  /// when there is no session token.
  static const Set<String> _anonymousEventTypes = {
    'landing_viewed',
    'booking_link_clicked',
  };

  /// Records a place added to a trip from a browse surface
  /// (specs/add-to-itinerary). [source] is one of the server's closed set:
  /// 'local_rec', 'event', 'guide_pin', or 'chat_place'. Authed-only: _record
  /// drops it for anonymous sessions since it isn't on the anonymous whitelist.
  Future<void> recordItineraryItemAdded({
    required String tripId,
    required String source,
  }) {
    return _record(
      'itinerary_item_added',
      tripId: tripId,
      metadata: {'source': source},
    );
  }

  /// The attach-rate numerator: a booking handoff link was opened. Sent
  /// anonymously when signed out (the server drops trip_id for anonymous
  /// events — ownership can't be verified).
  Future<void> recordBookingLinkClicked({
    String? tripId,
    String? todoKey,
    String? provider,
    String? surface,
    String? kind,
  }) {
    return _record(
      'booking_link_clicked',
      tripId: tripId,
      metadata: {
        if (todoKey != null) 'todo_key': todoKey,
        if (provider != null) 'provider': provider,
        if (surface != null) 'surface': surface,
        if (kind != null) 'kind': kind,
      },
    );
  }

  /// Top of the funnel: a signed-out visitor rendered the landing page.
  /// Call sites guard this to once per app session.
  Future<void> recordLandingViewed() => _record('landing_viewed');

  Future<void> _record(
    String eventType, {
    String? tripId,
    Map<String, String>? metadata,
  }) async {
    final token = apiClient.authToken;
    if (token == null && !_anonymousEventTypes.contains(eventType)) {
      return; // this event is untracked for anonymous sessions
    }
    try {
      await apiClient.httpClient.post(
        Uri.parse('${apiClient.baseUrl}/events'),
        headers: {
          'Content-Type': 'application/json',
          if (token != null) 'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'event_type': eventType,
          if (tripId != null) 'trip_id': tripId,
          if (metadata != null && metadata.isNotEmpty) 'metadata': metadata,
        }),
      );
    } catch (_) {
      // Silently dropped by design.
    }
  }
}
