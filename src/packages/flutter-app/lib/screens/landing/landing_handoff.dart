import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../navigation/app_nav.dart';
import '../../providers/auth_provider.dart';
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
/// plumbing so widget tests can override it to record calls, and so the
/// handoff lane replaces exactly one default.
final landingPromptHandoffProvider =
    Provider<LandingPromptHandoff>((ref) => _defaultHandoff);

// TODO(specs/landing-prompt-handoff): persist the prompt BEFORE navigation
// (it must survive the SSO full-page reload) and seed the first chat after
// auth. Until that lane lands, this degrades to the plain sign-up path and
// the prompt is dropped.
void _defaultHandoff(BuildContext context, String prompt, {String? sourceId}) {
  // Same warm-up + push as the landing page's plain CTAs, so the two entry
  // styles can't drift apart while the handoff lane is in flight.
  warmSsoAvailability(context);
  pushOnce(
    context,
    MaterialPageRoute(builder: (_) => AuthScreen(initialIsLogin: false)),
  );
}
