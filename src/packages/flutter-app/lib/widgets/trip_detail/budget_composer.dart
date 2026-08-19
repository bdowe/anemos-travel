import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/budget_provider.dart';
import '../../theme/spacing.dart';
import '../budget_categories.dart';

/// The Budget tab's add-expense composer: the planned/paid + city pick line
/// ("add options"), then the add row itself — category trigger, description
/// field, amount field, commit button.
///
/// Lifted out of `widgets/budget_section.dart` unchanged — a pure move for
/// the wave-1 budget-tab redesign, so the section's redesign happens around
/// an untouched composer. The composer owns the row's two controllers and
/// the draft write-back; its one write (the add) still goes through the
/// section's [run], so the busy guard, the two provider invalidations and
/// the error snackbar remain the single implementation. What used to read
/// `_cityOptions` arrives as [cityOptions].
class BudgetComposer extends ConsumerStatefulWidget {
  final String tripId;
  final bool isOffline;

  /// The pickable cities: the trip's legs minus the "Other places" run,
  /// resolved by the section (`BudgetSection._cityOptions`). Keys are
  /// canonical `RenderLeg.Key` spellings; labels/qualifiers are display text.
  final List<({String key, String label, String? qualifier})> cityOptions;

  /// The section's one mutation runner: busy guard + provider invalidation +
  /// error snackbar. The add goes through it so the composer's write shares
  /// every behavior the section's own writes have.
  final Future<void> Function(Future<void> Function() op) run;

  const BudgetComposer({
    super.key,
    required this.tripId,
    required this.isOffline,
    required this.cityOptions,
    required this.run,
  });

  @override
  ConsumerState<BudgetComposer> createState() => _BudgetComposerState();
}

class _BudgetComposerState extends ConsumerState<BudgetComposer> {
  final TextEditingController _labelController = TextEditingController();
  final TextEditingController _amountController = TextEditingController();
  // The picked category has no field here on purpose: it lives in the draft,
  // which is the one place any part of this row's unsaved contents lives.

  @override
  void initState() {
    super.initState();
    _seedFrom(widget.tripId);
  }

  @override
  void didUpdateWidget(BudgetComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Nothing to flush — every keystroke already wrote through — so a trip
    // swap on a reused element only has to re-seed. Unreachable from the one
    // mount site today, where the id is fixed for the screen's life; here so
    // that "which trip's draft is in these fields" is answered by the code
    // rather than by that convention.
    if (oldWidget.tripId != widget.tripId) _seedFrom(widget.tripId);
  }

  /// Loads [tripId]'s kept draft into the fields, then arms the write-back.
  /// Called from `initState`, never from `build`: seeding on rebuild would
  /// clobber the character just typed, and this way the section's early
  /// `SizedBox.shrink()` return cannot race it.
  ///
  /// `read`, never `watch` — watching the draft from `build` would re-render
  /// every expense row on every keystroke.
  void _seedFrom(String tripId) {
    final draft = ref.read(expenseDraftProvider(tripId));
    // Detached across the two assignments: [_saveDraft] writes both fields at
    // once, so a half-applied seed would post the outgoing trip's amount into
    // the incoming trip's draft before the next line corrected it. Removing a
    // listener that was never added is a no-op, so this is safe on first call.
    _labelController.removeListener(_saveDraft);
    _amountController.removeListener(_saveDraft);
    _labelController.value = _endCollapsed(draft.label);
    _amountController.value = _endCollapsed(draft.amountText);
    // Recorded on every change rather than on the way out: this row is
    // unmounted without warning (a header-tab switch, the chat panel
    // re-parenting the body), and by the time `dispose` runs the element is
    // already unmounted, so `ref` throws there.
    _labelController.addListener(_saveDraft);
    _amountController.addListener(_saveDraft);
  }

  /// Never assign `controller.text`: that setter parks the selection at
  /// offset -1, which the engine normalizes to 0, so the next keystroke lands
  /// in *front* of the restored value (the trap `airport_field.dart`
  /// documents).
  static TextEditingValue _endCollapsed(String text) => TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );

  void _saveDraft() =>
      ref.read(expenseDraftProvider(widget.tripId).notifier).setText(
            label: _labelController.text,
            amountText: _amountController.text,
          );

  @override
  void dispose() {
    _labelController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  void _add() {
    final label = _labelController.text.trim();
    final amount = double.tryParse(_amountController.text.trim());
    if (label.isEmpty || amount == null || amount < 0) return;
    final key = expenseDraftProvider(widget.tripId);
    final draftNow = ref.read(key);
    final category = draftNow.category;
    final planned = draftNow.planned;
    // Same stale-key resolution the picker renders with: a draft city the
    // trip no longer has posts as "no city", never as a 400.
    final legKey = widget.cityOptions.any((c) => c.key == draftNow.legKey)
        ? draftNow.legKey
        : null;
    // Captured before the await: this row can be unmounted mid-save (tab away
    // while the POST is in flight), and by the time it returns the controllers
    // are disposed and `ref` throws. The draft outlives both, so clearing it
    // has to go through the notifier — otherwise the expense just saved sits
    // in the row waiting to be added a second time.
    final draft = ref.read(key.notifier);
    widget.run(() async {
      await ref.read(budgetApiServiceProvider).addExpense(
            widget.tripId,
            category: category,
            label: label,
            amount: amount,
            planned: planned,
            legKey: legKey,
          );
      if (mounted) {
        _labelController.clear();
        _amountController.clear();
      }
      draft.clearText();
    });
  }

  /// The panel's inset, and it is asymmetric for the reason this whole file is
  /// asymmetric: **vertical space in a scrolling tab body is nearly free;
  /// horizontal space is the scarce resource.** [_buildAddRow]'s ladder is
  /// measured against the width it is handed, and after wave 3 that is this
  /// panel's interior rather than the tab's full width — so every horizontal
  /// pixel spent here is a pixel the ladder concedes, at a lower width, to a
  /// worse rung.
  ///
  /// Not free-hand numbers: at [AppSpacing.md] a side, a 360px phone lost the
  /// category trigger off the description's line — rung 3, which the row is
  /// only supposed to reach at accessibility widths, and which puts the
  /// trigger between the two fields in reading order so `next` stops there
  /// instead of reaching the amount. [AppSpacing.sm] a side keeps 360 on rung
  /// 2, and the ladder tests at that width are the standing guard: they name
  /// no width this padding is allowed to be, only that whatever it is, a
  /// 360px row still seats the category beside the label.
  static const EdgeInsets _panelPadding = EdgeInsets.symmetric(
    horizontal: AppSpacing.sm,
    vertical: AppSpacing.md,
  );

  /// The composer as a surface of its own — the blank line at the foot of the
  /// receipt.
  ///
  /// Until wave 3 this was the last thing on the tab with no surface at all:
  /// #498 gave the record a raised card and the model's estimate a recessed
  /// well, and then the traveler's own write — the one thing on the tab that
  /// creates an expense — scattered across the bare page below both, wider
  /// than either, its options line right-aligned over left-aligned fields. It
  /// read as debris under the cards rather than as the tab's write affordance
  /// (see the Rocket Money / Airwallex entry forms in the wave's Mobbin pass:
  /// the fields are always INSIDE something).
  ///
  /// Surface + a hairline, and NEITHER a fill nor an elevation, because the
  /// tab already spends both: the receipt is raised (the record), the
  /// suggestion is a recessed `surfaceContainerHighest` well (an estimate that
  /// is not yours yet). A filled panel here was tried first and read as a
  /// second well — `surfaceContainerHigh` lands 6/255 off `Highest`, so the
  /// two stacked as one grey block split by a gap. An outlined sheet is the
  /// third register the tab was missing and the one an entry surface wants
  /// anyway: a blank line, edge drawn, nothing written on it yet.
  ///
  /// The fill is `surface` and in LIGHT that is the page exactly (both
  /// `(244,251,248)`), so there the hairline alone draws the panel — which is
  /// the intent, not an accident: an outlined region on the page is what an
  /// empty line looks like. Dark parts company usefully — `surface` there is
  /// darker than the well above, the opposite direction from light and the
  /// same "not that other block" either way. In both, the fields (grey[50]
  /// light, `surfaceContainerHighest` dark) sit clearly ON the panel.
  ///
  /// The top gap is this widget's own margin rather than a sibling gap, for
  /// the reason the options line used to carry it: `DailySpendSection`
  /// collapses to nothing when offline or empty, and a sibling `SizedBox`
  /// would dangle above the panel in the common case.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: AppRadius.mdAll,
        ),
        padding: _panelPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildAddOptions(theme),
            _buildAddRow(theme),
          ],
        ),
      ),
    );
  }

  /// Planned or paid, for whatever the add row is about to save.
  ///
  /// On its OWN LINE rather than inside the add row: that row already spends
  /// 240px of its 358 on fixed-width controls, and the "Add an expense…" hint
  /// barely fits in what's left — any horizontal addition kills it. Vertical
  /// space in a scrolling tab body is nearly free; horizontal space is the
  /// scarce resource.
  ///
  /// "Barely fits" turned out to be "doesn't": the hint was truncating to
  /// "Add a…" on every phone, and [_buildAddRow] now stacks onto two lines
  /// when it can't seat both fields. That vindicates this control's own line
  /// rather than reversing it — putting it back in the row would only make the
  /// row stack at wider and wider windows.
  ///
  /// It carries a visible "Add as" label because the pick has **no immediate
  /// on-screen consequence** — tapping it changes nothing but itself, and the
  /// result only appears one action later, on the line you then add. An
  /// unlabelled pill sitting between the daily-spend card and the add row was
  /// read as belonging to the card, or as a filter over the list above, and so
  /// as a control that did nothing. The label is what ties it to the row it
  /// arms; since wave 3 the panel around both is the rest of that tie, and the
  /// misreading it was written against — "this belongs to the card above" — is
  /// the one thing a shared surface can no longer be read as saying.
  ///
  /// The pick is read from the draft, so it survives the remount that changing
  /// header tab or opening the chat panel causes — a choice, like the category
  /// beside it.
  ///
  /// Since 00072 the line also carries the CITY picker — deliberately here
  /// and not in [_buildAddRow]: that row is measured against
  /// [_addRowFixedWidth] and a third fixed control would move every one of
  /// the 8-widths × 2-locales assertions, while this line is a [Wrap] with
  /// slack, right at every width and locale by construction.
  Widget _buildAddOptions(ThemeData theme) {
    return Consumer(builder: (context, ref, _) {
      final planned = ref
          .watch(expenseDraftProvider(widget.tripId).select((d) => d.planned));
      final l10n = context.l10n;
      return Padding(
        // Only the gap down to the entry row now: the gap ABOVE the composer
        // became the panel's margin in [build] when the panel arrived, since a
        // surface's own outer spacing cannot live inside one of its children.
        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
        // Wrap, not Row: the label and the pill sit side by side when they
        // fit and the pill drops to its own line when they don't, which is
        // what Spanish does at 360px ("Añadir como" wants more than the
        // leftover beside a two-segment pill). A Row would have to choose
        // between ellipsizing the label and wrapping it mid-phrase, and both
        // fail silently — the add row's hints already taught this file that
        // "nothing threw" proves nothing. Wrap needs no measurement, so it is
        // right in every language and at every text scale by construction.
        child: Wrap(
          // Left, not right (wave 3): on the bare page this line right-aligned
          // so it would sit over the commit button it arms, which put the
          // composer's two halves on opposite edges with nothing tying them
          // together. Inside the panel the left edge IS the tie — the label
          // now opens the surface the way the receipt's title opens that card.
          alignment: WrapAlignment.start,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            Text(
              l10n.budgetPlanAddAs,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(theme.textTheme.labelMedium),
              ),
              segments: [
                ButtonSegment(
                  value: true,
                  label: Text(l10n.budgetPlanStatePlanned),
                ),
                ButtonSegment(
                  value: false,
                  label: Text(l10n.budgetPlanStatePaid),
                ),
              ],
              selected: {planned},
              onSelectionChanged: widget.isOffline
                  ? null
                  : (picked) => ref
                      .read(expenseDraftProvider(widget.tripId).notifier)
                      .setPlanned(picked.first),
            ),
            if (widget.cityOptions.isNotEmpty) _buildCityPicker(theme),
          ],
        ),
      );
    });
  }

  /// The add row's city pick (00072): which leg the next line is filed under.
  /// A popup menu, not a DropdownButton, for [_buildCategoryTrigger]'s reason
  /// (a dropdown's menu is constrained to its trigger's width) — but with a
  /// TEXT trigger, unlike the category's icon: this control has no width
  /// pressure on its Wrap line, and an icon cannot say "Rome".
  ///
  /// The selected key is resolved against [BudgetComposer.cityOptions] before
  /// rendering, so a stale draft key — the trip lost a city since it was
  /// picked — displays and posts as "No city" instead of a 400.
  Widget _buildCityPicker(ThemeData theme) {
    return Consumer(builder: (context, ref, _) {
      final draftKey = ref
          .watch(expenseDraftProvider(widget.tripId).select((d) => d.legKey));
      final l10n = context.l10n;
      final options = widget.cityOptions;
      ({String key, String label, String? qualifier})? selected;
      for (final c in options) {
        if (c.key == draftKey) selected = c;
      }
      final muted = theme.colorScheme.onSurfaceVariant;
      return PopupMenuButton<String>(
        key: const Key('budget-add-city'),
        tooltip: l10n.budgetCityLabel,
        enabled: !widget.isOffline,
        // '' is the menu's "No city" value (a PopupMenuItem value can't be
        // null); it reaches the draft as null via setLegKey.
        onSelected: (v) => ref
            .read(expenseDraftProvider(widget.tripId).notifier)
            .setLegKey(v.isEmpty ? null : v),
        itemBuilder: (_) => [
          CheckedPopupMenuItem<String>(
            value: '',
            checked: selected == null,
            child: Text(l10n.budgetCityNone),
          ),
          for (final c in options)
            CheckedPopupMenuItem<String>(
              value: c.key,
              checked: c.key == selected?.key,
              child: Text(c.qualifier == null
                  ? c.label
                  : '${c.label} · ${c.qualifier}'),
            ),
        ],
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.place_outlined, size: 18, color: muted),
            const SizedBox(width: 2),
            Text(
              selected == null
                  ? l10n.budgetCityNone
                  : (selected.qualifier == null
                      ? selected.label
                      : '${selected.label} · ${selected.qualifier}'),
              style: theme.textTheme.labelMedium?.copyWith(color: muted),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: muted),
          ],
        ),
      );
    });
  }

  /// What a dense outline field spends on chrome either side of its text.
  /// Flutter 3.35's `InputDecorator` gives the M3 + dense + outline branch a
  /// `contentPadding` of 12 per side (input_decorator.dart:2600-2603) and then
  /// deducts `OutlineInputBorder.gapPadding` (4 — input_border.dart:332) per
  /// side as well (:2609-2613, :992-1008), so the hint is laid out at exactly
  /// `fieldWidth - _fieldChrome`. That is the width the regression tests read
  /// straight off `RenderParagraph.constraints`. (The old note here said "16px
  /// per side" — right in total, wrong about where it comes from.)
  static const double _fieldChrome = 32;

  /// A hint whose intrinsic width lands EXACTLY on the interior is one
  /// sub-pixel from ellipsizing itself, and a fractional device pixel ratio is
  /// enough to get there. One spacing step of headroom is plenty, because the
  /// measurement below already uses the same painter inputs the hint's own
  /// paragraph does — this covers rounding, not disagreement.
  static const double _hintFitSlack = AppSpacing.xs;

  /// Width of each of the row's two icon affordances.
  ///
  /// **Declared, not predicted** — the row renders both inside a `SizedBox` of
  /// this width, so the number the arithmetic spends is the number the row
  /// occupies. That is the whole difference between this constant and the 136
  /// it replaces, and predicting would have been wrong anyway: `IconButton`
  /// takes its tap-target size from the platform, so the add button is 48 on
  /// Android/iOS and silently **40** on macOS/Linux/Windows
  /// (theme_data.dart:398-408). Pinning it makes the row platform-invariant
  /// and brings the desktop tap target back up to Material's minimum.
  ///
  /// Legitimately a constant even in a file about measuring: 48 encodes a
  /// touch-target spec, not a string, so it doesn't move with locale — and it
  /// can't move with text scale either, since `Icon.applyTextScaling` defaults
  /// to false and nothing here enables it.
  static const double _controlWidth = kMinTouchTarget;

  /// Everything on the add row that is not a field: the two icon affordances
  /// and the two gaps. None of it is text, so none of it moves with the text
  /// scaler; the terms that DO move are the hints, and those are measured.
  static const double _addRowFixedWidth =
      2 * _controlWidth + 2 * AppSpacing.sm;

  /// The amount field has two things to seat and its hint is the smaller one,
  /// so the figure is named here instead of folded into a magic width: a
  /// five-figure amount with cents — a flight or a hotel total, the widest
  /// thing that lands on one expense line. Sizing the box from
  /// "Amount"/"Importe" alone would give ~82px, which reads fine and is
  /// miserable to type in.
  ///
  /// Only characters this field's own [FilteringTextInputFormatter] admits: a
  /// sample containing a thousands separator would size the box for text it
  /// can never hold.
  static const String _amountWidthSample = '88888.88';

  /// The width a field needs for [text] to render in full, chrome included —
  /// directly comparable to the width a `SizedBox`/`Expanded` hands the field.
  ///
  /// Measured, not assumed: the strings are translated ("Añade un gasto…"),
  /// the text scaler is the traveler's, and the 1em-per-glyph FlutterTest font
  /// moves both again. A constant can only ever be right for the one string
  /// somebody measured — which is exactly how the description hint shipped
  /// truncated to "Add a…" while the amount hint had a regression test.
  ///
  /// The style is the one `InputDecorator` actually paints a hint with:
  /// `textTheme.bodyLarge` merged with the M3 default hint style, which sets
  /// only a colour (input_decorator.dart:2170-2183, :5897-5902). These fields
  /// pass neither `style` nor `hintStyle`, so nothing else contributes.
  /// `Text` merges `MediaQuery.boldTextOf` on top of that, so this does too.
  ///
  /// `maxIntrinsicWidth`, not `width`: painted width omits the trailing
  /// letter-spacing the field's constraint still has to cover, and intrinsic
  /// width is the quantity the tests compare against `constraints.maxWidth` —
  /// the widget's arithmetic and the tests' oracle have to be the same number.
  ///
  /// Same shape as the overview show-more toggle's `_collapsedClips`
  /// (trip_detail_screen.dart): synchronous, one layout pass, no post-frame
  /// re-measure.
  static double _fieldWidthFor(BuildContext context, String text) {
    var style = Theme.of(context).textTheme.bodyLarge;
    if (MediaQuery.boldTextOf(context)) {
      style = style?.merge(const TextStyle(fontWeight: FontWeight.bold));
    }
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.maybeLocaleOf(context),
    )..layout();
    final width = painter.maxIntrinsicWidth;
    painter.dispose();
    return (width + _fieldChrome + _hintFitSlack).ceilToDouble();
  }

  /// Closed state stays icon-compact (the add row is width-tight on phones);
  /// the open menu spells out each category. A popup menu (not a
  /// DropdownButton) because a dropdown's menu is hard-constrained to the
  /// trigger's width — an icon-only trigger would clip every label.
  ///
  /// The pick is read straight from the draft rather than mirrored into a
  /// field, so there is one answer to "which category is armed". The watch is
  /// scoped to this button and selects one String, so typing in the fields
  /// beside it can never re-render the expense list — or re-run the
  /// measurement beside it.
  Widget _buildCategoryTrigger(ThemeData theme) {
    return Consumer(builder: (context, ref, _) {
      final category = ref
          .watch(expenseDraftProvider(widget.tripId).select((d) => d.category));
      return SizedBox(
        width: _controlWidth,
        child: PopupMenuButton<String>(
          // Zero, not the default all(8) that PopupMenuButton forwards to its
          // IconButton: the two 18px icons plus 8+8 measure 52, which would
          // overflow the 48 the row's arithmetic spends here. 36 centred in 48
          // leaves 6 a side and reads the same.
          padding: EdgeInsets.zero,
          tooltip: context.l10n.budgetCategoryLabel,
          enabled: !widget.isOffline,
          icon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(kExpenseCategoryIcons[category],
                  size: 18, color: theme.colorScheme.onSurfaceVariant),
              Icon(Icons.arrow_drop_down,
                  size: 18, color: theme.colorScheme.onSurfaceVariant),
            ],
          ),
          onSelected: (v) => ref
              .read(expenseDraftProvider(widget.tripId).notifier)
              .setCategory(v),
          itemBuilder: (_) => [
            for (final cat in kExpenseCategories)
              CheckedPopupMenuItem<String>(
                value: cat,
                checked: cat == category,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(kExpenseCategoryIcons[cat],
                        size: 18, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: AppSpacing.sm),
                    Text(expenseCategoryLabel(context.l10n, cat)),
                  ],
                ),
              ),
          ],
        ),
      );
    });
  }

  /// Neither field passes a `style:`, and the theme passes no `hintStyle:`, on
  /// purpose: that is what makes the hint's metrics exactly `bodyLarge`, which
  /// is what [_fieldWidthFor] measures. Adding either without teaching the
  /// measurement about it silently un-derives the row.
  Widget _buildLabelField() => TextField(
        controller: _labelController,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(
          isDense: true,
          hintText: context.l10n.budgetAddHint,
        ),
      );

  Widget _buildAmountField() => TextField(
        controller: _amountController,
        textInputAction: TextInputAction.done,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
        ],
        decoration: InputDecoration(
          isDense: true,
          hintText: context.l10n.budgetAmount,
        ),
        onSubmitted: (_) => _add(),
      );

  /// Pick a category, say what it was, say what it cost, commit.
  ///
  /// One line while both fields can have the width their hints need, two lines
  /// below that. Measured rather than thresholded, because what runs out is a
  /// translated string at the traveler's text scale and no px breakpoint is
  /// right for every combination of those: at 390px the description field got
  /// ~106px and its hint truncated to "Add a…" — illegible, and too narrow to
  /// type into either, so shortening the copy would only have made an unusable
  /// field readable.
  ///
  /// It truncated rather than wrapped because a field hint inherits
  /// `hintMaxLines` from `TextField.maxLines`, which is 1, and a hint with a
  /// max-lines gets `TextOverflow.ellipsis` against a tight layout width. So
  /// the failure was silent by construction: no overflow stripes, no thrown
  /// exception, just a shorter string. Only a width assertion catches it,
  /// which is why the tests measure rather than watch for exceptions.
  ///
  /// Stacked, the money and the commit drop to a second line and the
  /// description takes the width back, while the category trigger stays glued
  /// to the field it categorizes — where it reads as that field's leading
  /// icon, which is what it is.
  ///
  /// The decision can't oscillate: this row's width comes from the sliver
  /// above it, never from its own children, so stacking cannot change the
  /// constraint that caused it.
  Widget _buildAddRow(ThemeData theme) {
    // LayoutBuilder, never MediaQuery (house rule, chat_panel.dart): the width
    // this row gets is the trip BODY's, and a docked chat panel takes 401px of
    // it without the window changing at all.
    return LayoutBuilder(builder: (context, constraints) {
      final labelWidth = _fieldWidthFor(context, context.l10n.budgetAddHint);
      final amountWidth = math.max(
        _fieldWidthFor(context, context.l10n.budgetAmount),
        _fieldWidthFor(context, _amountWidthSample),
      );
      final category = _buildCategoryTrigger(theme);
      final label = _buildLabelField();
      final amount = _buildAmountField();
      // Declared to _controlWidth for the same reason as the category trigger
      // — and it is a fix as well as a declaration: on desktop this button was
      // 40 wide, under Material's 48 minimum.
      //
      // Tonal-filled since wave 3, and still an IconButton at exactly
      // _controlWidth so the row's arithmetic is untouched: this is the tab's
      // primary write, and as a bare glyph it sat quieter than the "Add to
      // plan" links in the suggestion well directly above it — the one action
      // that files an expense reading weaker than the one that offers an
      // estimate. Tonal rather than filled because the surface it commits into
      // is a panel, not a hero, and the teal spine belongs to one action per
      // screen (#503's header rule).
      final add = SizedBox(
        width: _controlWidth,
        child: IconButton.filledTonal(
          icon: const Icon(Icons.add),
          tooltip: context.l10n.budgetAddExpenseTooltip,
          onPressed: widget.isOffline ? null : _add,
        ),
      );

      // A ladder, cheapest concession first — the description keeps whatever
      // company it can while still showing its hint whole:
      //
      //   1. everything on one line
      //   2. the money and the commit drop to a second line
      //   3. the category drops too, and the description takes the whole line
      //
      // Unbounded width takes rung 1: it seats anything, and the Expanded
      // would already have thrown there, so the guard only feeds the
      // arithmetic.
      if (!constraints.maxWidth.isFinite ||
          constraints.maxWidth >=
              _addRowFixedWidth + labelWidth + amountWidth) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            category,
            const SizedBox(width: AppSpacing.sm),
            Expanded(child: label),
            const SizedBox(width: AppSpacing.sm),
            SizedBox(width: amountWidth, child: amount),
            add,
          ],
        );
      }

      // Rung 3 is the accessibility rung, not a phone rung: a 320px body at a
      // large text scale is where the category trigger's 48 + 8 stops being
      // affordable. Below THIS nothing helps and the hint ellipsizes as it
      // always did — but by then the description has the widest line the row
      // can offer, which is the most the layout can honestly do.
      final categorySharesTheLabelsLine =
          constraints.maxWidth - _controlWidth - AppSpacing.sm >= labelWidth;

      // Both fields keep their order and their relative position on every
      // rung, so reading-order traversal carries `next` from the label to the
      // amount and `done` to _add() — except on rung 3, where the category
      // trigger now sits between them in reading order and `next` stops there
      // first. Acceptable at the only width that reaches rung 3, and the
      // alternative (the category between the amount and the add button)
      // buys a tidier tab order by making the row look like a mistake.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (categorySharesTheLabelsLine)
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                category,
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: label),
              ],
            )
          else
            label,
          const SizedBox(height: AppSpacing.xs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (!categorySharesTheLabelsLine) ...[
                category,
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(child: amount),
              add,
            ],
          ),
        ],
      );
    });
  }
}
