import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/secret_tap_counter.dart';

/// Whether the easter egg is currently rolling the site, and the two ways in.
///
/// A provider rather than local state in the listener widget for one reason
/// that matters: it is the seam tests drive. The overlay lives in
/// `MaterialApp.builder`, above every route, so there is no screen to pump on
/// its own — a test either sends ten keystrokes or flips this.
///
/// The tap counter lives here rather than in the app bar because **the app bar
/// is rebuilt constantly** — every screen constructs its own `GradientAppBar`,
/// and navigating rebuilds it. A counter held in that widget would reset
/// halfway through the gesture. This notifier is app-scoped, so a burst of
/// taps survives whatever the taps themselves make the app do.
class RickRollNotifier extends StateNotifier<bool> {
  RickRollNotifier({DateTime Function()? now})
      : _now = now ?? DateTime.now,
        super(false);

  /// The clock, injectable so a test can state the gaps it means rather than
  /// racing a real one.
  final DateTime Function() _now;

  final SecretTapCounter _taps = SecretTapCounter();

  /// Starts the roll. Entering the code again while it is already running is
  /// a no-op rather than a restart: re-triggering would tear down the audio
  /// context mid-phrase and re-attack the tune from bar one.
  void roll() {
    if (!state) state = true;
  }

  /// The brand was tapped. Rolls the site on the seventh in quick succession
  /// — the touch way in, for the phones that cannot enter a Konami code
  /// because they have no arrow keys.
  ///
  /// This never consumes or replaces the tap: the brand still navigates home
  /// exactly as before, and on the screens where it does nothing at all
  /// (landing, auth) this is the only thing listening. Counting is
  /// unconditional for the same reason the key detector is — a caller that
  /// had to know whether it was on a touch device would be a caller that can
  /// get it wrong.
  void brandTapped() {
    if (_taps.tap(_now())) roll();
  }

  /// Ends the roll — Escape, a tap, the close button, or the tune running out.
  void stop() {
    if (state) state = false;
  }
}

final rickRollProvider = StateNotifierProvider<RickRollNotifier, bool>(
  (ref) => RickRollNotifier(),
);
