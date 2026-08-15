import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:travel_route_planner/providers/destination_photos.dart';
import 'package:travel_route_planner/providers/suggestions_provider.dart';

/// The seam between hand-written prompts and generated photos.
///
/// `suggestionPool` is edited by hand; `kDestinationPhotos`, the .webp files
/// and CREDITS.md are all written by `scripts/fetch-destination-photos.py`.
/// Nothing but this test notices when the two drift — a prompt appended
/// without a photo, a pubspec entry never added, an image deleted — and the
/// symptom in the app would be a card that quietly renders its fallback box.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every pool prompt names a photo that exists in the table', () {
    for (final prompt in suggestionPool) {
      expect(prompt.photo, isNotEmpty);
      expect(kDestinationPhotos, contains(prompt.photo),
          reason: 'add "${prompt.photo}" to SOURCES in '
              'scripts/fetch-destination-photos.py and re-run it');
      // photoFor is what the UI actually calls; prove it agrees.
      expect(photoFor(prompt), same(kDestinationPhotos[prompt.photo]));
    }
  });

  test('photos are distinct, well-located and credited', () {
    final assets = <String>[];
    for (final prompt in suggestionPool) {
      final photo = photoFor(prompt);
      expect(photo.asset,
          'assets/images/destinations/${prompt.photo}.webp',
          reason: 'the generator names files after the slug');
      // CC BY sources require attribution, so an empty credit is a license
      // problem, not a cosmetic one.
      expect(photo.credit.trim(), isNotEmpty,
          reason: 'no credit for ${prompt.photo}');
      assets.add(photo.asset);
    }
    expect(assets.toSet(), hasLength(assets.length),
        reason: 'two prompts sharing one photo reads as a wiring bug');
  });

  test('every photo is a real bundled asset', () async {
    for (final prompt in suggestionPool) {
      final asset = photoFor(prompt).asset;
      // Loads through the real bundle, so a missing file OR a missing
      // pubspec `assets:` entry fails here rather than in the running app.
      final bytes = await rootBundle.load(asset);
      expect(bytes.lengthInBytes, greaterThan(0), reason: 'empty $asset');
      // The cards are 200x96 slots; anything near a megabyte means someone
      // dropped a full-resolution photo in and skipped the generator.
      expect(bytes.lengthInBytes, lessThan(150 * 1024),
          reason: '$asset is too heavy for a suggestion card');
    }
  });

  test('the generated table has no photos the pool never uses', () {
    final used = {for (final prompt in suggestionPool) prompt.photo};
    expect(kDestinationPhotos.keys.toSet().difference(used), isEmpty,
        reason: 'drop the unused slug from SOURCES so the app stops '
            'shipping an image nothing can show');
  });
}
