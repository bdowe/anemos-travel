import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/chat_session.dart';
import 'package:travel_route_planner/providers/plan_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/chats_api_service.dart';
import 'package:travel_route_planner/widgets/continue_chats_section.dart';

import 'support/l10n_test_app.dart';

/// Resuming from a continue card rebuilds PlanMessages with their persisted
/// display labels, so a near-me chat re-renders the seed context chip instead
/// of the raw coordinate bubble (specs/continue-where-you-left-off).
class _FakeChatsApiService extends ChatsApiService {
  final ChatSessionDetail detail;

  _FakeChatsApiService(this.detail) : super(ApiClient());

  @override
  Future<ChatSessionDetail> getChat(String chatId) async => detail;
}

void main() {
  testWidgets('resume restores display labels onto the plan conversation',
      (WidgetTester tester) async {
    const rawSeed = 'My current location is latitude 40.7234, longitude '
        '-73.9938 (accuracy about 12 m). What is good near me?';
    final detail = ChatSessionDetail(
      chatId: 'chat-near-me',
      title: 'Near my current location',
      summary: '',
      messages: const [
        ChatSessionMessage(
          role: 'user',
          content: rawSeed,
          displayLabel: 'Near my current location',
        ),
        ChatSessionMessage(role: 'assistant', content: 'You are in NoLita.'),
      ],
      updatedAt: '2026-08-02T10:00:00Z',
    );

    final container = ProviderContainer(overrides: [
      chatsApiServiceProvider.overrideWithValue(_FakeChatsApiService(detail)),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          home: Scaffold(
            body: ContinueChatCard(
              chat: const ChatSessionSummary(
                chatId: 'chat-near-me',
                title: 'Near my current location',
                preview: 'You are in NoLita.',
                messageCount: 2,
                createdAt: '2026-08-01T10:00:00Z',
                updatedAt: '2026-08-02T10:00:00Z',
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(ContinueChatCard));
    await tester.pumpAndSettle();

    final messages = container.read(planProvider).messages;
    expect(messages, hasLength(2));
    expect(messages.first.content, rawSeed);
    expect(messages.first.displayLabel, 'Near my current location');
    expect(messages.last.displayLabel, isNull);
  });
}
