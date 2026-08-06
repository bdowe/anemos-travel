// Transition telemetry for specs/server-leg-dates: compares the server
// `legs` payload against the local derivation the screen still renders, so
// Brian's daily prod dogfooding IS the parity monitor gating the stage-2a
// client repoint. Deleted with the fallback at stage 6a.
//
// Pure: no widgets, no providers. Callers emit the analytics event.

import 'package:intl/intl.dart';

import '../models/trip.dart';
import 'leg_ranges.dart';

/// Human-readable payload-vs-local differences for [trip]; empty = parity.
/// Empty when the payload carries no legs (nothing to compare). Compares
/// label and rendered span only — coordinates and positions are not part of
/// the dates contract.
List<String> legParityMismatches(Trip trip) {
  final payload = trip.legs;
  if (payload == null) return const [];
  final local = visibleLegRanges(trip);

  String? fmt(DateTime? d) =>
      d == null ? null : DateFormat('yyyy-MM-dd').format(d);

  final out = <String>[];
  if (payload.length != local.length) {
    out.add('leg count: payload ${payload.length} vs local ${local.length}');
  }
  final n = payload.length < local.length ? payload.length : local.length;
  for (var i = 0; i < n; i++) {
    final p = payload[i];
    final l = local[i];
    if (p.label != l.label) {
      out.add('[$i] label: ${p.label} vs ${l.label}');
    }
    if (p.startDate != fmt(l.start)) {
      out.add('[$i] ${p.label} start: ${p.startDate} vs ${fmt(l.start)}');
    }
    if (p.endDate != fmt(l.end)) {
      out.add('[$i] ${p.label} end: ${p.endDate} vs ${fmt(l.end)}');
    }
  }
  return out;
}
