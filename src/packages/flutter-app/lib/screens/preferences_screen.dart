import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/airport.dart';
import '../widgets/airport_field.dart';
import '../widgets/empty_state.dart';
import '../widgets/page_container.dart';
import '../widgets/choice_chip_row.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/interest_picker.dart';
import '../constants/travel_profile_options.dart';
import '../l10n/l10n.dart';
import '../providers/preferences_provider.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../utils/snack.dart';

// Canonical API values. These are sent to the server and read by the AI agent,
// so they are NEVER translated — only their display labels are
// (specs/i18n-spanish).
const _budgets = ['budget', 'mid', 'luxury'];
const _paces = ['relaxed', 'balanced', 'packed'];
const _workStyles = ['digital_nomad', 'workation', 'leisure_only'];

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

/// Fixed label column for a two-column field row inside a section card.
/// Measured against the longest row label at Inter 14/w600 — es
/// "Con qué equipaje vuelas" ≈ 170px — so every label sits on one line.
const double _kRowLabelWidth = 180;

/// A field row goes label-left only while the control column keeps room for
/// the longest single chip (es "moderado: rutas de medio día" ≈ 300px):
/// 540 − 180 label − 16 gap = 344. Below this the row stacks.
const double _kRowTwoColMin = 540;

class PreferencesScreen extends ConsumerStatefulWidget {
  const PreferencesScreen({super.key});

  @override
  ConsumerState<PreferencesScreen> createState() => _PreferencesScreenState();
}

class _PreferencesScreenState extends ConsumerState<PreferencesScreen> {
  String? _budget;
  String? _pace;
  String? _workStyle;
  String? _companions;
  String? _fitnessRoutine;
  String? _outdoorIntensity;
  String? _baggage;
  final Set<String> _interests = {};
  Airport? _homeAirport;

  /// Mirror of the airport field's raw text. `_homeAirport == null` is two
  /// different states — "no home airport" and "typed something, never picked
  /// it" — and only this tells them apart. Saving the second as the first is
  /// what used to discard an edit under a "Preferences saved" toast.
  String _homeAirportText = '';
  String? _homeAirportError;

  bool get _homeAirportUnresolved =>
      _homeAirport == null && _homeAirportText.trim().isNotEmpty;
  final _notesController = TextEditingController();

  /// Anchors the airport field so a refused save can scroll its complaint into
  /// view: Save now lives in a pinned bar, so the field may be far off-screen
  /// when the error text appears under it.
  final _airportFieldKey = GlobalKey();
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// Loads the server profile and seeds the form. `_initialized` is only set
  /// on a successful load: because Save is a full PUT of every field, a failed
  /// GET must never reach the form, or saving the resulting blank form would
  /// silently wipe the traveler's real server-side profile. On failure the
  /// build stays on the error branch, whose Retry re-runs this.
  Future<void> _load() async {
    await ref.read(preferencesProvider.notifier).load();
    if (!mounted) return;
    final state = ref.read(preferencesProvider);
    if (state.error != null) return;
    final prefs = state.prefs;
    setState(() {
      if (prefs != null) {
        _budget = prefs.budget;
        _pace = prefs.pace;
        _workStyle = prefs.workStyle;
        _companions = prefs.companions;
        _fitnessRoutine = prefs.fitnessRoutine;
        _outdoorIntensity = prefs.outdoorIntensity;
        _baggage = prefs.baggage;
        _interests.addAll(prefs.interests);
        _seedHomeAirport(prefs.homeAirport);
        _notesController.text = prefs.profileNotes ?? '';
      }
      _initialized = true;
    });
  }

  /// Seeds (or re-seeds) the airport field from a server value. Call inside a
  /// setState. An absent code resets the field rather than leaving the previous
  /// one on screen — after a clear, the form has to show what was actually
  /// stored, not what the user hoped for.
  void _seedHomeAirport(String? code) {
    if (code != null && code.isNotEmpty) {
      _homeAirport = Airport(iataCode: code, name: code);
      _homeAirportText = _homeAirport!.label;
    } else {
      _homeAirport = null;
      _homeAirportText = '';
    }
    _homeAirportError = null;
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    // An unresolved airport edit is refused rather than dropped. Sending it as
    // "no change" would return 200 with the old code still stored, and the user
    // would get "Preferences saved" for an edit that never happened.
    if (_homeAirportUnresolved) {
      setState(() => _homeAirportError = context.l10n.prefsHomeAirportPickOne);
      // Save sits in the pinned bar; the field (and its new error text) can be
      // a full viewport away. Bring the complaint to the eye.
      final ctx = _airportFieldKey.currentContext;
      if (ctx != null) {
        await Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 300),
          alignment: 0.3,
        );
      }
      return;
    }
    final ok = await ref.read(preferencesProvider.notifier).save(
          budget: _budget,
          pace: _pace,
          workStyle: _workStyle,
          companions: _companions,
          fitnessRoutine: _fitnessRoutine,
          outdoorIntensity: _outdoorIntensity,
          baggage: _baggage,
          interests: _interests.toList(),
          // "" is an explicit clear, not an omission — null would be COALESCEd
          // back to the stored code, making a home airport unremovable.
          homeAirport: _homeAirport?.iataCode ?? '',
          // Always send the field's text: an emptied field clears the notes.
          profileNotes: _notesController.text.trim(),
        );
    if (!mounted) return;
    if (ok) {
      // Re-seed from what the server actually stored, so the form shows the
      // post-state rather than a hopeful local one (docs/zen.md).
      setState(
          () => _seedHomeAirport(ref.read(preferencesProvider).prefs?.homeAirport));
    }
    showSnack(
        context, ok ? context.l10n.prefsSaved : context.l10n.prefsSaveFailed);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final state = ref.watch(preferencesProvider);
    final scheme = theme.colorScheme;

    final Widget body;
    Widget? saveBar;
    if (!_initialized && state.error != null) {
      // The load failed and the form was never seeded. Keep Save unreachable:
      // saving a blank form is a full PUT that would wipe the server profile.
      body = EmptyState(
        icon: Icons.cloud_off,
        title: l10n.prefsLoadErrorTitle,
        message: l10n.prefsLoadErrorMessage,
        iconColor: scheme.error.withValues(alpha: 0.6),
        actions: [
          FilledButton(
            onPressed: _load,
            child: Text(l10n.commonRetry),
          ),
        ],
      );
    } else if (!_initialized) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      final isDark = theme.brightness == Brightness.dark;
      // Page-scoped chip restyle, the DESIGN.md chip anatomy verbatim:
      // selected takes the brand tint family, unselected sits quiet behind an
      // outlineVariant hairline. Scoped as an inherited theme rather than an
      // edit to ChoiceChipRow/InterestPicker — those are shared with the
      // onboarding quiz and flight search, and restyling them here would
      // redesign three other screens blind.
      final selectedFill =
          isDark ? scheme.primaryContainer : AppColors.brandTint;
      final selectedInk =
          isDark ? scheme.onPrimaryContainer : AppColors.brandDark;
      final chipTheme = theme.chipTheme.copyWith(
        selectedColor: selectedFill,
        checkmarkColor: selectedInk,
        // Merged over the M3 defaults, so size stays labelLarge's; chips
        // resolve a WidgetStateColor against their own selected state.
        labelStyle: TextStyle(
          fontWeight: FontWeight.w500,
          color: WidgetStateColor.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? selectedInk
                : scheme.onSurfaceVariant,
          ),
        ),
        side: WidgetStateBorderSide.resolveWith(
          (states) => states.contains(WidgetState.selected)
              // Border matches the fill: selected chips read as solid tint.
              ? BorderSide(color: selectedFill)
              : BorderSide(color: scheme.outlineVariant),
        ),
      );

      body = Theme(
        data: theme.copyWith(chipTheme: chipTheme),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xl),
          children: [
            // Centered 700px column on wide layouts (declutter series);
            // the ListView stays full-width so wheel/scrollbar work in
            // the gutters.
            PageContainer(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.prefsIntro,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  // The agent's running notes lead the page: they are the one
                  // thing here no other travel product has, and the section
                  // most worth a returning traveler's glance. Attention comes
                  // from position, not from a colored field.
                  _Section(
                    icon: Icons.auto_awesome,
                    title: l10n.prefsProfileNotes,
                    help: l10n.prefsProfileNotesHelp,
                    child: TextField(
                      controller: _notesController,
                      maxLines: 6,
                      maxLength: 2000,
                      decoration: InputDecoration(
                        hintText: l10n.prefsProfileNotesHint,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                  _Section(
                    title: l10n.prefsSectionStyle,
                    help: l10n.prefsSectionStyleHelp,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _PrefRow(
                          label: l10n.prefsBudget,
                          child: ChoiceChipRow(
                            options: _budgets,
                            selected: _budget,
                            onSelected: (v) => setState(() => _budget = v),
                            labelBuilder: (v) => _budgetLabel(l10n, v),
                          ),
                        ),
                        const Divider(height: AppSpacing.xxl),
                        _PrefRow(
                          label: l10n.prefsPace,
                          child: ChoiceChipRow(
                            options: _paces,
                            selected: _pace,
                            onSelected: (v) => setState(() => _pace = v),
                            labelBuilder: (v) => _paceLabel(l10n, v),
                          ),
                        ),
                        const Divider(height: AppSpacing.xxl),
                        _PrefRow(
                          label: l10n.prefsCompanions,
                          child: ChoiceChipRow(
                            options: companionOptions,
                            selected: _companions,
                            onSelected: (v) => setState(() => _companions = v),
                            labelBuilder: (v) => companionLabel(l10n, v),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                  _Section(
                    title: l10n.prefsInterests,
                    help: l10n.prefsInterestsHelp,
                    child: InterestPicker(
                      selected: _interests,
                      onChanged: (next) => setState(
                        () => _interests
                          ..clear()
                          ..addAll(next),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                  _Section(
                    title: l10n.prefsSectionRhythm,
                    help: l10n.prefsSectionRhythmHelp,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _PrefRow(
                          label: l10n.prefsWorkStyle,
                          child: ChoiceChipRow(
                            options: _workStyles,
                            selected: _workStyle,
                            onSelected: (v) => setState(() => _workStyle = v),
                            labelBuilder: (v) => _workStyleLabel(l10n, v),
                          ),
                        ),
                        const Divider(height: AppSpacing.xxl),
                        _PrefRow(
                          label: l10n.prefsFitnessRoutine,
                          help: l10n.prefsFitnessRoutineHelp,
                          child: ChoiceChipRow(
                            options: fitnessRoutineOptions,
                            selected: _fitnessRoutine,
                            onSelected: (v) =>
                                setState(() => _fitnessRoutine = v),
                            labelBuilder: (v) => fitnessRoutineLabel(l10n, v),
                          ),
                        ),
                        const Divider(height: AppSpacing.xxl),
                        _PrefRow(
                          label: l10n.prefsOutdoorIntensity,
                          help: l10n.prefsOutdoorIntensityHelp,
                          child: ChoiceChipRow(
                            options: outdoorIntensityOptions,
                            selected: _outdoorIntensity,
                            onSelected: (v) =>
                                setState(() => _outdoorIntensity = v),
                            labelBuilder: (v) => outdoorIntensityLabel(l10n, v),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xxl),
                  _Section(
                    title: l10n.prefsSectionFlights,
                    help: l10n.prefsSectionFlightsHelp,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // The field labels itself (floating label + icon), so
                        // it takes the full row rather than a second, twin
                        // label in the left column.
                        KeyedSubtree(
                          key: _airportFieldKey,
                          child: AirportField(
                            label: l10n.prefsHomeAirport,
                            icon: Icons.home,
                            selected: _homeAirport,
                            errorText: _homeAirportError,
                            onSelected: (a) => setState(() {
                              _homeAirport = a;
                              if (a != null) _homeAirportError = null;
                            }),
                            onQueryChanged: (t) => setState(() {
                              _homeAirportText = t;
                              // Any edit retracts the complaint; Save
                              // re-checks.
                              _homeAirportError = null;
                            }),
                          ),
                        ),
                        // The complaint REPLACES the help line rather than
                        // stacking under it — Material's own helperText/
                        // errorText convention, and the field already renders
                        // the error inside its decoration.
                        if (_homeAirportError == null) ...[
                          const SizedBox(height: AppSpacing.xs),
                          Text(
                            l10n.prefsHomeAirportHelp,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                        const Divider(height: AppSpacing.xxl),
                        _PrefRow(
                          label: l10n.prefsBaggage,
                          help: l10n.prefsBaggageHelp,
                          child: ChoiceChipRow(
                            options: baggageOptions,
                            selected: _baggage,
                            onSelected: (v) => setState(() => _baggage = v),
                            labelBuilder: (v) => baggageLabel(l10n, v),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
      // Save rides a pinned bar (the references' move) instead of the old
      // full-width button buried at scroll end — one honest Save for what is
      // one full PUT, reachable from anywhere on the page. Built only on this
      // branch: the load-failed state must keep Save unreachable.
      saveBar = _SaveBar(saving: state.saving, onSave: _save);
    }

    return Scaffold(
      appBar: GradientAppBar(
        title: l10n.prefsTitle,
      ),
      body: body,
      bottomNavigationBar: saveBar,
    );
  }
}

/// A titled section: display-face heading and muted one-line description sitting
/// OUTSIDE a quiet card that holds the fields — the grouped-settings anatomy
/// (heading / description / card) both reference settings pages share.
class _Section extends StatelessWidget {
  final String title;
  final String? help;

  /// One optional leading icon at heading scale. On this page only the
  /// AI-maintained notes section carries one (auto_awesome, the app's
  /// established AI mark), so the one machine-written field is signposted.
  final IconData? icon;
  final Widget child;

  const _Section({
    required this.title,
    this.help,
    this.icon,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: scheme.primary),
              const SizedBox(width: AppSpacing.sm),
            ],
            // The display face and its w500 come from the theme's headline
            // tier — never restated here, so this can't be the call site that
            // ships faux-bold.
            Expanded(
              child: Text(title, style: theme.textTheme.headlineSmall),
            ),
          ],
        ),
        if (help != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            help!,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: AppSpacing.md),
        // Card margin zeroed so the card tracks the column's stretch width;
        // elevation/radius/tint come from the app cardTheme.
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: child,
          ),
        ),
      ],
    );
  }
}

/// One field inside a section card: label left / control right on wide cards,
/// stacked on narrow ones, with optional help under the control (where both
/// reference settings pages put it).
class _PrefRow extends StatelessWidget {
  final String label;
  final String? help;
  final Widget child;

  const _PrefRow({required this.label, this.help, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelText = Text(label, style: theme.textTheme.titleSmall);
    final control = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        child,
        if (help != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            help!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < _kRowTwoColMin) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              labelText,
              const SizedBox(height: AppSpacing.sm),
              control,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: _kRowLabelWidth,
              // Nudges the label onto the chip row's first text line.
              child: Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: labelText,
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(child: control),
          ],
        );
      },
    );
  }
}

/// The pinned save bar: quiet chrome (surface + hairline, not a raised card),
/// its button aligned to the same 700px column as the content.
class _SaveBar extends StatelessWidget {
  final bool saving;
  final VoidCallback onSave;

  const _SaveBar({required this.saving, required this.onSave});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          // PageContainer is a Center, and an unwrapped Center EXPANDS — as
          // this Scaffold's bottomNavigationBar it would take the whole screen
          // height and squeeze the body to zero. IntrinsicHeight pins the bar
          // to the button's height while keeping the one shared 700px column.
          child: IntrinsicHeight(
            child: PageContainer(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton(
                    onPressed: saving ? null : onSave,
                    child: saving
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(context.l10n.commonSave),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
