import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the Konami code is currently rolling the site.
///
/// A provider rather than local state in the listener widget for one reason
/// that matters: it is the seam tests drive. The overlay lives in
/// `MaterialApp.builder`, above every route, so there is no screen to pump on
/// its own — a test either sends ten keystrokes or flips this.
class RickRollNotifier extends StateNotifier<bool> {
  RickRollNotifier() : super(false);

  /// Starts the roll. Entering the code again while it is already running is
  /// a no-op rather than a restart: re-triggering would tear down the audio
  /// context mid-phrase and re-attack the tune from bar one.
  void roll() {
    if (!state) state = true;
  }

  /// Ends the roll — Escape, a tap, the close button, or the tune running out.
  void stop() {
    if (state) state = false;
  }
}

final rickRollProvider = StateNotifierProvider<RickRollNotifier, bool>(
  (ref) => RickRollNotifier(),
);
