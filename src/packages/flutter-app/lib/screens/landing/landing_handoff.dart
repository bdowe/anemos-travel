import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../navigation/app_nav.dart';
import '../../providers/analytics_provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/analytics_api_service.dart';
import '../../services/pending_prompt.dart';
import '../auth_screen.dart';

/// What the landing page does with a visitor's first prompt: the hero's
/// submit and the destination rail's card taps both call this.
///
/// [sourceId] names the suggestion that produced the prompt (the destination
/// photo slug) or is null for typed text — carried for the handoff lane's
/// analytics, unused by the default.
typedef LandingPromptHandoff = void Function(
  BuildContext context,
  String prompt, {
  String? sourceId,
});

/// Seam between the landing page UI and the prompt→sign-up→chat handoff
/// (specs/landing-prompt-handoff). A provider rather than constructor
/// plumbing so widget tests can override it to record calls.
final landingPromptHandoffProvider =
    Provider<LandingPromptHandoff>((ref) => _defaultHandoff);

/// The real handoff: persist the prompt BEFORE any navigation — SSO is a
/// full-page reload and in-memory state dies (the PendingConnectStore rule,
/// connect_app_screen.dart) — then continue into sign-up exactly like the
/// plain CTAs. `pendingPromptResumeProvider` consumes the store once the
/// session is signed in and onboarded.
Future<void> _defaultHandoff(BuildContext context, String prompt,
    {String? sourceId}) async {
  // Container read BEFORE the await (no context across the async gap).
  AnalyticsApiService? analytics;
  try {
    analytics = ProviderScope.containerOf(context, listen: false)
        .read(analyticsApiServiceProvider);
  } catch (_) {}
  await const PendingPromptStore().save(prompt, sourceId: sourceId);
  try {
    // Fire-and-forget, and never allowed to break the handoff — the same
    // stance as the landing_viewed guard. The prompt TEXT never rides
    // analytics; only which surface produced it.
    analytics?.recordLandingPromptSubmitted(
        surface: sourceId == null ? 'hero' : 'card', kind: sourceId);
  } catch (_) {}
  if (!context.mounted) return;
  warmSsoAvailability(context);
  pushOnce(
    context,
    MaterialPageRoute(builder: (_) => AuthScreen(initialIsLogin: false)),
  );
}
