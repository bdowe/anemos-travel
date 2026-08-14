import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/models/airport.dart';
import 'package:travel_route_planner/providers/flights_provider.dart';
import 'package:travel_route_planner/services/api_client.dart';
import 'package:travel_route_planner/services/flights_api_service.dart';
import 'package:travel_route_planner/widgets/airport_field.dart';

import 'support/l10n_test_app.dart';

/// AirportField is editable in place.
///
/// It used to render a chosen airport as static text with only a clear button,
/// so a value that was already set could not be typed over at all. The Travel
/// profile seeds its home airport from the server, which meant that page always
/// opened in the non-editable state — "I am unable to edit the home airport".
///
/// These pin the single-mode behavior and the two ways the old two-mode design
/// could lose an edit: text wiped by a late parent seed, and a pick that blanks
/// the field instead of showing what was picked.

class _FakeFlightsApiService extends FlightsApiService {
  _FakeFlightsApiService() : super(ApiClient(baseUrl: 'http://test'));

  @override
  Future<List<Airport>> searchAirports(String query) async => const [
        Airport(
          iataCode: 'SEA',
          name: 'Seattle-Tacoma International Airport',
          city: 'Seattle',
          country: 'US',
          subType: 'airport',
        ),
      ];
}

/// Hosts the field and owns `selected`, the way every real call site does.
/// [seed] lets a test push a selection in *after* first build, reproducing Find
/// Flights resolving its origin asynchronously.
class _Host extends StatefulWidget {
  final Airport? initial;
  const _Host({super.key, this.initial});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  Airport? selected;
  int voided = 0;

  @override
  void initState() {
    super.initState();
    selected = widget.initial;
  }

  void seed(Airport a) => setState(() => selected = a);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AirportField(
        label: 'Home airport',
        icon: Icons.home,
        selected: selected,
        onSelected: (a) => setState(() {
          if (a == null) voided++;
          selected = a;
        }),
      ),
    );
  }
}

const _saved = Airport(iataCode: 'BOS', name: 'BOS');

Future<_HostState> _pumpField(WidgetTester tester, {Airport? initial}) async {
  final key = GlobalKey<_HostState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        flightsApiServiceProvider.overrideWithValue(_FakeFlightsApiService()),
      ],
      child: localizedTestApp(home: _Host(key: key, initial: initial)),
    ),
  );
  await tester.pumpAndSettle();
  return key.currentState!;
}

TextField _field(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField));

void main() {
  testWidgets('a saved airport renders in an editable TextField', (t) async {
    await _pumpField(t, initial: _saved);

    // The regression: this used to be an InputDecorator wrapping a static Text,
    // with no TextField to put a cursor in.
    expect(find.byType(TextField), findsOneWidget);
    expect(_field(t).controller?.text, 'BOS');
  });

  testWidgets('typing over a saved airport keeps the text and voids the pick',
      (t) async {
    final host = await _pumpField(t, initial: _saved);

    await t.enterText(find.byType(TextField), 'sea');
    await t.pump();

    expect(_field(t).controller?.text, 'sea');
    expect(host.selected, isNull,
        reason: 'the stale pick must not survive an edit');
    expect(host.voided, 1);
  });

  testWidgets('picking a suggestion shows the picked label, not a blank field',
      (t) async {
    final host = await _pumpField(t);

    await t.enterText(find.byType(TextField), 'sea');
    await t.pump(const Duration(milliseconds: 350)); // debounce
    await t.pumpAndSettle();

    await t.tap(find.text('Seattle (SEA)'));
    await t.pumpAndSettle();

    expect(host.selected?.iataCode, 'SEA');
    expect(_field(t).controller?.text, 'Seattle (SEA)');
    // The list closed rather than staying open over the committed value.
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('a late parent seed does not overwrite in-progress typing',
      (t) async {
    final host = await _pumpField(t);

    await t.enterText(find.byType(TextField), 'lis');
    await t.pump();

    // Find Flights' home-airport seed landing mid-edit.
    host.seed(const Airport(iataCode: 'JFK', name: 'JFK'));
    await t.pumpAndSettle();

    expect(_field(t).controller?.text, 'lis');
    expect(host.selected, isNull,
        reason: 'the widget reports the seed void rather than adopting it');
  });

  testWidgets('a seed arriving on an untouched field is adopted', (t) async {
    final host = await _pumpField(t);
    expect(_field(t).controller?.text, isEmpty);

    host.seed(const Airport(iataCode: 'JFK', name: 'JFK'));
    await t.pumpAndSettle();

    expect(_field(t).controller?.text, 'JFK');
    expect(host.selected?.iataCode, 'JFK');
  });

  testWidgets('the clear button empties both the text and the selection',
      (t) async {
    final host = await _pumpField(t, initial: _saved);

    await t.tap(find.byIcon(Icons.close));
    await t.pumpAndSettle();

    expect(_field(t).controller?.text, isEmpty);
    expect(host.selected, isNull);
  });
}
