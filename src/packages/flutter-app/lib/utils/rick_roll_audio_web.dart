import 'dart:js_interop';
import 'dart:math' as math;

import 'package:web/web.dart' as web;

import 'rick_roll_tune.dart';

/// Peak amplitude of the whole tune. Square waves carry far more energy than
/// their amplitude suggests, so this sits low deliberately: an easter egg that
/// blows somebody's headphones off is a bug report, not a joke.
const double _masterGain = 0.12;

/// Seconds of lead-in before the first note. The scheduler needs a moment of
/// headroom or the browser drops the attack of note one.
const double _leadIn = 0.06;

/// Attack, and how long before a note's end its release begins. The release is
/// what separates the two identical `B4`s that open the phrase — without it
/// they run together into one long note and the melody stops being
/// recognizable.
const double _attack = 0.01;
const double _release = 0.05;

/// Plays [kRickRollHook] through one [web.AudioContext] of scheduled square
/// waves.
///
/// Every note is scheduled up front against the context clock rather than
/// driven by a Dart timer: timers drift, and a melody that drifts is a melody
/// nobody recognizes.
///
/// Returns [SilentRickRollPlayback] rather than throwing if the browser will
/// not give us a context. A keystroke grants user activation in Chrome and
/// Firefox, but Safari can still hand back a context that never starts, so the
/// caller must treat "no sound" as an ordinary outcome.
RickRollPlayback playRickRollHook() {
  final web.AudioContext ctx;
  try {
    ctx = web.AudioContext();
  } catch (_) {
    return const SilentRickRollPlayback();
  }

  try {
    // Best-effort: a context created before the browser considers the page
    // "activated" starts suspended. Failure here is not fatal — the notes are
    // still scheduled, they just may never sound.
    ctx.resume().toDart.catchError((Object _) => null);

    final master = ctx.createGain();
    master.gain.setValueAtTime(_masterGain, ctx.currentTime);
    master.connect(ctx.destination);

    var at = ctx.currentTime + _leadIn;
    for (final note in kRickRollHook) {
      final seconds = note.length.inMicroseconds / 1000000.0;
      final hertz = note.hertz;
      if (hertz != null) {
        final end = at + seconds;
        // Clamp so a note shorter than attack + release still gets a shape
        // instead of a backwards envelope.
        final releaseAt = math.max(at + _attack, end - _release);

        final osc = ctx.createOscillator();
        osc.type = 'square';
        osc.frequency.setValueAtTime(hertz, at);

        final env = ctx.createGain();
        env.gain.setValueAtTime(0, at);
        env.gain.linearRampToValueAtTime(1, at + _attack);
        env.gain.setValueAtTime(1, releaseAt);
        env.gain.linearRampToValueAtTime(0, end);

        osc.connect(env);
        env.connect(master);
        osc.start(at);
        osc.stop(end + 0.01);
      }
      at += seconds;
    }
    return _AudioContextPlayback(ctx);
  } catch (_) {
    // Half-scheduled is worse than silent: tear the context down so no
    // fragment of the tune is left playing.
    final playback = _AudioContextPlayback(ctx)..stop();
    return playback;
  }
}

class _AudioContextPlayback implements RickRollPlayback {
  _AudioContextPlayback(this._ctx);

  final web.AudioContext _ctx;
  bool _stopped = false;

  /// Closing the context kills every scheduled note at once, which is why
  /// nothing here tracks the individual oscillators. Guarded and wrapped
  /// because closing twice — dismissing by hand at the exact moment the tune
  /// ends on its own — throws `InvalidStateError`.
  @override
  void stop() {
    if (_stopped) return;
    _stopped = true;
    try {
      _ctx.close().toDart.catchError((Object _) => null);
    } catch (_) {
      // Already closed, or the context was never usable.
    }
  }
}
