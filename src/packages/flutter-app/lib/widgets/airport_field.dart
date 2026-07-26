import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../models/airport.dart';
import '../providers/flights_provider.dart';
import '../theme/spacing.dart';
import '../utils/errors.dart';

/// An airport/city autocomplete field backed by [airportSearchProvider]. When a
/// place is selected it shows the chosen label with a clear button; otherwise it
/// shows a search box with a live suggestion dropdown. Shared by the Find
/// Flights screen and the Travel profile (home airport).
class AirportField extends ConsumerStatefulWidget {
  final String label;
  final IconData icon;
  final Airport? selected;
  final ValueChanged<Airport?> onSelected;

  const AirportField({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onSelected,
  });

  @override
  ConsumerState<AirportField> createState() => _AirportFieldState();
}

class _AirportFieldState extends ConsumerState<AirportField> {
  final _controller = TextEditingController();
  String _query = '';

  /// Hides the suggestion list after an outside tap without discarding the
  /// typed text; typing or tapping back into the field re-opens it.
  bool _dismissed = false;

  bool get _listOpen => !_dismissed && _query.trim().length >= 2;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Shared bordered shell for the suggestion list and its empty/error rows,
  /// so all three states read as the same dropdown.
  Widget _suggestionBox({required Widget child}) {
    return Container(
      margin: const EdgeInsets.only(top: AppSpacing.xs),
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: AppRadius.smAll,
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final selected = widget.selected;
    final muted = theme.colorScheme.onSurfaceVariant;

    if (selected != null) {
      return InputDecorator(
        decoration: InputDecoration(
          labelText: widget.label,
          prefixIcon: Icon(widget.icon),
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            tooltip: l10n.airportFieldClearTooltip,
            icon: const Icon(Icons.close),
            onPressed: () {
              widget.onSelected(null);
              _controller.clear();
              setState(() => _query = '');
            },
          ),
        ),
        child: Text(
          selected.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
        ),
      );
    }

    // TapRegion: a tap anywhere outside the field + list dismisses the list
    // (the inline dropdown otherwise only closes on selection).
    return TapRegion(
      onTapOutside: (_) {
        if (_listOpen) setState(() => _dismissed = true);
      },
      child: Column(
        children: [
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: widget.label,
              hintText: l10n.airportFieldHint,
              prefixIcon: Icon(widget.icon),
              border: const OutlineInputBorder(),
            ),
            onTap: () => setState(() => _dismissed = false),
            onChanged: (v) => setState(() {
              _query = v;
              _dismissed = false;
            }),
          ),
          if (_listOpen)
            Consumer(
              builder: (context, ref, _) {
                final results = ref.watch(airportSearchProvider(_query));
                return results.when(
                  data: (airports) => airports.isEmpty
                      // Visible "no matches" so a typo is distinguishable
                      // from "still typing".
                      ? _suggestionBox(
                          child: ListTile(
                            dense: true,
                            leading:
                                Icon(Icons.search_off, size: 20, color: muted),
                            title: Text(
                              l10n.airportFieldNoMatches,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(color: muted),
                            ),
                          ),
                        )
                      : _suggestionBox(
                          child: ListView(
                            shrinkWrap: true,
                            children: airports
                                .map((a) => ListTile(
                                      dense: true,
                                      leading: Icon(
                                          a.subType.toLowerCase() == 'city'
                                              ? Icons.location_city
                                              : Icons.local_airport,
                                          size: 20),
                                      title: Text(a.label),
                                      subtitle: a.country.isEmpty
                                          ? null
                                          : Text(a.country),
                                      onTap: () {
                                        widget.onSelected(a);
                                        _controller.clear();
                                        setState(() => _query = '');
                                      },
                                    ))
                                .toList(),
                          ),
                        ),
                  loading: () => const Padding(
                    padding: EdgeInsets.all(AppSpacing.sm),
                    child: LinearProgressIndicator(),
                  ),
                  // A failed lookup is no longer silent: a muted error row
                  // with a tap-to-retry (the one network failure in the
                  // flights flow that used to be indistinguishable from
                  // "no results").
                  error: (e, _) => _suggestionBox(
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.error_outline,
                          size: 20, color: theme.colorScheme.error),
                      title: Text(
                        friendlyError(l10n, e),
                        style:
                            theme.textTheme.bodyMedium?.copyWith(color: muted),
                      ),
                      trailing: Icon(Icons.refresh, size: 20, color: muted),
                      onTap: () =>
                          ref.invalidate(airportSearchProvider(_query)),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
