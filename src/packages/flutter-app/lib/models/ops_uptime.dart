import 'package:json_annotation/json_annotation.dart';

part 'ops_uptime.g.dart';

/// 90-day availability history from GET /admin/ops/uptime — one row per
/// monitored component, one bucket per UTC day, admin-only
/// (specs/uptime-history). Rolled up server-side from the health monitor's
/// samples; the client NEVER recomputes a percentage (docs/zen.md — derived
/// state is computed in exactly one place), it lays out the numbers the
/// server sends. snake_case JSON keys via [FieldRename.snake].

/// One UTC day for one component.
///
/// [state] is a canonical API value — "up" | "degraded" | "down" | "no_data" —
/// kept as a String for the same reason [HealthDb.status] is: a state the
/// server adds tomorrow must render as unknown, not throw at parse time.
/// [uptimePct] is null IFF the day is no_data: null, 0.0, and 100.0 are three
/// different values and the UI must never conflate them.
@JsonSerializable(fieldRename: FieldRename.snake)
class UptimeDay {
  /// "YYYY-MM-DD". Kept as the wire string; [OpsUptime.utcDay] is the one
  /// parser (DateTime.parse on a bare date yields UTC, but every comparison
  /// still normalizes — the AdminTimeseries.denseSeries lesson).
  final String day;
  final String state;
  final double? uptimePct;
  final int upS;
  final int downS;
  final int unknownS;

  /// Stable reason codes ("db_unreachable" | "process_down" | "ai_failing" |
  /// "backups_stale"), localized by the widget — the wire never carries prose.
  final List<String> reasonCodes;

  const UptimeDay({
    this.day = '',
    this.state = 'no_data',
    this.uptimePct,
    this.upS = 0,
    this.downS = 0,
    this.unknownS = 0,
    this.reasonCodes = const [],
  });

  bool get hasData => state != 'no_data';

  factory UptimeDay.fromJson(Map<String, dynamic> json) =>
      _$UptimeDayFromJson(json);
  Map<String, dynamic> toJson() => _$UptimeDayToJson(this);
}

/// One monitored component and its window.
@JsonSerializable(fieldRename: FieldRename.snake)
class UptimeComponent {
  /// Stable API key: "api" | "database" | "ai_provider" | "backups". Display
  /// names are localized off this key, never off a server-sent string.
  final String key;

  /// Current state from the freshest sample: "up" | "down" | "no_data".
  final String status;

  /// Window percentage over OBSERVED seconds only; null when nothing was
  /// observed in the window.
  final double? uptimePct;
  final int observedDays;

  /// DENSE: exactly [OpsUptime.days] entries, oldest first — the server owns
  /// gap semantics, so the client never synthesizes a day.
  final List<UptimeDay> days;

  const UptimeComponent({
    this.key = '',
    this.status = 'no_data',
    this.uptimePct,
    this.observedDays = 0,
    this.days = const [],
  });

  factory UptimeComponent.fromJson(Map<String, dynamic> json) =>
      _$UptimeComponentFromJson(json);
  Map<String, dynamic> toJson() => _$UptimeComponentToJson(this);
}

/// Mirror of GET /admin/ops/uptime?days=90.
@JsonSerializable(fieldRename: FieldRename.snake)
class OpsUptime {
  final int days;

  /// First day of the window, "YYYY-MM-DD" (UTC).
  final String startDay;

  /// When the first sample ever was recorded; null before any exist. What
  /// lets the pane caption a wall of grey bars as "before we were watching".
  final DateTime? monitoringSince;
  final List<UptimeComponent> components;

  const OpsUptime({
    this.days = 0,
    this.startDay = '',
    this.monitoringSince,
    this.components = const [],
  });

  /// The one "YYYY-MM-DD" → UTC DateTime parser for this payload.
  static DateTime? utcDay(String day) {
    final d = DateTime.tryParse(day);
    if (d == null) return null;
    return DateTime.utc(d.year, d.month, d.day);
  }

  factory OpsUptime.fromJson(Map<String, dynamic> json) =>
      _$OpsUptimeFromJson(json);
  Map<String, dynamic> toJson() => _$OpsUptimeToJson(this);
}
