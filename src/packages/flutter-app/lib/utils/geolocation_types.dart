/// Shared result types for the current-position lookup, imported by both
/// geolocation_stub.dart and geolocation_web.dart (and by callers) so the
/// conditional import only swaps the implementation, never the contract.
library;

/// Why a position lookup produced no coordinates.
enum GeoErrorKind {
  /// No geolocation capability at all: non-web build, insecure context, or a
  /// browser without the API. The UI should skip straight to manual entry.
  unsupported,

  /// The user (or browser policy) refused the permission prompt.
  denied,

  /// The device tried and failed to produce a fix.
  unavailable,

  /// No fix arrived within the timeout.
  timeout,
}

/// Outcome of a current-position lookup: either coordinates or an error kind,
/// never both.
class GeoResult {
  final double? latitude;
  final double? longitude;
  final double? accuracyMeters;
  final GeoErrorKind? error;

  const GeoResult.ok(this.latitude, this.longitude, this.accuracyMeters)
      : error = null;

  const GeoResult.fail(this.error)
      : latitude = null,
        longitude = null,
        accuracyMeters = null;

  bool get ok => error == null;
}
