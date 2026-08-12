import 'dart:convert';
import '../models/booking_todo.dart';
import 'api_client.dart';

class BookingTodosApiService {
  final ApiClient apiClient;

  BookingTodosApiService(this.apiClient);

  List<BookingTodo> _parseList(String body) {
    final list = jsonDecode(body) as List<dynamic>;
    return list
        .map((e) => BookingTodo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Upserts the itinerary-derived auto-TODOs and returns the full list. The
  /// server preserves booked state for surviving keys and prunes stale ones.
  Future<List<BookingTodo>> syncTodos(
      String tripId, List<Map<String, dynamic>> derived) async {
    final res = await apiClient.httpClient.put(
      Uri.parse('${apiClient.baseUrl}/trips/$tripId/booking-todos'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode(derived),
    );
    if (res.statusCode == 200) return _parseList(res.body);
    throw Exception('Failed to sync booking todos (${res.statusCode})');
  }

  Future<BookingTodo> addTodo(String tripId, Map<String, dynamic> body) async {
    final res = await apiClient.httpClient.post(
      Uri.parse('${apiClient.baseUrl}/trips/$tripId/booking-todos'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode(body),
    );
    if (res.statusCode == 201) {
      return BookingTodo.fromJson(jsonDecode(res.body));
    }
    throw Exception('Failed to add booking todo (${res.statusCode})');
  }

  Future<BookingTodo> setBooked(
      String tripId, String todoId, bool booked) async {
    final res = await apiClient.httpClient.patch(
      Uri.parse('${apiClient.baseUrl}/trips/$tripId/booking-todos/$todoId'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode({'booked': booked}),
    );
    if (res.statusCode == 200) {
      return BookingTodo.fromJson(jsonDecode(res.body));
    }
    throw Exception('Failed to update booking todo (${res.statusCode})');
  }

  /// Sets the per-leg transport-mode override on a transport todo (auto rows
  /// included). Origin/destination/depart_date/passengers are never persisted —
  /// the server uses them to rebuild the row's provider + search link for the
  /// new mode.
  Future<BookingTodo> setMode(
    String tripId,
    String todoId, {
    required String mode,
    required String origin,
    required String destination,
    String? departDate,
    int passengers = 1,
  }) async {
    final res = await apiClient.httpClient.patch(
      Uri.parse('${apiClient.baseUrl}/trips/$tripId/booking-todos/$todoId'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode({
        'mode': mode,
        'origin': origin,
        'destination': destination,
        if (departDate != null) 'depart_date': departDate,
        'passengers': passengers,
      }),
    );
    if (res.statusCode == 200) {
      return BookingTodo.fromJson(jsonDecode(res.body));
    }
    throw Exception('Failed to update booking todo (${res.statusCode})');
  }

  /// Partial content update of a custom (non-auto) todo. Same body shape as
  /// [addTodo]; a destination with no explicit search_url makes the server
  /// rebuild the search link.
  Future<BookingTodo> update(
      String tripId, String todoId, Map<String, dynamic> body) async {
    final res = await apiClient.httpClient.patch(
      Uri.parse('${apiClient.baseUrl}/trips/$tripId/booking-todos/$todoId'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode(body),
    );
    if (res.statusCode == 200) {
      return BookingTodo.fromJson(jsonDecode(res.body));
    }
    throw Exception('Failed to update booking todo (${res.statusCode})');
  }

  /// Persists the user's drag order for the Bookings section's residual
  /// "Other" list.
  /// Sends only that subset; the server renumbers those rows 0..n-1.
  Future<void> reorderTodos(String tripId, List<String> todoIds) async {
    final res = await apiClient.httpClient.put(
      Uri.parse('${apiClient.baseUrl}/trips/$tripId/booking-todos/order'),
      headers: apiClient.jsonHeaders(json: true),
      body: jsonEncode({'todo_ids': todoIds}),
    );
    if (res.statusCode != 204) {
      throw Exception('Failed to reorder booking todos (${res.statusCode})');
    }
  }

  Future<void> delete(String tripId, String todoId) async {
    final res = await apiClient.httpClient.delete(
      Uri.parse('${apiClient.baseUrl}/trips/$tripId/booking-todos/$todoId'),
      headers: apiClient.jsonHeaders(),
    );
    if (res.statusCode != 204) {
      throw Exception('Failed to delete booking todo (${res.statusCode})');
    }
  }
}
