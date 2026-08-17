import 'dart:js_interop';
import 'dart:math' as math;

import 'package:web/web.dart' as web;

import 'rick_roll_tune.dart';

/// Peak amplitude of the whole tune. Square waves carry far more energy than
/// their amplitude suggests, so this stays low — an easter egg that blows
/// somebody's headphones off is a bug report, not a joke — but not so low that
/// a phone speaker cannot produce it.
const double _masterGain = 0.18;

/// Seconds of lead-in before the first note. The scheduler needs a moment of
/// headroom or the browser drops the attack of note one.
const double _leadIn = 0.06;

/// Attack, and how long before a note's end its release begins. The release is
/// what separates the two identical `B4`s that open the phrase — without it
/// they run together into one long note and the melody stops being
/// recognizable.
const double _attack = 0.01;
const double _release = 0.05;

/// The one audio context for the page's lifetime.
///
/// Shared rather than per-play because it can only be opened at a moment the
/// browser allows, and that moment is the user's first interaction — long
/// before anybody enters the code. See [primeRickRollAudio].
web.AudioContext? _shared;
bool _primed = false;

/// Opens the audio context on the first real interaction with the page.
///
/// The listeners sit on `document` in the **capture** phase so they see the
/// event before Flutter's own handling, and they are never removed: a context
/// can be suspended again by the browser (a backgrounded tab, an iOS call),
/// and re-resuming on the next interaction is exactly the recovery wanted.
///
/// Creating the context here rather than at import time is deliberate. A
/// context constructed with no user activation is born `suspended`, and on
/// Safari `resume()` outside a gesture handler will not revive it — so an
/// eagerly-built one would be permanently silent, which is the failure this
/// function exists to prevent.
void primeRickRollAudio() {
  if (_primed) return;
  _primed = true;
  try {
    final unlock = ((web.Event _) => _openContext()).toJS;
    final options = web.AddEventListenerOptions(capture: true, passive: true);
    for (final type in const ['pointerdown', 'keydown', 'touchend']) {
      web.document.addEventListener(type, unlock, options);
    }
  } catch (_) {
    // No document, or an engine that dislikes the options bag. The egg still
    // runs; it may just be silent.
  }
}

/// The context if we have a usable one, opening or resuming it if we can.
/// Returns null rather than throwing — silence is an ordinary outcome.
web.AudioContext? _openContext() {
  try {
    final ctx = _shared ??= web.AudioContext();
    if (ctx.state != 'running') {
      ctx.resume().toDart.catchError((Object _) => null);
    }
    return ctx;
  } catch (_) {
    return null;
  }
}

/// Plays [kRickRollHook] as scheduled square waves.
///
/// Every note is scheduled up front against the context clock rather than
/// driven by a Dart timer: timers drift, and a melody that drifts is a melody
/// nobody recognizes.
///
/// Returns [SilentRickRollPlayback] rather than throwing if there is no usable
/// context. The caller treats that exactly like success, because the visual
/// must never depend on audio.
RickRollPlayback playRickRollHook() {
  final ctx = _openContext();
  if (ctx == null) return const SilentRickRollPlayback();

  final oscillators = <web.OscillatorNode>[];
  try {
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
        oscillators.add(osc);
      }
      at += seconds;
    }
    return _ScheduledPlayback(oscillators, master);
  } catch (_) {
    // Half-scheduled is worse than silent: silence what was scheduled.
    final playback = _ScheduledPlayback(oscillators, null)..stop();
    return playback;
  }
}

class _ScheduledPlayback implements RickRollPlayback {
  _ScheduledPlayback(this._oscillators, this._master);

  final List<web.OscillatorNode> _oscillators;
  final web.GainNode? _master;
  bool _stopped = false;

  /// Stops the notes and cuts the branch off the graph.
  ///
  /// It deliberately does NOT close the context — that context is shared and
  /// unlocked, and closing it would spend the one unlock the page is going to
  /// get. (The previous version could close it, because it built a throwaway
  /// context per play; that is exactly the design that was silent on Safari.)
  /// Disconnecting the master gain is what makes the cut instant, since
  /// `stop()` on an already-finished node is a no-op and on a not-yet-started
  /// one throws.
  @override
  void stop() {
    if (_stopped) return;
    _stopped = true;
    try {
      _master?.disconnect();
    } catch (_) {}
    for (final osc in _oscillators) {
      try {
        osc.stop();
      } catch (_) {
        // Already finished, or never started. Either way it is not sounding.
      }
    }
  }
}
