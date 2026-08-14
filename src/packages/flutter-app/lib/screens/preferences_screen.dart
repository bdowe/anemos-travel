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
  final Set<String> _interests = {};
  Airport? _homeAirport;
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
        _interests.addAll(prefs.interests);
        final home = prefs.homeAirport;
        if (home != null && home.isNotEmpty) {
          _homeAirport = Airport(iataCode: home, name: home);
        }
        _notesController.text = prefs.profileNotes ?? '';
      }
      _initialized = true;
    });
  }

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final ok = await ref.read(preferencesProvider.notifier).save(
          budget: _budget,
          pace: _pace,
          workStyle: _workStyle,
          interests: _interests.toList(),
          homeAirport: _homeAirport?.iataCode,
          // Always send the field's text: an emptied field clears the notes.
          profileNotes: _notesController.text.trim(),
        );
    if (!mounted) return;
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
                  onSelected: (a) => setState(() => _homeAirport = a),
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
