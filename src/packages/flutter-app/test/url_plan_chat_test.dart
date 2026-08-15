import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/main.dart';
import 'package:travel_route_planner/models/chat_session.dart';
import 'package:travel_route_planner/models/plan_message.dart';
import 'package:travel_route_planner/navigation/app_nav.dart';
import 'package:travel_route_planner/navigation/url_sync.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/providers/trips_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/chats_api_service.dart';

import 'support/url_sync_fakes.dart';

/// /plan/<chatId> (specs/url-page-persistence): the Plan tab's URL carries
/// the conversation id once one exists, and booting on it rehydrates the
/// transcript — with a silent fresh-chat fallback when there is nothing to
/// restore (foreign or expired ids).
///
/// A trip's own conversation can never be named here: since
/// specs/trip-refine-memory it lives in its own table keyed by (traveler,
/// trip) and has no chat id at all, so this URL has nothing to point at and
/// the refine panel stays deliberately absent from the address bar.
class _FakeChatsApiService extends ChatsApiService {
  final ChatSessionDetail? detail;

  _FakeChatsApiService(this.detail) : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<ChatSessionDetail> getChat(String chatId) async {
    final d = detail;
    if (d == null || d.chatId != chatId) {
      throw Exception('no stored transcript (404)');
    }
    return d;
  }
}

ChatSessionDetail _detail(String chatId) => ChatSessionDetail(
      chatId: chatId,
      title: 'Greek islands',
      summary: '',
      messages: const [
        ChatSessionMessage(role: 'user', content: 'Plan me an island hop'),
        ChatSessionMessage(role: 'assistant', content: 'Naxos then Paros.'),
      ],
      updatedAt: '2026-07-02T10:00:00Z',
    );

void main() {
  late List<String> reports;

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    required String initialUrl,
    ChatSessionDetail? storedChat,
  }) async {
    tester.binding.platformDispatcher.defaultRouteNameTestValue = initialUrl;
    reports = <String>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => FakeAuthNotifier(fakeUser())),
          tripsApiServiceProvider
              .overrideWithValue(FakeTripsApiService(fakeTrip('t1'))),
          chatsApiServiceProvider
              .overrideWithValue(_FakeChatsApiService(storedChat)),
          liveTripProvider.overrideWithValue(null),
          resumableChatsProvider.overrideWith((ref) async => const []),
          urlReporterProvider.overrideWithValue(reports.add),
        ],
        child: const TravelRoutePlannerApp(),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
        tester.element(find.byType(TravelRoutePlannerApp)));
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('booting /plan/<chatId> rehydrates the conversation',
      (tester) async {
    final container = await pumpApp(tester,
        initialUrl: '/plan/c1', storedChat: _detail('c1'));

    expect(container.read(navIndexProvider), AppTab.plan.index);
    final plan = container.read(planProvider);
    expect(plan.chatId, 'c1');
    expect(plan.messages, hasLength(2));
    expect(plan.messages.first.role, MessageRole.user);
    expect(reports.last, '/plan/c1');
  });

  testWidgets('a chat with no stored transcript degrades to a fresh Plan tab',
      (tester) async {
    final container =
        await pumpApp(tester, initialUrl: '/plan/gone', storedChat: null);

    expect(container.read(navIndexProvider), AppTab.plan.index);
    final plan = container.read(planProvider);
    expect(plan.chatId, isNull);
    expect(plan.messages, isEmpty);
    expect(reports.last, '/plan');
    expect(tester.takeException(), isNull);
  });

  testWidgets('resume and Start over move the Plan tab URL', (tester) async {
    final container = await pumpApp(tester, initialUrl: '/');

    final notifier = container.read(planProvider.notifier);
    notifier.resumeConversation(chatId: 'c9', messages: const [
      PlanMessage(role: MessageRole.user, content: 'hello'),
    ]);
    container.read(navIndexProvider.notifier).state = AppTab.plan.index;
    await tester.pumpAndSettle();
    expect(reports.last, '/plan/c9');

    notifier.reset();
    await tester.pumpAndSettle();
    expect(reports.last, '/plan');
  });
}
