import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../models/airport.dart';
import '../providers/flights_provider.dart';
import '../theme/spacing.dart';
import '../utils/errors.dart';

/// An airport/city autocomplete field backed by [airportSearchProvider]. Shared
/// by the Find Flights screen, the onboarding quiz and the Travel profile
/// (home airport).
///
/// **One mode, always editable.** The field is a real [TextField] holding the
/// selected airport's label, so a value that is already set can be typed over
/// in place. It used to render a chosen airport as static text with only a
/// clear button, which made an existing value impossible to edit — the Travel
/// profile seeds [selected] from the server, so that page always opened in the
/// non-editable state.
///
/// [selected] remains the authoritative value: typing voids a stale pick
/// (`onSelected(null)`) so the visible text can never disagree with what the
/// parent will save. A parent therefore has to treat "text present, selection
/// null" as an unresolved edit rather than as "no airport".
///
/// [selected] must be a stable field on the parent's `State`. The re-seed guard
/// compares [Airport.label] rather than instances (Airport has no `==`), so a
/// value rebuilt each frame is harmless, but a parent that derives [selected]
/// instead of honoring `onSelected(null)` would fight the user's typing.
class AirportField extends ConsumerStatefulWidget {
  final String label;
  final IconData icon;
  final Airport? selected;
  final ValueChanged<Airport?> onSelected;

  /// Mirrors the raw field text to the parent on every change, including the
  /// programmatic writes made when a suggestion is picked or the field cleared.
  ///
  /// A parent that saves needs this: [selected] alone cannot tell "no airport"
  /// apart from "typed something and never picked it", and those must not be
  /// treated the same — silently saving the second as the first is how an edit
  /// gets thrown away under a success message.
  final ValueChanged<String>? onQueryChanged;

  /// Shown under the field, e.g. to say an edit is unresolved.
  final String? errorText;

  const AirportField({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onSelected,
    this.onQueryChanged,
    this.errorText,
  });

  @override
  ConsumerState<AirportField> createState() => _AirportFieldState();
}

class _AirportFieldState extends ConsumerState<AirportField> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  String _query = ''; // debounced search text driving airportSearchProvider

  /// True once the user has edited the text and before that edit is committed
  /// (a pick, a clear, or an accepted seed). While dirty the field belongs to
  /// the user: a parent selection that lands late must not overwrite what they
  /// are in the middle of typing.
  bool _dirty = false;

  /// At most one pending post-frame `onSelected(null)` (see [_voidSelectionSoon]).
  bool _pendingVoid = false;

  /// One-shot: the next tap after focusing an untouched value selects the whole
  /// label so typing replaces the airport, instead of editing "Paris (CDG)"
  /// character by character. Later taps position the caret normally.
  bool _selectAllOnTap = false;

  /// Hides the suggestion list after an outside tap without discarding the
  /// typed text; typing or tapping back into the field re-opens it.
  bool _dismissed = false;

  /// Deliberately does NOT test [_focus] — a suggestion row is an [InkWell],
  /// which takes focus on click on desktop/web, so a focus term here would
  /// tear the list down under the pointer and make picking impossible. The
  /// orphaned-list case it would have guarded (a seed landing under an open
  /// dropdown) is already closed by [_acceptSeed].
  bool get _listOpen => !_dismissed && _query.trim().length >= 2;

  @override
  void initState() {
    super.initState();
    // Load-bearing on Find Flights: that form is built only while expanded, so
    // this State is recreated on every collapse/expand and a value already held
    // by the parent would otherwise come back as an empty box.
    final label = widget.selected?.label;
    if (label != null) _setText(label);
    _focus.addListener(_onFocusChanged);
  }

  @override
  void didUpdateWidget(AirportField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selected = widget.selected;
    // Never re-seed from a null selection: onChanged voids the pick on every
    // keystroke, so doing so would wipe the character just typed.
    if (selected == null || selected.label == _controller.text) return;
    if (_dirty) {
      // A parent selection landed while the user was typing — Find Flights
      // resolves its origin asynchronously and can answer minutes after the
      // field was first shown. The user wins; the parent is told its selection
      // is void, but not from here (see [_voidSelectionSoon]).
      _voidSelectionSoon();
      return;
    }
    _acceptSeed(selected.label);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Writes [text] with the caret at the end. Never assign `_controller.text`
  /// directly: that setter parks the selection at offset -1, which the engine
  /// normalizes to 0, so the next keystroke lands in *front* of the value.
  void _setText(String text) {
    if (text == _controller.text) return; // don't disturb the user's caret
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _selectAll() {
    if (_controller.text.isEmpty) return;
    _controller.selection =
        TextSelection(baseOffset: 0, extentOffset: _controller.text.length);
  }

  void _onFocusChanged() {
    if (!_focus.hasFocus) {
      _selectAllOnTap = false;
      return;
    }
    _selectAllOnTap = !_dirty && widget.selected != null;
    // Covers focus arriving without a tap (keyboard traversal); a tap re-runs
    // it from onTap, after the gesture has positioned the caret.
    if (_selectAllOnTap) _selectAll();
  }

  /// Debounces the [_query] update that drives [airportSearchProvider] so one
  /// autocomplete request fires 350 ms after typing stops, instead of one per
  /// keystroke. Immediate UI state (reopening the dismissed list) stays
  /// synchronous in [build]'s onChanged.
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _query = value);
    });
  }

  /// Accepts a selection handed down by the parent (first seed, or an async
  /// resolve). A full reset, not just a text write: leaving [_query] and the
  /// armed debounce in place would keep the dropdown showing results for the
  /// text this just replaced, or reopen it 350 ms later.
  void _acceptSeed(String label) {
    _debounce?.cancel();
    _setText(label);
    _query = '';
    _dismissed = true;
    _dirty = false;
  }

  /// Reports a voided selection to the parent after the current frame.
  /// [didUpdateWidget] runs during build and every call site sits below the
  /// element owning the build scope, so calling [AirportField.onSelected]
  /// synchronously from there throws "setState() called during build".
  void _voidSelectionSoon() {
    if (_pendingVoid) return;
    _pendingVoid = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingVoid = false;
      if (mounted && _dirty && widget.selected != null) {
        widget.onSelected(null);
      }
    });
  }

  /// Commits a pick: the field shows the chosen label and the list closes.
  /// [AirportField.onQueryChanged] fires before [AirportField.onSelected] here
  /// and in [_clear], so a parent that derives "unresolved" from the pair never
  /// observes the new text against the old selection.
  void _commit(Airport airport) {
    _debounce?.cancel();
    widget.onQueryChanged?.call(airport.label);
    widget.onSelected(airport);
    setState(() {
      _setText(airport.label);
      // Clearing _query is what closes the list. airportSearchProvider is not
      // autoDispose, so leaving a stale query would let the next onTap reopen
      // the dropdown instantly with the pre-pick rows.
      _query = '';
      _dismissed = true;
      _dirty = false;
    });
  }

  /// Clears both the text and the selection (the trailing X).
  void _clear() {
    _debounce?.cancel();
    widget.onQueryChanged?.call('');
    widget.onSelected(null);
    setState(() {
      _controller.clear();
      _query = '';
      _dismissed = false;
      _dirty = false;
    });
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
    final muted = theme.colorScheme.onSurfaceVariant;

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
            focusNode: _focus,
            decoration: InputDecoration(
              labelText: widget.label,
              hintText: l10n.airportFieldHint,
              prefixIcon: Icon(widget.icon),
              border: const OutlineInputBorder(),
              errorText: widget.errorText,
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: l10n.airportFieldClearTooltip,
                      icon: const Icon(Icons.close),
                      onPressed: _clear,
                    ),
            ),
            onTap: () {
              if (_selectAllOnTap) {
                _selectAllOnTap = false;
                _selectAll();
              }
              setState(() => _dismissed = false);
            },
            onChanged: (v) {
              // Typing voids a stale pick so the text on screen can never
              // disagree with the value the parent holds. Programmatic writes
              // never reach onChanged, so this cannot loop with the
              // didUpdateWidget re-seed.
              if (widget.selected != null) widget.onSelected(null);
              widget.onQueryChanged?.call(v);
              setState(() {
                _dirty = true;
                _dismissed = false;
              });
              _onSearchChanged(v);
            },
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
                                      onTap: () => _commit(a),
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
