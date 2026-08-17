/// How many taps in a row open the easter egg on a device with no keyboard.
///
/// Seven, because that is the number Android's "tap the build number" gesture
/// taught everyone. Fewer would be reachable by an impatient traveler tapping
/// the logo to get home.
const int kSecretTapCount = 7;

/// How long a tap stays "part of the same burst". Measured between
/// *consecutive* taps, not across the whole run, so the gesture stays
/// achievable for someone who is not especially quick without ever
/// accumulating across the minutes of ordinary navigation taps a session
/// contains.
///
/// **This was 700 ms and that was too strict to use.** It shipped verified
/// only by automation that tapped every 145 ms — five times faster than the
/// limit — so the boundary was never near. A person tapping at a natural
/// once-a-second pace, and especially one pausing to see whether anything is
/// happening, overruns it and silently restarts at one every time. The gesture
/// gives no feedback, so an overrun is indistinguishable from a feature that
/// does not exist, which is exactly how it was reported.
///
/// Two seconds is still far too short to accumulate by accident: it needs
/// SEVEN consecutive taps inside it, and ordinary navigation taps on the brand
/// are seconds or minutes apart. When changing this, test at the boundary —
/// the useful measurement is the slowest cadence that still fires, not the
/// fastest.
const Duration kSecretTapWindow = Duration(seconds: 2);

/// Counts taps arriving in rapid succession — the touch counterpart to
/// [KonamiDetector], and pure for the same reason: the interesting cases are
/// about timing, which is miserable to drive through a widget pump but trivial
/// to state directly.
///
/// The clock is a parameter rather than a call to `DateTime.now()` inside, so
/// a test can state the gaps it means instead of hoping the machine is fast.
class SecretTapCounter {
  DateTime? _last;
  int _count = 0;

  /// Records a tap at [now] and reports whether it was the one that completed
  /// the run.
  ///
  /// A tap that arrives more than [kSecretTapWindow] after the previous one
  /// does not merely fail — it *restarts* the count at one, so the slow tap is
  /// treated as the beginning of a fresh burst rather than being thrown away.
  /// Without that, seven deliberate taps following one stray earlier tap would
  /// need an eighth.
  bool tap(DateTime now) {
    final last = _last;
    _count = (last != null && now.difference(last) <= kSecretTapWindow)
        ? _count + 1
        : 1;
    _last = now;
    if (_count >= kSecretTapCount) {
      // Reset rather than leaving the counter at the threshold, so the next
      // tap cannot fire it a second time.
      _count = 0;
      _last = null;
      return true;
    }
    return false;
  }
}
