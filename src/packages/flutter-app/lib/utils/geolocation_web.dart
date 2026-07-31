import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'geolocation_types.dart';

/// Web implementation of the current-position lookup (the "What's near me?"
/// chip): one browser geolocation fix, mapped to a [GeoResult].
///
/// Coordinates are rounded to 4 decimals (~11 m) before they leave this
/// function — precise enough for "near me", coarse enough that the exact
/// position never lands in chat transcripts, and stable across GPS jitter so
/// the server's biased-search cache keys repeat.
///
/// A low-accuracy fix is requested (city-block precision is plenty) with a
/// 60 s `maximumAge` so a recent fix is reused instead of re-prompting the
/// hardware. The browser gets [timeout] to produce a fix; a Dart-side
/// belt-and-braces timer at timeout + 2 s guarantees the Future completes
/// even if the browser never fires either callback.
Future<GeoResult> getCurrentPosition(
    {Duration timeout = const Duration(seconds: 10)}) async {
  // Geolocation only exists in secure contexts (HTTPS/localhost); elsewhere
  // touching the API can throw, so treat any failure here as unsupported.
  try {
    if (!web.window.isSecureContext) {
      return const GeoResult.fail(GeoErrorKind.unsupported);
    }
    final completer = Completer<GeoResult>();
    void finish(GeoResult r) {
      if (!completer.isCompleted) completer.complete(r);
    }

    double round4(double v) => (v * 1e4).roundToDouble() / 1e4;

    web.window.navigator.geolocation.getCurrentPosition(
      ((web.GeolocationPosition pos) {
        final c = pos.coords;
        finish(GeoResult.ok(
            round4(c.latitude), round4(c.longitude), c.accuracy));
      }).toJS,
      ((web.GeolocationPositionError err) {
        finish(GeoResult.fail(switch (err.code) {
          1 => GeoErrorKind.denied,
          2 => GeoErrorKind.unavailable,
          3 => GeoErrorKind.timeout,
          _ => GeoErrorKind.unavailable,
        }));
      }).toJS,
      web.PositionOptions(
        enableHighAccuracy: false,
        timeout: timeout.inMilliseconds,
        maximumAge: 60000,
      ),
    );
    return await completer.future.timeout(
      timeout + const Duration(seconds: 2),
      onTimeout: () => const GeoResult.fail(GeoErrorKind.timeout),
    );
  } catch (_) {
    return const GeoResult.fail(GeoErrorKind.unsupported);
  }
}
