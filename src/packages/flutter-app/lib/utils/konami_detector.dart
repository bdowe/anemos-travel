import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart' show LogicalKeyboardKey;

/// The Konami code, in the order it has to arrive: ↑ ↑ ↓ ↓ ← → ← → B A.
const List<LogicalKeyboardKey> kKonamiCode = [
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.keyB,
  LogicalKeyboardKey.keyA,
];

/// Watches a keystroke stream for [kKonamiCode].
///
/// Deliberately a **rolling buffer of the last ten keys** rather than the
/// obvious advance-an-index matcher. The code opens `↑ ↑`, so an index matcher
/// desyncs the moment somebody overshoots: at `↑ ↑ ↑` the third arrow fails
/// the expected `↓`, the index resets to 0, and every subsequent key is then
/// tested against the wrong position — the sequence can never complete no
/// matter how correctly the rest of it is typed. Recovering from that needs a
/// KMP failure table; comparing the tail of a ten-element buffer needs four
/// lines and is right for *any* prefix of junk.
///
/// Pure Dart on purpose ([LogicalKeyboardKey] is the only Flutter type here),
/// so the matching rules are unit-testable without pumping a widget.
class KonamiDetector {
  final List<LogicalKeyboardKey> _recent = <LogicalKeyboardKey>[];

  /// Records [key] and reports whether the code has just completed.
  ///
  /// Returns true on the keystroke that finishes the sequence and not again
  /// until the whole thing is re-entered — the buffer keeps its contents, so
  /// one extra `A` after a successful run does not re-fire.
  bool accept(LogicalKeyboardKey key) {
    _recent.add(key);
    if (_recent.length > kKonamiCode.length) {
      _recent.removeAt(0);
    }
    return listEquals(_recent, kKonamiCode);
  }

  /// Forgets the keys seen so far. Not needed for correctness — the buffer
  /// self-heals — but lets a caller draw a hard line under a session.
  void reset() => _recent.clear();
}
