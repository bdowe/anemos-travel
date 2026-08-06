import 'package:flutter_test/flutter_test.dart';

/// Expands the trip-detail city group whose header shows [label] by tapping
/// it. Groups default to collapsed (only a sole group is seeded open), so
/// tests that assert on a group's contents expand it first. [index] picks
/// among duplicate headers when a trip revisits a city (first run = 0).
Future<void> expandCity(WidgetTester tester, String label,
    {int index = 0}) async {
  await tester.tap(find.text(label).at(index));
  await tester.pumpAndSettle();
}
