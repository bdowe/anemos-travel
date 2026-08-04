import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:travel_route_planner/services/plan_service.dart';

/// streamPlan hands its abortTrigger to an AbortableRequest so the transport
/// dies the moment the trigger fires — even mid-tool-call with an idle socket
/// — and the resulting RequestAbortedException ends the stream cleanly with
/// no synthetic error event.
///
/// MockClient does not honor abortTrigger, so this fake transport implements
/// the contract by hand: stream one SSE frame, then inject the abort error
/// when the trigger completes (what BrowserClient/IOClient do for real).
class _AbortAwareClient extends http.BaseClient {
  Future<void>? seenTrigger;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    seenTrigger = (request as http.AbortableRequest).abortTrigger;
    final controller = StreamController<List<int>>();
    controller.add(
        utf8.encode('data: {"type":"text_delta","data":{"text":"one"}}\n\n'));
    if (seenTrigger == null) {
      // No trigger: behave like a normal completed response.
      unawaited(controller.close());
    } else {
      seenTrigger!.whenComplete(() {
        controller.addError(http.RequestAbortedException(request.url));
        controller.close();
      });
    }
    return http.StreamedResponse(controller.stream, 200);
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  const history = [
    {'role': 'user', 'content': 'plan athens'}
  ];

  test('abort mid-stream ends cleanly: pre-abort events only, no error event',
      () async {
    final client = _AbortAwareClient();
    final service =
        PlanService('http://test/api/v1', clientFactory: () => client);
    final abort = Completer<void>();

    final eventsFuture =
        service.streamPlan(history, abortTrigger: abort.future).toList();
    await Future<void>.delayed(const Duration(milliseconds: 5));

    // The trigger reached the transport as this request's abortTrigger.
    expect(identical(client.seenTrigger, abort.future), isTrue);

    abort.complete();
    final events = await eventsFuture;

    expect(events.map((e) => e.type).toList(), ['text_delta']);
    expect(events.single.data['text'], 'one');
    expect(client.closed, isTrue);
  });

  test('no abortTrigger: the stream parses and completes unchanged', () async {
    final client = _AbortAwareClient();
    final service =
        PlanService('http://test/api/v1', clientFactory: () => client);

    final events = await service.streamPlan(history).toList();

    expect(client.seenTrigger, isNull);
    expect(events.map((e) => e.type).toList(), ['text_delta']);
    expect(client.closed, isTrue);
  });
}
