import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/utils/place_links.dart';

void main() {
  test('placePhotoUrl builds off the API base and query-encodes the ref', () {
    expect(
      placePhotoUrl('http://localhost:8080/api/v1', 'REF+a/b c'),
      'http://localhost:8080/api/v1/places/photo?ref=REF%2Ba%2Fb+c&w=400',
    );
    // Prod web builds configure a relative base; the path stays relative.
    expect(
      placePhotoUrl('/api/v1', 'r1', width: 800),
      '/api/v1/places/photo?ref=r1&w=800',
    );
  });

  test('googleMapsSearchUrl encodes the name and appends the place id', () {
    expect(
      googleMapsSearchUrl('Bar El Comercio', 'p1'),
      'https://www.google.com/maps/search/?api=1&query=Bar+El+Comercio&query_place_id=p1',
    );
    // No place id → name-only query, no dangling param.
    expect(
      googleMapsSearchUrl('Setas', ''),
      'https://www.google.com/maps/search/?api=1&query=Setas',
    );
  });
}
