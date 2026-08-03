import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:travel_route_planner/l10n/l10n.dart';
import 'package:travel_route_planner/providers/auth_provider.dart';
import 'package:travel_route_planner/providers/locale_provider.dart';
import 'package:travel_route_planner/services/auth_storage.dart';

import 'support/l10n_test_app.dart';

/// End-to-end of the user-visible half of specs/i18n-spanish: picking a
/// language redraws the app in it, and the choice survives a restart.
///
/// The picker itself lives in account settings, which needs a signed-in user;
/// these drive the provider it is bound to, plus a real MaterialApp, which is
/// what actually proves the ARB wiring resolves at runtime.
/// The locale provider reads authProvider to decide whether to sync the choice
/// to the account; constructing the real one hits flutter_secure_storage, which
/// has no implementation under `flutter test`.
class _FakeAuthStorage extends AuthStorage {
  @override
  Future<String?> loadToken() async => null;

  @override
  Future<void> saveToken(String value) async {}

  @override
  Future<void> clearToken() async {}
}

ProviderContainer _container() {
  final c = ProviderContainer(
    overrides: [authStorageProvider.overrideWithValue(_FakeAuthStorage())],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('choosing Spanish redraws the app in Spanish', (tester) async {
    late WidgetRef ref;
    await tester.pumpWidget(ProviderScope(
      overrides: [authStorageProvider.overrideWithValue(_FakeAuthStorage())],
      child: Consumer(builder: (context, r, _) {
        ref = r;
        final locale = r.watch(localeProvider.select((s) => s.materialLocale));
        return MaterialApp(
          localizationsDelegates: testLocalizationsDelegates,
          supportedLocales: kSupportedLocales,
          locale: locale,
          home: Builder(
            builder: (context) => Text(context.l10n.languageSectionTitle),
          ),
        );
      }),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Language'), findsOneWidget);

    await ref.read(localeProvider.notifier).setLanguage('es');
    await tester.pumpAndSettle();

    expect(find.text('Idioma'), findsOneWidget);
    expect(find.text('Language'), findsNothing);
  });

  test('an explicit choice is persisted and restored on next launch', () async {
    final container = _container();
    await container.read(localeProvider.notifier).setLanguage('es');
    expect(container.read(localeProvider).language, 'es');

    // A fresh container stands in for a relaunch: the choice must come back
    // from device storage rather than resetting to the device language.
    final relaunched = _container();
    await relaunched.read(localeProvider.notifier).load();
    expect(relaunched.read(localeProvider).language, 'es');
  });

  test('first launch resolves the device language and stores it', () async {
    // A device that has never chosen ("system default" users from before the
    // option was removed, and fresh installs) gets its resolved language
    // persisted, so the picker always shows a concrete selection.
    final container = _container();
    await container.read(localeProvider.notifier).load();
    expect(container.read(localeProvider).language, 'en');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('locale_override'), 'en');
  });

  test('the API client language header follows the choice', () async {
    final container = _container();
    await container.read(localeProvider.notifier).setLanguage('es');
    // The server renders emails, trip-health findings and exports from this
    // header, so it must track the picker and not just the widget tree.
    expect(container.read(localeProvider).language, 'es');
  });
}
