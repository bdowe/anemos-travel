import 'geolocation_types.dart';

/// Non-web stub for the current-position lookup: native geolocation needs a
/// plugin (geolocator-class dependency) plus per-platform permission strings
/// that aren't worth the weight while web is the primary target. Reporting
/// [GeoErrorKind.unsupported] routes those builds to the manual location
/// entry, which VM widget tests exercise too (they resolve to this stub).
///
/// See geolocation_web.dart for the real implementation and the contract.
Future<GeoResult> getCurrentPosition(
    {Duration timeout = const Duration(seconds: 10)}) async {
  return const GeoResult.fail(GeoErrorKind.unsupported);
}
