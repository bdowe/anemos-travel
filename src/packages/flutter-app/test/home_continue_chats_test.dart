import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/chat_session.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/screens/home_screen.dart';
import 'package:travel_route_planner/widgets/continue_chats_section.dart';

import 'support/l10n_test_app.dart';

/// Home-screen slotting of the "Continue where you left off" section
/// (specs/continue-where-you-left-off): in-progress plan chats surface on
/// Home too, and the section collapses to nothing when there are none.
class _FakeAuthNotifier extends StateNotifier<AuthState>
    implements AuthNotifier {
  _FakeAuthNotifier(UserModel? user)
      : super(AuthState(user: user, initialized: true));

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

UserModel _user() => UserModel(
      id: 'user-1',
      email: 'test@example.com',
      displayName: 'Brian',
      createdAt: DateTime(2026, 1, 1),
    );

ChatSessionSummary _chat(String id, String title) => ChatSessionSummary(
      chatId: id,
      title: title,
      preview: 'Thinking about a week of island hopping.',
      messageCount: 4,
      createdAt: '2026-07-01T10:00:00Z',
      updatedAt: '2026-07-02T10:00:00Z',
    );

Future<void> _pumpHome(
  WidgetTester tester, {
  List<ChatSessionSummary> chats = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
        liveTripProvider.overrideWithValue(null),
        resumableChatsProvider.overrideWith((ref) async => chats),
      ],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,home: HomeScreen()),
    ),
  );
  // Extra pumps flush the SharedPreferences read behind recentTripProvider
  // and the resumable-chats future.
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('in-progress chats surface on home', (WidgetTester tester) async {
    await _pumpHome(tester, chats: [_chat('c1', 'Greek islands in September')]);

    expect(find.text('Continue where you left off'), findsOneWidget);
    expect(find.byType(ContinueChatCard), findsOneWidget);
    expect(find.text('Greek islands in September'), findsOneWidget);
  });

  testWidgets('section collapses when there is nothing to resume',
      (WidgetTester tester) async {
    await _pumpHome(tester);

    expect(find.text('Continue where you left off'), findsNothing);
    expect(find.byType(ContinueChatCard), findsNothing);
  });
}
