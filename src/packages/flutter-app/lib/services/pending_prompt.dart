import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A landing prompt waiting on a session (specs/landing-prompt-handoff).
///
/// [sourceId] is the destination-photo slug when a rail card produced the
/// prompt, null for typed text; it feeds the consume event's `surface`
/// metadata and nothing else.
class PendingPrompt {
  final String text;
  final String? sourceId;
  final int savedAtMs;

  const PendingPrompt({
    required this.text,
    this.sourceId,
    required this.savedAtMs,
  });
}

/// Remembers the visitor's landing prompt across the sign-up round trip
/// (specs/landing-prompt-handoff), the same way [PendingConnectStore] carries
/// the connector consent request: Google/Apple sign-in navigate the whole
/// page away and come back at /sso/<code>, so every scrap of in-memory state
/// is gone by the time there is a session. SharedPreferences is localStorage
/// on web, which survives that reload.
///
/// One writer (the landing handoff), one consumer
/// (`pendingPromptResumeProvider`). One slot, last-write-wins; `take()` is
/// single-use and clears before validating, so a stale or malformed record
/// can never replay on a later sign-in.
class PendingPromptStore {
  static const _textKey = 'pending_prompt.text';
  static const _chipKey = 'pending_prompt.chip';
  static const _savedAtKey = 'pending_prompt.saved_at';

  /// No server token bounds this (unlike PendingConnect's 15 minutes), so the
  /// window only has to cover sign-up plus the onboarding quiz comfortably
  /// while making "a forgotten prompt fires days later" impossible.
  static const maxAge = Duration(minutes: 30);

  /// The one source of truth for how long a first prompt may be — the hero
  /// field's `maxLength` reads this so the input and the store can never
  /// disagree.
  static const int maxPromptLength = 2000;

  /// Write-through mirror: the email+password path never reloads the page,
  /// so the prompt survives even when device storage is unavailable (private
  /// browsing, full quota). SSO's full-page reload wipes it — prefs cover
  /// that path. Static for the same reason `LandingScreen._viewRecorded` is:
  /// the store is const-constructed at several sites but the slot is one.
  static PendingPrompt? _memory;

  /// Resets the in-memory slot so tests can isolate runs.
  @visibleForTesting
  static void resetMemoryForTest() => _memory = null;

  const PendingPromptStore();

  /// Every method swallows storage failures. Losing the prompt costs the
  /// user a retype, whereas an exception here would break the sign-up
  /// handoff itself.

  /// Records [text] (trimmed, capped at [maxPromptLength]) as waiting on a
  /// session. Call — and await — BEFORE any navigation toward auth. Empty
  /// or whitespace-only text is not stored.
  Future<void> save(String text, {String? sourceId}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    // Grapheme clusters, not code units: the hero field's maxLength counts
    // characters, and a substring cap could split a surrogate pair.
    final capped = trimmed.characters.length > maxPromptLength
        ? trimmed.characters.take(maxPromptLength).toString()
        : trimmed;
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    _memory = PendingPrompt(text: capped, sourceId: sourceId, savedAtMs: now);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_textKey, capped);
      if (sourceId != null) {
        await prefs.setString(_chipKey, sourceId);
      } else {
        await prefs.remove(_chipKey);
      }
      await prefs.setInt(_savedAtKey, now);
    } catch (_) {
      // Best effort — the memory mirror still covers the same-page paths.
    }
  }

  /// Returns the pending prompt and forgets it — storage AND mirror, before
  /// any validation, so nothing lingers after a consume attempt. Null when
  /// nothing is pending or the record aged out (both slots age-checked: a
  /// tab parked on the auth screen for an hour holds the mirror without a
  /// reload).
  Future<PendingPrompt?> take() async {
    final mirror = _memory;
    _memory = null;
    PendingPrompt? stored;
    try {
      final prefs = await SharedPreferences.getInstance();
      final text = prefs.getString(_textKey);
      final chip = prefs.getString(_chipKey);
      final savedAt = prefs.getInt(_savedAtKey);
      await clear();
      if (text != null && text.isNotEmpty && savedAt != null) {
        stored = PendingPrompt(text: text, sourceId: chip, savedAtMs: savedAt);
      }
    } catch (_) {
      // Storage unavailable — the mirror below is all we have.
    }
    final candidate = mirror ?? stored;
    if (candidate == null) return null;
    final age =
        DateTime.now().toUtc().millisecondsSinceEpoch - candidate.savedAtMs;
    if (age < 0 || age > maxAge.inMilliseconds) return null;
    return candidate;
  }

  Future<void> clear() async {
    _memory = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_textKey);
      await prefs.remove(_chipKey);
      await prefs.remove(_savedAtKey);
    } catch (_) {
      // Best effort — see the note above.
    }
  }
}
