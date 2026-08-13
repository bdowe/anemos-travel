import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:travel_route_planner/models/checklist_item.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/checklist_api_service.dart';
import 'package:travel_route_planner/providers/checklist_provider.dart';
import 'package:travel_route_planner/widgets/checklist_section.dart';

import 'support/l10n_test_app.dart';

/// A stateful fake: it holds the list so invalidate-after-mutate reflects the
/// change, and records which network methods were called for assertions.
class _FakeChecklistApiService extends ChecklistApiService {
  final List<ChecklistItem> items;
  final List<Map<String, dynamic>> patches = [];
  int addCount = 0;
  int deleteCount = 0;

  _FakeChecklistApiService(this.items)
      : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<ChecklistItem>> list(String tripId) async =>
      List.of(items); // snapshot

  @override
  Future<ChecklistItem> add(
      String tripId, String title, String category) async {
    addCount++;
    final item = ChecklistItem(
        id: 'new-$addCount', category: category, title: title);
    items.add(item);
    return item;
  }

  @override
  Future<ChecklistItem> update(
      String tripId, String itemId, Map<String, dynamic> body) async {
    patches.add({'id': itemId, ...body});
    final idx = items.indexWhere((i) => i.id == itemId);
    if (idx >= 0) {
      items[idx] = items[idx].copyWith(
        checked: body['checked'] as bool?,
        title: body['title'] as String?,
        category: body['category'] as String?,
      );
      return items[idx];
    }
    throw Exception('not found');
  }

  @override
  Future<void> delete(String tripId, String itemId) async {
    deleteCount++;
    items.removeWhere((i) => i.id == itemId);
  }
}

ChecklistItem _item(String id, String category, String title,
        {bool checked = false}) =>
    ChecklistItem(id: id, category: category, title: title, checked: checked);

Future<_FakeChecklistApiService> _pump(
    WidgetTester tester, List<ChecklistItem> items,
    {bool canEdit = true, bool isOffline = false}) async {
  final fake = _FakeChecklistApiService(items);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        checklistApiServiceProvider.overrideWithValue(fake),
      ],
      child: MaterialApp(
      localizationsDelegates: testLocalizationsDelegates,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChecklistSection(
                tripId: 't1', canEdit: canEdit, isOffline: () => isOffline),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

void main() {
  testWidgets('renders items grouped by category with a progress pill',
      (tester) async {
    await _pump(tester, [
      _item('a', 'documents', 'Passport'),
      _item('b', 'clothing', 'Rain jacket', checked: true),
      _item('c', 'general', 'Snacks'),
    ]);

    expect(find.text('Packing & prep'), findsOneWidget);
    // Category group headers.
    expect(find.text('Documents'), findsOneWidget);
    expect(find.text('Clothing'), findsOneWidget);
    expect(find.text('General'), findsOneWidget);
    // Items.
    expect(find.text('Passport'), findsOneWidget);
    expect(find.text('Rain jacket'), findsOneWidget);
    // Progress pill: 1 of 3 checked.
    expect(find.text('1/3'), findsOneWidget);
  });

  testWidgets('toggling an item checkbox calls PATCH with checked',
      (tester) async {
    final fake = await _pump(tester, [_item('a', 'general', 'Snacks')]);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();

    expect(fake.patches, isNotEmpty);
    expect(fake.patches.first['id'], 'a');
    expect(fake.patches.first['checked'], true);
  });

  testWidgets('adding an item posts to the service', (tester) async {
    final fake = await _pump(tester, [_item('a', 'general', 'Snacks')]);

    await tester.enterText(find.byType(TextField), 'Sunscreen');
    await tester.tap(find.byTooltip('Add item'));
    await tester.pumpAndSettle();

    expect(fake.addCount, 1);
    expect(find.text('Sunscreen'), findsOneWidget);
  });

  testWidgets('empty state shows the AI-assistant hint and an add field',
      (tester) async {
    await _pump(tester, []);

    expect(find.text('Nothing packed yet'), findsOneWidget);
    expect(find.textContaining('AI assistant'), findsOneWidget);
    // The add affordance is still available for the editor.
    expect(find.byTooltip('Add item'), findsOneWidget);
  });

  testWidgets('viewer with no items renders nothing', (tester) async {
    await _pump(tester, [], canEdit: false);

    expect(find.text('Packing & prep'), findsNothing);
    expect(find.byTooltip('Add item'), findsNothing);
  });
}
