import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/suggestions_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../theme/spacing.dart';
import '../../widgets/random_suggestions.dart';
import 'landing_handoff.dart';

/// The hero prompt field caps input at the handoff store's limit so the two
/// can never disagree about how long a first prompt may be
/// (specs/landing-prompt-handoff).
const int kLandingPromptMaxLength = 2000;

/// Full-bleed landing hero: the Santorini photo dissolving into the landing
/// canvas, a Marcellus headline, and a REAL prompt input — the product's
/// first interaction, not a description of it.
///
/// No logo or wordmark in here: the `GradientAppBar` above already carries
/// the full lockup on the landing page (the brand *is* the bar's title), and
/// the old hero made the page brand three times. This also keeps the Konami
/// rule structural — the only brand tap target is the bar's.
class LandingHero extends ConsumerStatefulWidget {
  /// "I already have an account" — stays on the plain sign-in path.
  final VoidCallback onSignIn;

  const LandingHero({super.key, required this.onSignIn});

  @override
  ConsumerState<LandingHero> createState() => _LandingHeroState();
}

class _LandingHeroState extends ConsumerState<LandingHero> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    ref.read(landingPromptHandoffProvider)(context, text);
  }

  /// Chips prefill rather than submit: they are suggestions, and the
  /// visitor's first submit should be their own act — in the field or on a
  /// destination card.
  void _prefill(String text) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final media = MediaQuery.sizeOf(context);

    return LayoutBuilder(builder: (context, constraints) {
      // The hero measures its own box, not the window: below ~600px the type
      // scale and spacing tighten so the 320x568 fold contract (headline +
      // field + submit above the fold) holds.
      final narrow = constraints.maxWidth < 600;
      final minHeight =
          narrow ? 0.0 : (media.height * 0.62).clamp(520.0, 680.0);

      return Stack(
        children: [
          // Branded gradient behind the photo: visible until the image
          // decodes and whenever it fails to load, so the white copy always
          // sits on a dark branded surface.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: AppColors.brandGradient),
            ),
          ),
          Positioned.fill(
            child: Image.asset(
              'assets/images/hero_santorini.jpg',
              fit: BoxFit.cover,
              // Decorative: the headline carries the message.
              excludeFromSemantics: true,
              // Bound the decode to the viewport; the source is 1600px wide.
              cacheWidth: math.min(
                1600,
                (media.width * MediaQuery.devicePixelRatioOf(context)).round(),
              ),
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                if (wasSynchronouslyLoaded) return child;
                return AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                  child: child,
                );
              },
              // The gradient underneath is the fallback.
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: AppColors.heroScrim),
            ),
          ),
          // Dissolve the photo's bottom edge into the page canvas.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 120,
            child: DecoratedBox(
              decoration:
                  BoxDecoration(gradient: AppColors.landingHeroBlend),
            ),
          ),
          Container(
            constraints: BoxConstraints(minHeight: minHeight),
            padding: EdgeInsets.symmetric(
              horizontal: narrow ? AppSpacing.lg : AppSpacing.xl,
              vertical: narrow ? AppSpacing.xl : AppSpacing.xl + AppSpacing.sm,
            ),
            alignment: Alignment.center,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    l10n.landingHeroHeadline,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      // Marcellus ships only w400; 48 on desktop is a
                      // deliberate display step above headlineLarge (34) —
                      // stated locally because nothing else needs the tier.
                      fontFamily: AppFonts.display,
                      fontWeight: FontWeight.w400,
                      fontSize: narrow ? 34 : 48,
                      height: 1.15,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    l10n.landingHeroSubtitle,
                    textAlign: TextAlign.center,
                    maxLines: narrow ? 2 : null,
                    overflow: narrow ? TextOverflow.ellipsis : null,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: _promptField(l10n),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _suggestionChips(theme),
                  const SizedBox(height: AppSpacing.sm),
                  TextButton(
                    onPressed: widget.onSignIn,
                    style:
                        TextButton.styleFrom(foregroundColor: Colors.white),
                    child: Text(l10n.landingHaveAccount),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    });
  }

  Widget _promptField(AppLocalizations l10n) {
    // Locally decorated dark-glass field, deliberately overriding the app
    // InputDecorationTheme: this input sits on a photo, not a surface.
    return TextField(
      key: const Key('landing-prompt-input'),
      controller: _controller,
      focusNode: _focusNode,
      maxLength: kLandingPromptMaxLength,
      textInputAction: TextInputAction.go,
      onSubmitted: (_) => _submit(),
      style: const TextStyle(color: Colors.white),
      cursorColor: Colors.white,
      decoration: InputDecoration(
        counterText: '', // maxLength guard only — no visible counter.
        hintText: l10n.landingPromptHint,
        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.10),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.lg,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.lgAll,
          borderSide: BorderSide(color: AppColors.landingHairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.lgAll,
          borderSide: BorderSide(
            color: Colors.white.withValues(alpha: 0.7),
            width: 2,
          ),
        ),
        suffixIcon: Padding(
          padding: const EdgeInsets.only(right: AppSpacing.xs),
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) {
              final enabled = _controller.text.trim().isNotEmpty;
              return IconButton(
                key: const Key('landing-prompt-submit'),
                tooltip: l10n.landingPromptSubmit,
                onPressed: enabled ? _submit : null,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppColors.brandDark,
                  disabledBackgroundColor:
                      Colors.white.withValues(alpha: 0.35),
                  disabledForegroundColor:
                      AppColors.brandDark.withValues(alpha: 0.6),
                ),
                icon: const Icon(Icons.arrow_forward),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _suggestionChips(ThemeData theme) {
    return RandomSuggestions(
      // A sample, not the pool: three static chips under the field; the
      // destination rail below shows the full range.
      picker: suggestionPickerProvider,
      builder: (context, prompts) => Wrap(
        alignment: WrapAlignment.center,
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: [
          // Translucent, deliberately not the home hero's solid-white chips:
          // there a chip SENDS; here it only prefills the field.
          for (final s in prompts)
            ActionChip(
              key: ValueKey('landing-chip-${s.text}'),
              label: Text(
                s.text,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
              backgroundColor: Colors.white.withValues(alpha: 0.12),
              side: BorderSide(color: AppColors.landingHairline),
              onPressed: () => _prefill(s.text),
            ),
        ],
      ),
    );
  }
}
