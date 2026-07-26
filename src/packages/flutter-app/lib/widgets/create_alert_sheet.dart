import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../providers/alerts_provider.dart';
import '../theme/spacing.dart';
import '../utils/errors.dart';
import '../utils/flight_labels.dart';
import '../utils/money_format.dart';
import '../utils/snack.dart';
import 'choice_chip_row.dart';
import 'section_header.dart';

/// Bottom sheet that turns the current flight search into a price alert
/// (specs/price-alerts). Seeded with the route/date/cheapest price the
/// traveler is looking at; they pick any-drop or a target price.
class CreateAlertSheet extends ConsumerStatefulWidget {
  final String origin;
  final String destination;
  final String departDate; // YYYY-MM-DD
  final String? returnDate; // YYYY-MM-DD; null = one-way
  final int adults;
  final String cabinClass;
  final String baggage; // personal_item | carry_on | checked
  final double? currentPrice;
  final String? currency;

  const CreateAlertSheet({
    super.key,
    required this.origin,
    required this.destination,
    required this.departDate,
    this.returnDate,
    this.adults = 1,
    this.cabinClass = 'economy',
    this.baggage = 'personal_item',
    this.currentPrice,
    this.currency,
  });

  static Future<void> show(BuildContext context, CreateAlertSheet sheet) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      // Desktop width cap: a full-bleed 1440px form reads as broken next to
      // the app's 700px-capped surfaces.
      constraints: const BoxConstraints(maxWidth: 560),
      // The keyboard inset is padded inside the sheet's own build (its own
      // MediaQuery), not here — the launcher's context goes stale when the
      // target-price field summons the keyboard.
      builder: (_) => sheet,
    );
  }

  @override
  ConsumerState<CreateAlertSheet> createState() => _CreateAlertSheetState();
}

class _CreateAlertSheetState extends ConsumerState<CreateAlertSheet> {
  bool _anyDrop = true;
  int _flexDays = 0;
  late final TextEditingController _targetController;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Prefill a plausible target: a bit under the current best fare.
    final seed = widget.currentPrice;
    _targetController = TextEditingController(
      text: seed == null ? '' : (seed * 0.9).floorToDouble().toStringAsFixed(0),
    );
  }

  @override
  void dispose() {
    _targetController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    // Captured before the await so the post-await snack never reads a
    // context that may have been unmounted.
    final l10n = context.l10n;
    double? target;
    if (!_anyDrop) {
      target = double.tryParse(_targetController.text.trim());
      if (target == null || target <= 0) {
        setState(() => _error = l10n.alertsInvalidTarget);
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(alertsProvider.notifier).create({
        'origin': widget.origin,
        'destination': widget.destination,
        'depart_date': widget.departDate,
        if (widget.returnDate != null) 'return_date': widget.returnDate,
        'adults': widget.adults,
        'cabin_class': widget.cabinClass,
        if (widget.baggage != 'personal_item') 'baggage': widget.baggage,
        if (_flexDays > 0) 'flex_days': _flexDays,
        if (target != null) 'target_price': target,
        if (widget.currentPrice != null) 'current_price': widget.currentPrice,
        if (widget.currency != null) 'currency': widget.currency,
      });
      if (mounted) {
        Navigator.of(context).pop();
        showSnack(context,
            l10n.alertSheetWatchingSnack(widget.origin, widget.destination));
      }
    } catch (e) {
      setState(() {
        _saving = false;
        _error = friendlyError(l10n, e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final cur = widget.currency ?? '';
    // AddStaySheet/_AddToTripSheet's sheet ergonomics: the column scrolls
    // inside a capped height, and the keyboard inset is read from THIS
    // context so the target-price field is lifted above the keyboard.
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.xl,
        right: AppSpacing.xl,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.alertSheetTitle, style: theme.textTheme.titleLarge),
              const SizedBox(height: AppSpacing.sm),
              Text(
                '${widget.origin} → ${widget.destination} · ${flightDateLabel(l10n, widget.departDate)}'
                '${widget.returnDate != null ? ' → ${flightDateLabel(l10n, widget.returnDate!)}' : ''}'
                '${widget.adults > 1 ? ' · ${l10n.alertsAdults(widget.adults)}' : ''}'
                '${widget.cabinClass != 'economy' ? ' · ${cabinClassLabel(l10n, widget.cabinClass)}' : ''}',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              if (widget.currentPrice != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text(
                    l10n.alertSheetBestPriceNow(
                        formatMoney(widget.currentPrice!, cur)),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              const SizedBox(height: AppSpacing.lg),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.alertSheetAnyDropTitle),
                subtitle: Text(l10n.alertSheetAnyDropSubtitle),
                value: _anyDrop,
                onChanged: (v) => setState(() => _anyDrop = v),
              ),
              if (!_anyDrop) ...[
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _targetController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: l10n.alertsNotifyAtOrBelow,
                    prefixText: cur.isEmpty ? null : '$cur ',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              SectionHeader(title: l10n.alertSheetFlexTitle),
              const SizedBox(height: AppSpacing.xs),
              Text(
                l10n.alertSheetFlexHelp,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppSpacing.sm),
              // Canonical values stay untranslated; only labels are localized
              // (the ChoiceChipRow contract). Re-tapping the selected chip
              // yields null — ignored so a flex choice is always selected.
              ChoiceChipRow(
                options: const ['0', '1', '2', '3'],
                selected: '$_flexDays',
                labelBuilder: (v) =>
                    v == '0' ? l10n.alertSheetFlexExact : '±$v',
                onSelected: (v) {
                  if (_saving || v == null) return;
                  setState(() => _flexDays = int.parse(v));
                },
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                ),
              const SizedBox(height: AppSpacing.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _saving ? null : _create,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.notifications_active_outlined),
                  label: Text(_saving
                      ? l10n.alertSheetCreating
                      : l10n.alertSheetCreate),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
