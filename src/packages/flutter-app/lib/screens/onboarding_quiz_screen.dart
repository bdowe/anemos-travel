import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../models/airport.dart';
import '../models/traveler_preferences.dart';
import '../providers/auth_provider.dart';
import '../providers/preferences_provider.dart';
import '../theme/spacing.dart';
import '../widgets/airport_field.dart';
import '../widgets/choice_chip_row.dart';
import '../widgets/empty_state.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/interest_picker.dart';
import '../widgets/page_container.dart';
import '../widgets/section_header.dart';
import '../utils/snack.dart';

// Canonical API values. These are sent to the server (and, for companions,
// folded into the profile notes the AI agent reads), so they are NEVER
// translated — only their display labels are (specs/i18n-spanish).
const _budgets = ['budget', 'mid', 'luxury'];
const _paces = ['relaxed', 'balanced', 'packed'];
const _workStyleOptions = ['digital_nomad', 'workation', 'leisure_only'];
const _companionOptions = [
  'solo',
  'partner',
  'friends',
  'family with kids',
  'it varies'
];
const _tripsMaxLength = 500;

String _budgetLabel(AppLocalizations l10n, String value) => switch (value) {
      'budget' => l10n.prefsBudgetLow,
      'mid' => l10n.prefsBudgetMid,
      'luxury' => l10n.prefsBudgetLuxury,
      _ => value,
    };

String _paceLabel(AppLocalizations l10n, String value) => switch (value) {
      'relaxed' => l10n.prefsPaceRelaxed,
      'balanced' => l10n.prefsPaceBalanced,
      'packed' => l10n.prefsPacePacked,
      _ => value,
    };

String _workStyleLabel(AppLocalizations l10n, String value) => switch (value) {
      'digital_nomad' => l10n.prefsWorkStyleNomad,
      'workation' => l10n.prefsWorkStyleWorkation,
      'leisure_only' => l10n.prefsWorkStyleLeisure,
      _ => value,
    };


String _companionLabel(AppLocalizations l10n, String value) => switch (value) {
      'solo' => l10n.quizCompanionSolo,
      'partner' => l10n.quizCompanionPartner,
      'friends' => l10n.quizCompanionFriends,
      'family with kids' => l10n.quizCompanionFamily,
      'it varies' => l10n.quizCompanionVaries,
      _ => value,
    };

/// Formats the quiz's free-form answers as profile-notes bullet lines, using
/// the same short-bullet convention the AI profile distiller maintains so the
/// two sources merge cleanly. Returns '' when there is nothing to note.
String buildOnboardingProfileNotes(
    {String? companions, required String tripsInMind}) {
  final lines = <String>[];
  if (companions != null && companions.isNotEmpty) {
    lines.add('- Travels with: $companions');
  }
  final trips = tripsInMind.trim();
  if (trips.isNotEmpty) {
    lines.add(
        '- Trips in mind: ${trips.replaceAll(RegExp(r'\s*\n+\s*'), '; ')}');
  }
  return lines.join('\n');
}

/// One-time signup quiz that seeds the traveler profile. Rendered by AuthGate
/// (instead of the app shell) while the signed-in user still owes onboarding —
/// completion/skip flips auth state, which swaps this screen out. Every
/// question is optional and Skip is always available; this screen must only be
/// shown to brand-new users (it replaces profile notes wholesale).
class OnboardingQuizScreen extends ConsumerStatefulWidget {
  /// When true the quiz was pushed as a profile "retake" (account menu)
  /// rather than shown by AuthGate at signup: finishing pops back instead of
  /// relying on AuthGate to swap the screen, and Skip just leaves.
  final bool retake;

  const OnboardingQuizScreen({super.key, this.retake = false});

  @override
  ConsumerState<OnboardingQuizScreen> createState() =>
      _OnboardingQuizScreenState();
}

class _OnboardingQuizScreenState extends ConsumerState<OnboardingQuizScreen> {
  static const _stepCount = 6;

  final _pageController = PageController();
  int _step = 0;
  bool _submitting = false;
  bool _seededFromPrefs = false;

  String? _budget;
  String? _pace;
  String? _workStyle;
  final Set<String> _interests = {};
  String? _companions;

  @override
  void initState() {
    super.initState();
    // A retake edits the EXISTING profile: seed the form from saved
    // preferences so an untouched step keeps its values instead of wiping
    // them (save() sends interests as provided-including-empty).
    if (widget.retake) {
      final prefs = ref.read(preferencesProvider).prefs;
      if (prefs != null) {
        _seedFrom(prefs);
      } else {
        // After the first frame: load() mutates the provider synchronously,
        // which Riverpod forbids while the widget tree is still building.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) ref.read(preferencesProvider.notifier).load();
        });
      }
    }
  }

  void _seedFrom(TravelerPreferences prefs) {
    _seededFromPrefs = true;
    _budget = prefs.budget;
    _pace = prefs.pace;
    _workStyle = prefs.workStyle;
    _interests.addAll(prefs.interests);
    final home = prefs.homeAirport;
    if (home != null && home.isNotEmpty) {
      _homeAirport = Airport(iataCode: home, name: home);
    }
  }

  Airport? _homeAirport;
  final _tripsController = TextEditingController();

  @override
  void dispose() {
    _pageController.dispose();
    _tripsController.dispose();
    super.dispose();
  }

  void _goTo(int step) {
    setState(() => _step = step);
    _pageController.animateToPage(
      step,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _skip() async {
    if (widget.retake) {
      Navigator.of(context).pop();
      return;
    }
    if (_submitting) return;
    setState(() => _submitting = true);
    await ref.read(authProvider.notifier).completeOnboarding();
    // No setState after: completing onboarding swaps this screen out via
    // AuthGate, and the local-unlock fallback means it always succeeds.
  }

  Future<void> _finish() async {
    if (_submitting) return;
    final l10n = context.l10n;
    setState(() => _submitting = true);
    final notes = buildOnboardingProfileNotes(
      companions: _companions,
      tripsInMind: _tripsController.text,
    );
    final ok = await ref.read(preferencesProvider.notifier).save(
          budget: _budget,
          pace: _pace,
          workStyle: _workStyle,
          interests: _interests.toList(),
          homeAirport: _homeAirport?.iataCode,
          // null keeps notes untouched (they're empty for a brand-new user).
          // A retake NEVER writes notes: the accumulated AI-distilled profile
          // must not be replaced by one or two quiz bullets.
          profileNotes: widget.retake || notes.isEmpty ? null : notes,
        );
    if (!ok) {
      if (!mounted) return;
      setState(() => _submitting = false);
      showSnack(context, l10n.quizSaveFailed);
      return;
    }
    if (widget.retake) {
      if (!mounted) return;
      Navigator.of(context).pop();
      showSnack(context, l10n.quizProfileUpdated);
      return;
    }
    await ref.read(authProvider.notifier).completeOnboarding();
  }

  @override
  Widget build(BuildContext context) {
    // Retake with preferences still loading at initState: seed once they land.
    // A load that completes with a legitimately-empty profile still has a
    // non-null prefs object, so seeding it releases the gate below too.
    if (widget.retake && !_seededFromPrefs) {
      ref.listen(preferencesProvider, (prev, next) {
        if (_seededFromPrefs) return;
        final prefs = next.prefs;
        if (prefs != null) {
          setState(() => _seedFrom(prefs));
        } else if (!next.loading && next.error == null) {
          // Defensive: the load settled with nothing to seed — release the
          // gate rather than spin forever.
          setState(() => _seededFromPrefs = true);
        }
      });
    }
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final isLast = _step == _stepCount - 1;

    return PopScope(
      // The system back gesture steps to the previous question instead of
      // tearing down the quiz and discarding the answers (swipe between steps
      // stays disabled on purpose — the PageView gates progression).
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_submitting) _goTo(_step - 1);
      },
      child: Scaffold(
        appBar: GradientAppBar(
          title: Text(l10n.quizTitle),
          actions: [
            TextButton(
              onPressed: _submitting ? null : _skip,
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              child: Text(l10n.quizSkip),
            ),
          ],
        ),
        body: SafeArea(
          child: PageContainer(
            child: _buildBody(theme, l10n, isLast),
          ),
        ),
      ),
    );
  }

  /// Body of the quiz. While a retake is still waiting for the saved profile,
  /// this is a deliberate loading/error gate instead of the form: _finish()
  /// sends the CURRENT answers as the whole profile, so rendering the form
  /// unseeded would let a fast tap-through silently wipe saved preferences.
  Widget _buildBody(ThemeData theme, AppLocalizations l10n, bool isLast) {
    if (widget.retake && !_seededFromPrefs) {
      final prefsState = ref.watch(preferencesProvider);
      if (prefsState.error != null) {
        // Fixed copy — never the raw provider error string.
        return EmptyState(
          icon: Icons.cloud_off,
          title: l10n.quizLoadErrorTitle,
          message: l10n.quizLoadErrorBody,
          actions: [
            FilledButton.icon(
              onPressed: () => ref.read(preferencesProvider.notifier).load(),
              icon: const Icon(Icons.refresh),
              label: Text(l10n.commonRetry),
            ),
          ],
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Expanded(
          child: PageView(
            controller: _pageController,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _buildStep(
                title: l10n.quizStyleTitle,
                subtitle: l10n.quizStyleSubtitle,
                children: [
                  SectionHeader(title: l10n.prefsBudget),
                  const SizedBox(height: AppSpacing.sm),
                  ChoiceChipRow(
                    options: _budgets,
                    selected: _budget,
                    onSelected: (v) => setState(() => _budget = v),
                    labelBuilder: (v) => _budgetLabel(l10n, v),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  SectionHeader(title: l10n.prefsPace),
                  const SizedBox(height: AppSpacing.sm),
                  ChoiceChipRow(
                    options: _paces,
                    selected: _pace,
                    onSelected: (v) => setState(() => _pace = v),
                    labelBuilder: (v) => _paceLabel(l10n, v),
                  ),
                ],
              ),
              _buildStep(
                title: l10n.quizWorkStyleTitle,
                subtitle: l10n.quizWorkStyleSubtitle,
                children: [
                  ChoiceChipRow(
                    options: _workStyleOptions,
                    selected: _workStyle,
                    onSelected: (v) => setState(() => _workStyle = v),
                    labelBuilder: (v) => _workStyleLabel(l10n, v),
                  ),
                ],
              ),
              _buildStep(
                title: l10n.quizInterestsTitle,
                subtitle: l10n.quizInterestsSubtitle,
                children: [
                  InterestPicker(
                    selected: _interests,
                    onChanged: (next) => setState(
                      () => _interests
                        ..clear()
                        ..addAll(next),
                    ),
                  ),
                ],
              ),
              _buildStep(
                title: l10n.quizCompanionsTitle,
                children: [
                  ChoiceChipRow(
                    options: _companionOptions,
                    selected: _companions,
                    onSelected: (v) => setState(() => _companions = v),
                    labelBuilder: (v) => _companionLabel(l10n, v),
                  ),
                ],
              ),
              _buildStep(
                title: l10n.quizHomeAirportTitle,
                subtitle: l10n.prefsHomeAirportHelp,
                children: [
                  AirportField(
                    label: l10n.prefsHomeAirport,
                    icon: Icons.home,
                    selected: _homeAirport,
                    onSelected: (a) => setState(() => _homeAirport = a),
                  ),
                ],
              ),
              _buildStep(
                title: l10n.quizTripsTitle,
                subtitle: l10n.quizTripsSubtitle,
                children: [
                  TextField(
                    controller: _tripsController,
                    maxLines: 4,
                    maxLength: _tripsMaxLength,
                    // No border override: inherit the app's themed
                    // OutlineInputBorder (rounded corners).
                    decoration: InputDecoration(
                      hintText: l10n.quizTripsHint,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          // Flexible buttons: the Spacers collapse first, then the
          // labels ellipsize, so long Spanish labels at large text
          // scales never overflow the footer at 320px.
          child: Row(
            children: [
              if (_step > 0)
                Flexible(
                  child: TextButton(
                    onPressed: _submitting ? null : () => _goTo(_step - 1),
                    child: Text(
                      l10n.commonBack,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              const Spacer(),
              _StepDots(count: _stepCount, current: _step),
              const Spacer(),
              Flexible(
                child: FilledButton(
                  onPressed: _submitting
                      ? null
                      : () => isLast ? _finish() : _goTo(_step + 1),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xl,
                      vertical: AppSpacing.md,
                    ),
                  ),
                  child: _submitting
                      ? SizedBox(
                          height: 20,
                          width: 20,
                          // onPrimary, so the spinner is visible on the
                          // filled (primary) button surface.
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.onPrimary,
                          ),
                        )
                      : Text(
                          isLast ? l10n.quizFinish : l10n.commonNext,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStep({
    required String title,
    String? subtitle,
    required List<Widget> children,
  }) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        const SizedBox(height: AppSpacing.sm),
        Text(title, style: theme.textTheme.headlineSmall),
        if (subtitle != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            subtitle,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.xl),
        ...children,
      ],
    );
  }
}

class _StepDots extends StatelessWidget {
  final int count;
  final int current;

  const _StepDots({required this.count, required this.current});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = context.l10n.quizStepOf(current + 1, count);
    // One combined semantics node: the dots are decorative; position is both
    // announced and visibly captioned as "Step n of total".
    return Semantics(
      container: true,
      label: label,
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(count, (i) {
                return Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color:
                        i == current ? scheme.primary : scheme.outlineVariant,
                  ),
                );
              }),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
