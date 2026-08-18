import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../navigation/app_nav.dart';
import '../navigation/url_sync.dart';
import '../services/pending_connect.dart';
import '../services/pending_prompt.dart';
import 'analytics_provider.dart';
import 'auth_provider.dart';
import 'plan_provider.dart';

/// The ONE consume point for a landing prompt (specs/landing-prompt-handoff),
/// modeled on [urlSyncProvider]'s boot-target consumption: alive from the
/// first frame (watched in `TravelRoutePlannerApp.build`), so it hears the
/// auth transition on every path — email sign-up finishing the quiz, the SSO
/// return landing on the bare /sso route, plain sign-in, and a cold boot
/// with a stored session — with zero changes to AuthScreen or the SSO
/// callback screen.
final pendingPromptResumeProvider = Provider<PendingPromptResume>((ref) {
  final resume = PendingPromptResume(ref);
  ref.listen(authProvider, (_, next) => resume.maybeConsume(next));
  // Cold boot with an already-eligible session: the listener never fires, so
  // check once outside the build phase (registerBootTarget's idiom).
  WidgetsBinding.instance.addPostFrameCallback(
      (_) => resume.maybeConsume(ref.read(authProvider)));
  return resume;
});

class PendingPromptResume {
  PendingPromptResume(this._ref, {PendingPromptStore? store})
      : _store = store ?? const PendingPromptStore();

  final Ref _ref;
  final PendingPromptStore _store;

  /// Guards the async window between eligibility and the store's own
  /// single-use clear — two rapid auth transitions must not both read the
  /// slot. Reset afterwards: a sign-out → new landing submit → sign-in
  /// cycle within one app run consumes again (the store being empty is what
  /// makes an already-consumed prompt a no-op, not this flag).
  bool _consuming = false;

  Future<void> maybeConsume(AuthState auth) async {
    if (_consuming) return;
    // Strictly after onboarding: the quiz seeds the traveler profile that
    // makes the first plan good, and Skip flips the same flag — mirrors the
    // boot-target rule ("finish the quiz, then land").
    if (!auth.initialized || !auth.isSignedIn) return;
    if (auth.user!.needsOnboarding) return;
    _consuming = true;
    try {
      // Defer behind an active connector-consent flow: it ends in a
      // full-page redirect to the external client, which would strand a
      // prompt consumed now. The prompt stays stored; the next sign-in (or
      // the 30-min expiry) settles it.
      if (await const PendingConnectStore().hasPending()) return;
      final pending = await _store.take();
      if (pending == null) return;

      // Prefill, never auto-send: minutes separate the landing intent from
      // this moment, and the user should review before the first turn. The
      // ChatPanel's external-draft listener applies this to a mounted
      // composer too; an unmounted one restores it on mount. (Auto-send
      // later = swap this write for planProvider.notifier.sendMessage.)
      _ref
          .read(chatDraftProvider(chatDraftKeyFor(null)).notifier)
          .setText(pending.text);

      // A deep-linked destination the user explicitly requested keeps the
      // tab; the draft still waits on the Plan tab either way.
      if (!_ref.read(urlSyncProvider).bootTargetSeen) {
        _ref.read(navIndexProvider.notifier).state = AppTab.plan.index;
      }

      try {
        _ref.read(analyticsApiServiceProvider).recordPendingPromptConsumed(
            surface: pending.sourceId == null ? 'hero' : 'card');
      } catch (_) {
        // Tracking must never affect the handoff.
      }
    } finally {
      _consuming = false;
    }
  }
}
