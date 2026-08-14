import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/airport.dart';
import '../widgets/airport_field.dart';
import '../widgets/empty_state.dart';
import '../widgets/page_container.dart';
import '../widgets/section_header.dart';
import '../widgets/choice_chip_row.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/interest_picker.dart';
import '../constants/travel_profile_options.dart';
import '../l10n/l10n.dart';
import '../providers/preferences_provider.dart';
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
      return;
    }
    final ok = await ref.read(preferencesProvider.notifier).save(
          budget: _budget,
          pace: _pace,
          workStyle: _workStyle,
          companions: _companions,
          fitnessRoutine: _fitnessRoutine,
          outdoorIntensity: _outdoorIntensity,
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

    final Widget body;
    if (!_initialized && state.error != null) {
      // The load failed and the form was never seeded. Keep Save unreachable:
      // saving a blank form is a full PUT that would wipe the server profile.
      body = EmptyState(
        icon: Icons.cloud_off,
        title: l10n.prefsLoadErrorTitle,
        message: l10n.prefsLoadErrorMessage,
        iconColor: theme.colorScheme.error.withValues(alpha: 0.6),
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
      body = ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          // Centered 700px column on wide layouts (declutter series);
          // the ListView stays full-width so wheel/scrollbar work in
          // the gutters.
          PageContainer(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                const SizedBox(height: AppSpacing.xl),
                SectionHeader(title: l10n.prefsWorkStyle),
                const SizedBox(height: AppSpacing.sm),
                ChoiceChipRow(
                  options: _workStyles,
                  selected: _workStyle,
                  onSelected: (v) => setState(() => _workStyle = v),
                  labelBuilder: (v) => _workStyleLabel(l10n, v),
                ),
                const SizedBox(height: AppSpacing.xl),
                SectionHeader(title: l10n.prefsCompanions),
                const SizedBox(height: AppSpacing.sm),
                ChoiceChipRow(
                  options: companionOptions,
                  selected: _companions,
                  onSelected: (v) => setState(() => _companions = v),
                  labelBuilder: (v) => companionLabel(l10n, v),
                ),
                const SizedBox(height: AppSpacing.xl),
                SectionHeader(title: l10n.prefsInterests),
                const SizedBox(height: AppSpacing.sm),
                InterestPicker(
                  selected: _interests,
                  onChanged: (next) => setState(
                    () => _interests
                      ..clear()
                      ..addAll(next),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                SectionHeader(title: l10n.prefsFitnessRoutine),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  l10n.prefsFitnessRoutineHelp,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                ChoiceChipRow(
                  options: fitnessRoutineOptions,
                  selected: _fitnessRoutine,
                  onSelected: (v) => setState(() => _fitnessRoutine = v),
                  labelBuilder: (v) => fitnessRoutineLabel(l10n, v),
                ),
                const SizedBox(height: AppSpacing.xl),
                SectionHeader(title: l10n.prefsOutdoorIntensity),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  l10n.prefsOutdoorIntensityHelp,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                ChoiceChipRow(
                  options: outdoorIntensityOptions,
                  selected: _outdoorIntensity,
                  onSelected: (v) => setState(() => _outdoorIntensity = v),
                  labelBuilder: (v) => outdoorIntensityLabel(l10n, v),
                ),
                const SizedBox(height: AppSpacing.xl),
                SectionHeader(title: l10n.prefsHomeAirport),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  l10n.prefsHomeAirportHelp,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                AirportField(
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
                    // Any edit retracts the complaint; Save re-checks.
                    _homeAirportError = null;
                  }),
                ),
                const SizedBox(height: AppSpacing.xl),
                SectionHeader(title: l10n.prefsProfileNotes),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  l10n.prefsProfileNotesHelp,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _notesController,
                  maxLines: 6,
                  maxLength: 2000,
                  decoration: InputDecoration(
                    hintText: l10n.prefsProfileNotesHint,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: AppSpacing.xxl),
                FilledButton(
                  onPressed: state.saving ? null : _save,
                  style: FilledButton.styleFrom(
                      padding:
                          const EdgeInsets.symmetric(vertical: AppSpacing.lg)),
                  child: state.saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(l10n.commonSave),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: GradientAppBar(
        title: Text(l10n.prefsTitle),
      ),
      body: body,
    );
  }
}
