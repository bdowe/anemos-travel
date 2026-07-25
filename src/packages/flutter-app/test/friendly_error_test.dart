import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/l10n/l10n.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/utils/errors.dart';

import 'support/l10n_test_app.dart';

/// friendlyError turns caught errors into localized, user-facing copy so raw
/// ApiException dumps never reach a snackbar or banner.
ApiException _api(int status) =>
    ApiException(statusCode: status, message: 'raw internal detail', endpoint: '/x');

void main() {
  Future<AppLocalizations> pumpL10n(WidgetTester tester, {Locale? locale}) async {
    late AppLocalizations l10n;
    await tester.pumpWidget(localizedTestApp(
      locale: locale,
      home: Builder(builder: (context) {
        l10n = context.l10n;
        return const SizedBox.shrink();
      }),
    ));
    return l10n;
  }

  testWidgets('maps ApiException status codes to distinct localized messages',
      (tester) async {
    final l10n = await pumpL10n(tester);

    expect(friendlyError(l10n, _api(0)), l10n.errorNetwork);
    expect(friendlyError(l10n, _api(401)), l10n.errorSession);
    expect(friendlyError(l10n, _api(403)), l10n.errorSession);
    expect(friendlyError(l10n, _api(429)), l10n.errorTooManyRequests);
    expect(friendlyError(l10n, _api(500)), l10n.errorServer);
    expect(friendlyError(l10n, _api(503)), l10n.errorServer);
    // 4xx that isn't 401/403/429 falls back to generic.
    expect(friendlyError(l10n, _api(400)), l10n.errorGeneric);
    expect(friendlyError(l10n, _api(404)), l10n.errorGeneric);

    // The raw internal message is never surfaced.
    expect(friendlyError(l10n, _api(500)), isNot(contains('raw internal detail')));
  });

  testWidgets('passes an already-friendly String (e.g. a /plan SSE error) through',
      (tester) async {
    final l10n = await pumpL10n(tester);
    const serverMessage = 'That destination is not supported yet.';
    expect(friendlyError(l10n, serverMessage), serverMessage);
  });

  testWidgets('an unclassifiable error falls back to the generic message',
      (tester) async {
    final l10n = await pumpL10n(tester);
    expect(friendlyError(l10n, Exception('boom')), l10n.errorGeneric);
    expect(friendlyError(l10n, null), l10n.errorGeneric);
  });

  testWidgets('resolves Spanish copy under an es locale', (tester) async {
    final l10n = await pumpL10n(tester, locale: const Locale('es'));
    expect(friendlyError(l10n, _api(0)), l10n.errorNetwork);
    expect(l10n.errorNetwork, contains('conexión'));
  });
}
