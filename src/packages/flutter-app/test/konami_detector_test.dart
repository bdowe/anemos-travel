import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:travel_route_planner/utils/konami_detector.dart';

/// Matching rules for the Konami code. Pure — no widget pump — because the
/// interesting cases are all about what a *sloppy* entry does, and those are
/// tedious to drive through a key simulator.
void main() {
  const up = LogicalKeyboardKey.arrowUp;
  const down = LogicalKeyboardKey.arrowDown;
  const left = LogicalKeyboardKey.arrowLeft;
  const right = LogicalKeyboardKey.arrowRight;
  const b = LogicalKeyboardKey.keyB;
  const a = LogicalKeyboardKey.keyA;

  /// Feeds every key and returns which positions reported a completed code.
  List<int> firesAt(List<LogicalKeyboardKey> keys) {
    final detector = KonamiDetector();
    return [
      for (var i = 0; i < keys.length; i++)
        if (detector.accept(keys[i])) i,
    ];
  }

  test('the code completes on its last key and not before', () {
    expect(firesAt(kKonamiCode), [kKonamiCode.length - 1]);
  });

  test('an overshot leading arrow still completes', () {
    // The reason this detector is a rolling buffer and not an index. The code
    // opens with two Ups; press three and an index matcher can never recover,
    // no matter how correctly the remaining eight keys are typed.
    expect(firesAt([up, ...kKonamiCode]), [kKonamiCode.length]);
    expect(firesAt([up, up, ...kKonamiCode]), [kKonamiCode.length + 1]);
  });

  test('unrelated keystrokes before the code are ignored', () {
    expect(
      firesAt([a, b, down, right, ...kKonamiCode]),
      [kKonamiCode.length + 3],
    );
  });

  test('a wrong key inside the sequence stops it completing', () {
    expect(
      firesAt([up, up, down, down, left, left, left, right, b, a]),
      isEmpty,
    );
  });

  test('one more key after a completed code does not fire again', () {
    expect(firesAt([...kKonamiCode, a]), [kKonamiCode.length - 1]);
    expect(firesAt([...kKonamiCode, b, a]), [kKonamiCode.length - 1]);
  });

  test('the code fires again after a full re-entry', () {
    expect(
      firesAt([...kKonamiCode, ...kKonamiCode]),
      [kKonamiCode.length - 1, kKonamiCode.length * 2 - 1],
    );
  });

  test('reset drops a sequence in progress', () {
    final detector = KonamiDetector();
    for (final key in kKonamiCode.take(kKonamiCode.length - 1)) {
      expect(detector.accept(key), isFalse);
    }
    detector.reset();
    expect(detector.accept(kKonamiCode.last), isFalse);
  });
}
