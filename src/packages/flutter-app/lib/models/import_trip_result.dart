/// Result of POST /trips/import: the freshly created trip plus user-facing
/// warnings about places that resolved approximately or were left out. Plain
/// model (small, read-only — same treatment as SharedTrip).
class ImportTripResult {
  final String tripId;
  final String title;
  final int itemCount;

  /// Localized, display-ready strings from the server (approximate/dropped
  /// places, degraded place verification). Empty when everything resolved.
  final List<String> warnings;

  const ImportTripResult({
    required this.tripId,
    required this.title,
    required this.itemCount,
    this.warnings = const [],
  });

  factory ImportTripResult.fromJson(Map<String, dynamic> json) =>
      ImportTripResult(
        tripId: json['trip_id'] as String,
        title: (json['title'] as String?) ?? '',
        itemCount: (json['item_count'] as num?)?.toInt() ?? 0,
        warnings: ((json['warnings'] as List?) ?? const [])
            .whereType<String>()
            .toList(),
      );
}
