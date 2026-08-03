import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

import 'package:travel_route_planner/l10n/l10n.dart';
import 'package:travel_route_planner/providers/locale_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/utils/money_format.dart';
import 'package:travel_route_planner/utils/trip_format.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('supported languages', () {
    // Spanish is now enabled (PR 7). Everything else must still be rejected:
    // resolving a locale the app has no translations for would send a language
    // header for text it cannot render.
    test('English and Spanish are supported, other languages are not', () {
      expect(isSupportedLanguage('en'), isTrue);
      expect(isSupportedLanguage('es'), isTrue);
      expect(isSupportedLanguage('fr'), isFalse);
      expect(isSupportedLanguage('pt'), isFalse);
    });
  });

  group('resolveEffectiveLocale', () {
    test('nothing stored follows the device, falling back to English', () {
      expect(resolveEffectiveLocale(null), 'en');
    });

    test('a stored choice this build cannot render is ignored', () {
      // A stale choice left by a build that shipped more languages — or the
      // retired "system" sentinel — must not pin the app to a language it has
      // no translations for.
      expect(resolveEffectiveLocale('klingon'), 'en');
      expect(resolveEffectiveLocale('fr'), 'en');
      expect(resolveEffectiveLocale('system'), 'en');
    });

    test('a stored supported language wins', () {
      expect(resolveEffectiveLocale('en'), 'en');
      expect(resolveEffectiveLocale('es'), 'es');
    });
  });

  group('LocaleState', () {
    test('the chosen language pins MaterialApp to that locale', () {
      // Always concrete: there is no "follow the system" mode, so MaterialApp
      // never gets a null locale to resolve itself.
      const state = LocaleState(language: 'en');
      expect(state.materialLocale.languageCode, 'en');
      const spanish = LocaleState(language: 'es');
      expect(spanish.materialLocale.languageCode, 'es');
    });
  });

  group('ApiClient language header', () {
    test('every JSON request states the effective language', () {
      final client = ApiClient(baseUrl: 'http://x/api/v1');
      expect(client.jsonHeaders()['Accept-Language'], 'en');

      client.localeTag = 'es';
      expect(client.jsonHeaders()['Accept-Language'], 'es');
      // The existing headers must survive the addition.
      expect(client.jsonHeaders(json: true)['Content-Type'], 'application/json');
      expect(client.jsonHeaders()['Accept'], 'application/json');
    });
  });

  group('locale-aware formatting', () {
    setUp(() => Intl.defaultLocale = null);
    tearDown(() => Intl.defaultLocale = null);

    test('English formatting is unchanged by the intl migration', () {
      expect(tripDateRange('2026-03-04', '2026-03-09'), 'Mar 4 – Mar 9');
      expect(tripDateRange('2026-03-04', '2026-03-04'), 'Mar 4');
      expect(tripDateRange(null, '2026-03-09'), isNull);
      expect(formatMoney(412, 'EUR'), '€412');
      expect(formatMoney(1234, 'USD'), r'$1,234');
      expect(formatMoney(-5, 'USD'), r'-$5');
    });

    test('Spanish formatting follows the active locale', () async {
      // flutter_localizations does this at startup for the app's locale; unit
      // tests have no delegates, so load the symbols explicitly.
      await initializeDateFormatting('es');
      Intl.defaultLocale = 'es';

      // Day-before-month ordering and Spanish month abbreviations.
      expect(tripDateRange('2026-03-04', '2026-03-09'), '4 mar – 9 mar');
      // Grouping separator flips; the currency symbol does not (it is a
      // property of the currency, not of the reader's language).
      expect(formatMoney(1234, 'USD'), r'$1.234');
      expect(formatMoney(412, 'EUR'), '€412');
    });
  });

  group('citiesLabel', () {
    test('falls back to English connectors without translations', () {
      expect(citiesLabel(null), isNull);
      expect(citiesLabel([]), isNull);
      expect(citiesLabel(['Paris']), 'Paris');
      expect(citiesLabel(['Mexico City', 'Puerto Vallarta']),
          'Mexico City & Puerto Vallarta');
      expect(citiesLabel(['Tokyo', 'Kyoto', 'Osaka', 'Nara']),
          'Tokyo & Kyoto +2 more');
    });

    test('uses the translated connectors when supplied', () {
      expect(
        citiesLabel(['Madrid', 'Sevilla'], two: (a, b) => '$a y $b'),
        'Madrid y Sevilla',
      );
      expect(
        citiesLabel(
          ['Madrid', 'Sevilla', 'Granada', 'Córdoba'],
          more: (a, b, n) => '$a y $b +$n más',
        ),
        'Madrid y Sevilla +2 más',
      );
    });
  });
}
