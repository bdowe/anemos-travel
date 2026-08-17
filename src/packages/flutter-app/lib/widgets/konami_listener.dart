import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/easter_egg_provider.dart';
import '../utils/konami_detector.dart';
import '../utils/rick_roll_audio_stub.dart'
    if (dart.library.js_interop) '../utils/rick_roll_audio_web.dart';
import 'rick_roll_overlay.dart';

/// Listens for the Konami code everywhere in the app, and hosts the overlay it
/// triggers.
///
/// Mounted from `MaterialApp.builder`, which is the only spot that covers
/// everything: it wraps the root `Navigator`, so it sees dialogs and the nine
/// screens that render outside `AppShell` (landing, auth, splash, the SSO
/// callback…) as well as the tabs.
///
/// **Why `HardwareKeyboard` and not a `Focus`.** Handlers registered with
/// `HardwareKeyboard.instance.addHandler` run in `KeyEventManager` *before*
/// the focus tree gets the event, and returning false leaves normal handling
/// completely untouched. A `Focus(onKeyEvent:)` here would sit above the
/// focused node in the bubble chain and would therefore never see arrow keys
/// while a text field has focus — and this app has text fields on 21 screens,
/// including the one people spend the most time in.
///
/// The handler **always returns false**, so it cannot swallow a keystroke from
/// anything. Note that returning true would not help even where you might want
/// it to: `KeyEventManager` dispatches to the focus tree either way, and a
/// handler's result only reports back to the engine. Dismissal keys are
/// therefore the overlay's own business — see [RickRollOverlay], which takes
/// focus and handles Escape where it can actually stop it travelling.
class KonamiListener extends ConsumerStatefulWidget {
  const KonamiListener({super.key, required this.child});

  /// The app itself — whatever `MaterialApp.builder` handed us.
  final Widget child;

  @override
  ConsumerState<KonamiListener> createState() => _KonamiListenerState();
}

class _KonamiListenerState extends ConsumerState<KonamiListener> {
  final KonamiDetector _detector = KonamiDetector();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    // Mounted from MaterialApp.builder, so this runs once at app start — the
    // earliest point that still precedes any interaction, which is the whole
    // requirement. See primeRickRollAudio: the browser will only open an audio
    // context inside a real gesture, and by the time the egg fires we are a
    // frame past one.
    primeRickRollAudio();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    // Key *down* only. Taking repeats and ups as well would mean a held arrow
    // key walks the sequence on its own.
    if (event is! KeyDownEvent) return false;

    // Keep feeding the detector while the roll is up — it costs one list
    // compare and means the buffer is never in a half-matched state when the
    // overlay goes away. roll() is a no-op if it is already running.
    if (_detector.accept(event.logicalKey)) {
      ref.read(rickRollProvider.notifier).roll();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      // Non-directional alignment and an explicit expand: this sits above the
      // Navigator, and the app must fill the window exactly as it did before
      // the Stack existed.
      fit: StackFit.expand,
      alignment: Alignment.center,
      children: [
        widget.child,
        // The overlay slot is ALWAYS present — an empty box when idle rather
        // than a conditionally-added child. Keeping the children list a fixed
        // length pins the app at index 0 forever, so triggering the egg can
        // never re-key the slot below it and remount the entire app. (An
        // unnoticed remount is exactly how the chat panel used to destroy
        // every unsaved draft on the trip page.)
        Consumer(
          builder: (context, ref, _) => ref.watch(rickRollProvider)
              ? const RickRollOverlay()
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
