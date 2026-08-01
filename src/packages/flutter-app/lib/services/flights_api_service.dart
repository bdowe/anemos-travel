import 'dart:convert';
import '../models/airport.dart';
import '../models/flight_search_request.dart';
import '../models/flight_search_response.dart';
import 'api_client.dart';

/// Wraps the /flights/* endpoints (Duffel-backed flight search + airport
/// autocomplete). These endpoints are public, but we still send the bearer
/// token when present, matching the other services.
class FlightsApiService {
  final ApiClient apiClient;

  FlightsApiService(this.apiClient);

  Future<FlightSearchResponse> searchFlights(FlightSearchRequest request) async {
    final res = await apiClient.httpClient.post(
      Uri.parse('${apiClient.baseUrl}/flights/search'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode(request.toJson()),
    );
    if (res.statusCode == 200) {
      return FlightSearchResponse.fromJson(
          jsonDecode(res.body) as Map<String, dynamic>);
    }
    throw ApiException(
      statusCode: res.statusCode,
      message: 'Failed to search flights: ${res.body}',
      endpoint: 'flights/search',
    );
  }

  Future<List<Airport>> searchAirports(String query) =>
      _airports({'q': query});

  /// Resolves a coordinate to nearby airports/cities, sorted nearest-first. Used
  /// to map an itinerary place (e.g. a village) to a bookable airport when its
  /// name has no IATA match.
  Future<List<Airport>> nearestAirports(double lat, double lng) =>
      _airports({'lat': '$lat', 'lng': '$lng'});

  Future<List<Airport>> _airports(Map<String, String> params) async {
    final uri = Uri.parse('${apiClient.baseUrl}/flights/airports')
        .replace(queryParameters: params);
    final res = await apiClient.httpClient.get(uri, headers: apiClient.jsonHeaders());
    if (res.statusCode == 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (body['results'] as List<dynamic>? ?? []);
      return list
          .map((e) => Airport.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    throw ApiException(
      statusCode: res.statusCode,
      message: 'Failed to search airports: ${res.body}',
      endpoint: 'flights/airports',
    );
  }
}
