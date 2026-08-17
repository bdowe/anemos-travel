/// The tune the Konami code plays, and the contract the two playback
/// implementations share.
///
/// Imported by `rick_roll_audio_stub.dart`, `rick_roll_audio_web.dart` and by
/// the overlay itself, so the conditional import only ever swaps *how* sound
/// is made — never what is played or how long it lasts. Same split as
/// `geolocation_types.dart`.
///
/// Nothing is bundled: the hook is synthesized from this table at trigger
/// time. That is not only a size choice. The deployment sets
/// `Cross-Origin-Embedder-Policy: require-corp` on `/app/`, which blocks a
/// cross-origin YouTube embed outright, and the CSP declares no `media-src`,
/// so audio falls back to `default-src 'self'` — a `data:`/`blob:` clip would
/// work today and break the day that policy stops being Report-Only.
/// Oscillators are subject to neither.
library;

import 'dart:math' as math;

/// Beats per minute of the original chorus.
const int _tempoBpm = 114;

/// A whole note in microseconds — four beats at [_tempoBpm]. Every note length
/// is derived from this one number, so the tune cannot half-retune itself.
const int _wholeNoteMicros = 4 * 60 * 1000000 ~/ _tempoBpm;

/// One entry in the melody.
class RickRollNote {
  /// MIDI note number, or null for a rest.
  final int? midi;

  /// Note value in the usual score sense: `4` is a quarter, `8` an eighth,
  /// `16` a sixteenth. **Negative means dotted** (`-4` = dotted quarter), the
  /// convention the transcription this table came from uses.
  final int divisor;

  const RickRollNote(this.midi, this.divisor);

  /// How long this note sounds. Derived, never stored — see [_wholeNoteMicros].
  Duration get length {
    final base = _wholeNoteMicros ~/ divisor.abs();
    return Duration(microseconds: divisor < 0 ? base * 3 ~/ 2 : base);
  }

  /// Equal-temperament frequency in Hz, A4 (MIDI 69) = 440. Null for a rest.
  double? get hertz {
    final n = midi;
    return n == null ? null : 440.0 * math.pow(2, (n - 69) / 12.0);
  }
}

/// The first five bars of the chorus — "never gonna give you up …" — from the
/// widely-circulated buzzer transcription in `robsoncouto/arduino-songs`
/// (D major; the phrase lands back on the tonic, so it stops cleanly rather
/// than needing a fade). Ten and a half seconds: long enough to land the joke,
/// short enough that nobody has to sit through it.
const List<RickRollNote> kRickRollHook = [
  // "Never gonna give you up"
  RickRollNote(null, 8),
  RickRollNote(71, 8), // B4
  RickRollNote(71, 8), // B4
  RickRollNote(73, 8), // C#5
  RickRollNote(74, 8), // D5
  RickRollNote(71, 4), // B4
  RickRollNote(69, 8), // A4
  // answering figure
  RickRollNote(81, 8), // A5
  RickRollNote(null, 8),
  RickRollNote(81, 8), // A5
  RickRollNote(76, -4), // E5, dotted
  RickRollNote(null, 4),
  // "Never gonna run around and desert you"
  RickRollNote(71, 8), // B4
  RickRollNote(71, 8), // B4
  RickRollNote(73, 8), // C#5
  RickRollNote(74, 8), // D5
  RickRollNote(71, 8), // B4
  RickRollNote(74, 8), // D5
  RickRollNote(76, 8), // E5
  RickRollNote(null, 8),
  RickRollNote(null, 8),
  RickRollNote(73, 8), // C#5
  RickRollNote(71, 8), // B4
  RickRollNote(69, -4), // A4, dotted
  RickRollNote(null, 4),
  // "Never gonna make you cry"
  RickRollNote(null, 8),
  RickRollNote(71, 8), // B4
  RickRollNote(71, 8), // B4
  RickRollNote(73, 8), // C#5
  RickRollNote(74, 8), // D5
  RickRollNote(71, 8), // B4
  RickRollNote(69, 4), // A4
];

/// How long the hook runs, summed from [kRickRollHook]. The overlay shows
/// itself for exactly this long, so the picture and the sound can never
/// disagree about when the joke is over.
final Duration kRickRollHookDuration =
    kRickRollHook.fold(Duration.zero, (sum, note) => sum + note.length);

/// A handle on a running hook. `stop()` must be safe to call more than once
/// and safe to call after the tune has already finished on its own.
abstract interface class RickRollPlayback {
  void stop();
}

/// The two functions the conditional import must supply, documented here
/// because this file is the contract both implementations answer to:
///
/// * `void primeRickRollAudio()` — called once at app start. A browser will
///   not let a page make noise until the user has interacted with it, and the
///   check is stricter than "has the user ever done anything": **Safari
///   requires the audio context to be resumed inside the gesture handler
///   itself**. By the time the egg fires, the tune is started from a widget's
///   `initState`, a frame or more after the tap or keystroke that caused it —
///   outside any handler. Chrome's page-level sticky activation forgives that;
///   Safari does not, which is why the sound worked on desktop and not on a
///   phone. The unlock therefore cannot wait for the egg: it hooks the FIRST
///   real interaction with the page, where the browser is still willing.
///
/// * `RickRollPlayback playRickRollHook()` — schedules [kRickRollHook] and
///   returns a handle. Must never throw: "no sound" is an ordinary outcome.

/// The "no sound happened" answer — returned by the non-web stub and by the
/// web implementation when the browser refuses to give us an audio context.
/// The overlay treats it exactly like a successful one: the visual never
/// depends on audio, because Safari can still withhold playback even though a
/// keystroke granted user activation.
class SilentRickRollPlayback implements RickRollPlayback {
  const SilentRickRollPlayback();

  @override
  void stop() {}
}
