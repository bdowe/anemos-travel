import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/models/trip.dart';
import 'package:travel_route_planner/models/user.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/live_trip_provider.dart';
import 'package:travel_route_planner/providers/resumable_chats_provider.dart';
import 'package:travel_route_planner/screens/home_screen.dart';
import 'package:travel_route_planner/theme/app_theme.dart';
import 'package:travel_route_planner/theme/app_typography.dart';

import 'support/l10n_test_app.dart';

/// The editorial recast's style guards (home redesign): the greeting is the
/// page's one display moment (the display face at w500/39 via the theme role,
/// i.e. headlineMedium), and the
/// de-tealed plan strip can never silently regress to a gradient band or
/// grow its icon plate back. Scoped finders on purpose — the live hero and
/// the photo hero legitimately keep their gradients.
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

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

Trip _liveTrip() => Trip(
      id: 't1',
      title: 'Athens Trip',
      startDate: _iso(DateTime.now().subtract(const Duration(days: 1))),
      endDate: _iso(DateTime.now().add(const Duration(days: 1))),
      createdAt: '2026-06-01',
      updatedAt: '2026-06-01',
    );

Future<void> _pumpHome(WidgetTester tester,
    {Trip? liveTrip, ThemeData? theme}) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _FakeAuthNotifier(_user())),
        liveTripProvider.overrideWithValue(liveTrip),
        resumableChatsProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(
          theme: theme ?? AppTheme.light,
          localizationsDelegates: testLocalizationsDelegates,
          home: const HomeScreen()),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Any painted gradient or circle-plate decoration under [root].
Finder _gradientOrPlate(Finder root) => find.descendant(
      of: root,
      matching: find.byWidgetPredicate((w) {
        if (w is! DecoratedBox) return false;
        final d = w.decoration;
        return d is BoxDecoration &&
            (d.gradient != null || d.shape == BoxShape.circle);
      }),
    );

void main() {
  testWidgets('greeting renders in the display face at the headline tier',
      (WidgetTester tester) async {
    await _pumpHome(tester, liveTrip: _liveTrip());

    final greeting =
        tester.widget<Text>(find.textContaining(', Brian').first);
    expect(greeting.style?.fontFamily, AppFonts.display);
    // The literal values of headlineMedium, pinned rather than read back off
    // the theme — reading the theme here would assert nothing. w500 is the
    // One Weight Rule's display weight; 35 is the optical correction the
    // ladder took when the face followed the wordmark to Cormorant Garamond.
    expect(greeting.style?.fontWeight, FontWeight.w500);
    expect(greeting.style?.fontSize, 39);
  });

  testWidgets('plan strip carries no gradient band and no icon plate',
      (WidgetTester tester) async {
    await _pumpHome(tester, liveTrip: _liveTrip());

    final strip = find
        .ancestor(
            of: find.text('Plan less. Travel more.'),
            matching: find.byType(Card))
        .first;
    expect(_gradientOrPlate(strip), findsNothing);
    // The bare icon itself stays — it is the plate that died.
    expect(
        find.descendant(
            of: strip, matching: find.byIcon(Icons.flight_takeoff)),
        findsOneWidget);
  });

  testWidgets('dark theme renders the recast strip without exceptions',
      (WidgetTester tester) async {
    await _pumpHome(tester, liveTrip: _liveTrip(), theme: AppTheme.dark);

    expect(find.text('Plan less. Travel more.'), findsOneWidget);
    expect(find.textContaining(', Brian'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new-user photo hero: display headline, no icon plate',
      (WidgetTester tester) async {
    // No live trip, no prefs, no chats — the returning flag is false and the
    // photo hero branch renders.
    await _pumpHome(tester);

    final headline =
        tester.widget<Text>(find.text('Plan less. Travel more.'));
    expect(headline.style?.fontFamily, AppFonts.display);
    // headlineLarge's literals — see the greeting test above for why these are
    // spelled out rather than read from the theme.
    expect(headline.style?.fontWeight, FontWeight.w500);
    expect(headline.style?.fontSize, 44);

    // The hero's flight icon floats bare on the scrim — the circle plate
    // died in the editorial pass.
    final hero = find
        .ancestor(
            of: find.text('Plan less. Travel more.'),
            matching: find.byType(ClipRRect))
        .first;
    expect(
        find.descendant(
            of: hero, matching: find.byIcon(Icons.flight_takeoff)),
        findsOneWidget);
    expect(
      find.descendant(
        of: hero,
        matching: find.byWidgetPredicate((w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).shape == BoxShape.circle),
      ),
      findsNothing,
    );
  });
}
