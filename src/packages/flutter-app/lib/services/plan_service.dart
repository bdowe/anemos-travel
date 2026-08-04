import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

class PlanEvent {
  final String type;
  final Map<String, dynamic> data;

  const PlanEvent({required this.type, required this.data});
}

class PlanService {
  final String baseUrl;

  /// Builds the HTTP client used for one streaming request. Injectable so
  /// tests can substitute a fake transport; defaults to a fresh client per
  /// stream (closed when the stream ends).
  final http.Client Function() _newClient;

  PlanService(this.baseUrl, {http.Client Function()? clientFactory})
      : _newClient = clientFactory ?? http.Client.new;

  Stream<PlanEvent> streamPlan(
    List<Map<String, dynamic>> messages, {
    String? bearerToken,
    String? chatId,
    String? tripId,
    String? summary,
    Future<void>? abortTrigger,
  }) async* {
    // AbortableRequest tears down the transport the moment [abortTrigger]
    // completes — even while the socket is idle mid-tool-call. Cancelling the
    // consumer's subscription alone would only take effect at the next SSE
    // frame, leaving the server generating for a dead client.
    final request = http.AbortableRequest('POST', Uri.parse('$baseUrl/plan'),
        abortTrigger: abortTrigger);
    request.headers['Content-Type'] = 'application/json';
    if (bearerToken != null) {
      request.headers['Authorization'] = 'Bearer $bearerToken';
    }
    request.body = jsonEncode({
      'messages': messages,
      if (chatId != null) 'chat_id': chatId,
      if (tripId != null) 'trip_id': tripId,
      if (summary != null && summary.isNotEmpty) 'summary': summary,
    });

    final client = _newClient();
    try {
      final response = await client.send(request);

      // A non-200 is a middleware/gateway rejection (e.g. the request-body
      // 413, or an nginx 502) whose body carries no SSE frames at all —
      // without this check the stream would end silently: no reply, no error
      // banner, no retry. Convert it into the same synthetic `error` event
      // the server uses for in-handler failures, so the provider's existing
      // error path (banner + retryLastSend) engages.
      if (response.statusCode != 200) {
        var message = 'Request failed (HTTP ${response.statusCode})';
        try {
          final body = await response.stream.bytesToString();
          final decoded = jsonDecode(body);
          if (decoded is Map<String, dynamic>) {
            // writeJSONError uses {"message": ...}; tolerate {"error": ...}.
            final msg = decoded['message'] ?? decoded['error'];
            if (msg is String && msg.isNotEmpty) message = msg;
          }
        } catch (_) {
          // Non-JSON body (gateway HTML error page): keep the generic text.
        }
        yield PlanEvent(type: 'error', data: {'message': message});
        return;
      }

      final buffer = StringBuffer();
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        buffer.write(chunk);
        final raw = buffer.toString();
        final parts = raw.split('\n\n');
        buffer.clear();
        buffer.write(parts.last);

        for (final part in parts.sublist(0, parts.length - 1)) {
          for (final line in part.split('\n')) {
            if (line.startsWith('data: ')) {
              final decoded =
                  jsonDecode(line.substring(6)) as Map<String, dynamic>;
              yield PlanEvent(
                type: decoded['type'] as String,
                data: (decoded['data'] as Map<String, dynamic>?) ?? {},
              );
            }
          }
        }
      }
    } on http.RequestAbortedException {
      // Deliberate teardown (stop button, reset, dispose) — end the stream
      // with no synthetic error event; the provider superseded this turn
      // before firing the trigger, so nothing downstream is listening.
      return;
    } finally {
      client.close();
    }
  }
}
