/// URL builders for the chat photo cards (places/local picks): the API's
/// place-photo redirect endpoint and Google Maps deep links.
library;

/// Builds `<apiBase>/places/photo?ref=..&w=..` — the API endpoint that 302s to
/// the actual Google photo. Built off the configured API base (not
/// root-relative) so `make flutter-run` dev, where the app and API are
/// different origins, resolves against the API rather than the dev server.
String placePhotoUrl(String apiBaseUrl, String photoRef, {int width = 400}) =>
    '$apiBaseUrl/places/photo?ref=${Uri.encodeQueryComponent(photoRef)}&w=$width';

/// Google Maps deep link per the maps URL scheme; falls back to a name-only
/// query when no place_id is available.
String googleMapsSearchUrl(String name, String placeId) =>
    'https://www.google.com/maps/search/?api=1'
    '&query=${Uri.encodeQueryComponent(name)}'
    '${placeId.isEmpty ? '' : '&query_place_id=${Uri.encodeQueryComponent(placeId)}'}';
