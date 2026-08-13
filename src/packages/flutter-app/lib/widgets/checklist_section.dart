import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../models/checklist_item.dart';
import '../providers/checklist_provider.dart';
import '../theme/spacing.dart';
import 'empty_state.dart';
import 'section_header.dart';
import 'status_pill.dart';

/// The per-trip packing checklist: a lightweight list the AI assistant seeds
/// (add_packing_item) and the traveler edits freely. On trip detail it renders
/// body-only (showHeader: false) inside the "What to wear & pack" sheet
/// (specs/what-to-wear, wear_pack_sheet.dart), below the weather-derived
/// recommendations; standalone it keeps its own "Packing & prep" header.
/// Self-contained — it owns its data via [checklistProvider] and reconciles
/// mutations by invalidating that family key.
class ChecklistSection extends ConsumerStatefulWidget {
  final String tripId;
  final bool canEdit;

  /// Live read, not a captured bool: this widget's host is a modal sheet
  /// route that never rebuilds on the screen's connectivity setState. The
  /// action guards read it at call time; the add row's disabled VISUAL only
  /// reflects the last build, so it can stay stale until something else
  /// rebuilds the sheet body (a connectivity flip alone never does) — the
  /// TripReviewSection trade. A guarded tap while stale-enabled shows the
  /// offline snackbar behind the sheet barrier (known debt, friction-log
  /// 2026-08-13); the mutation itself never fires.
  final bool Function() isOffline;

  /// False when a parent (trip detail's collapsed-section row) already
  /// renders the divider/title/count, so this widget is body-only.
  final bool showHeader;

  const ChecklistSection({
    super.key,
    required this.tripId,
    required this.canEdit,
    required this.isOffline,
    this.showHeader = true,
  });

  @override
  ConsumerState<ChecklistSection> createState() => _ChecklistSectionState();
}

// Display order for the category groups. Free-text on the server, but the
// client groups into this known set; anything else falls under "general". The
// values themselves are sent to the server, so they are NEVER translated —
// only their display labels are (specs/i18n-spanish).
const List<String> _categoryOrder = [
  'documents',
  'clothing',
  'electronics',
  'health',
  'general',
];

String _categoryLabel(AppLocalizations l10n, String value) => switch (value) {
      'documents' => l10n.checklistCategoryDocuments,
      'clothing' => l10n.checklistCategoryClothing,
      'electronics' => l10n.checklistCategoryElectronics,
      'health' => l10n.checklistCategoryHealth,
      'general' => l10n.checklistCategoryGeneral,
      _ => value,
    };

const Map<String, IconData> _categoryIcons = {
  'documents': Icons.description_outlined,
  'clothing': Icons.checkroom_outlined,
  'electronics': Icons.devices_other_outlined,
  'health': Icons.medical_services_outlined,
  'general': Icons.luggage_outlined,
};

String _normalizeCategory(String raw) {
  final c = raw.trim().toLowerCase();
  return _categoryOrder.contains(c) ? c : 'general';
}

class _ChecklistSectionState extends ConsumerState<ChecklistSection> {
  final TextEditingController _addController = TextEditingController();
  String _addCategory = 'general';
  bool _busy = false;

  @override
  void dispose() {
    _addController.dispose();
    super.dispose();
  }

  bool _guard() {
    if (widget.isOffline()) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.commonOffline)),
      );
      return true;
    }
    return false;
  }

  Future<void> _run(Future<void> Function() op) async {
    if (_guard() || _busy) return;
    setState(() => _busy = true);
    try {
      await op();
      ref.invalidate(checklistProvider(widget.tripId));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.commonGenericError)),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toggle(ChecklistItem item, bool checked) => _run(() =>
      ref.read(checklistApiServiceProvider).update(
          widget.tripId, item.id, {'checked': checked}));

  void _delete(ChecklistItem item) => _run(() =>
      ref.read(checklistApiServiceProvider).delete(widget.tripId, item.id));

  void _add() {
    final title = _addController.text.trim();
    if (title.isEmpty) return;
    _run(() async {
      await ref
          .read(checklistApiServiceProvider)
          .add(widget.tripId, title, _addCategory);
      _addController.clear();
    });
  }

  Future<void> _editTitle(ChecklistItem item) async {
    if (_guard()) return;
    final l10n = context.l10n;
    final controller = TextEditingController(text: item.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.checklistEditItemTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: l10n.checklistItemLabel),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l10n.commonCancel)),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(l10n.commonSave),
          ),
        ],
      ),
    );
    if (newTitle != null && newTitle.isNotEmpty && newTitle != item.title) {
      _run(() => ref
          .read(checklistApiServiceProvider)
          .update(widget.tripId, item.id, {'title': newTitle}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(checklistProvider(widget.tripId));
    // Best-effort: on error or while first loading with no data, render
    // nothing rather than an error state — a utility section shouldn't shout.
    final items = async.valueOrNull;
    if (items == null) return const SizedBox.shrink();

    // Viewers with an empty list get no section at all (nothing to show or do).
    if (items.isEmpty && !widget.canEdit) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final l10n = context.l10n;
    final checked = items.where((i) => i.checked).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showHeader) ...[
          const Divider(height: 32),
          SectionHeader(
            title: l10n.checklistTitle,
            action: items.isEmpty
                ? null
                : StatusPill.custom(
                    label: '$checked/${items.length}',
                    background: theme.colorScheme.surfaceContainerHighest,
                    foreground: theme.colorScheme.onSurfaceVariant,
                  ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        if (items.isEmpty)
          EmptyState(
            compact: true,
            icon: Icons.luggage_outlined,
            title: l10n.checklistEmptyTitle,
            message: l10n.checklistEmptyMessage,
          )
        else
          ..._buildGroups(theme, items),
        if (widget.canEdit) ...[
          const SizedBox(height: AppSpacing.sm),
          _buildAddRow(theme),
        ],
      ],
    );
  }

  List<Widget> _buildGroups(ThemeData theme, List<ChecklistItem> items) {
    final byCategory = <String, List<ChecklistItem>>{};
    for (final item in items) {
      byCategory.putIfAbsent(_normalizeCategory(item.category), () => []).add(item);
    }
    final widgets = <Widget>[];
    for (final cat in _categoryOrder) {
      final group = byCategory[cat];
      if (group == null || group.isEmpty) continue;
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
        child: Row(
          children: [
            Icon(_categoryIcons[cat], size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: AppSpacing.xs),
            Text(
              _categoryLabel(context.l10n, cat),
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ));
      for (final item in group) {
        widgets.add(_buildRow(theme, item));
      }
    }
    return widgets;
  }

  Widget _buildRow(ThemeData theme, ChecklistItem item) {
    return Padding(
      key: ValueKey(item.id),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            height: 40,
            child: Checkbox(
              value: item.checked,
              onChanged: widget.canEdit
                  ? (v) => _toggle(item, v ?? false)
                  : null,
            ),
          ),
          Expanded(
            child: Text(
              item.title,
              style: theme.textTheme.bodyMedium?.copyWith(
                decoration:
                    item.checked ? TextDecoration.lineThrough : null,
                color: item.checked
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.onSurface,
              ),
            ),
          ),
          if (widget.canEdit)
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert,
                  size: 18, color: theme.colorScheme.onSurfaceVariant),
              tooltip: context.l10n.checklistItemOptions,
              onSelected: (v) {
                if (v == 'edit') _editTitle(item);
                if (v == 'delete') _delete(item);
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                    value: 'edit', child: Text(context.l10n.checklistMenuEdit)),
                PopupMenuItem(
                    value: 'delete', child: Text(context.l10n.commonDelete)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildAddRow(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        DropdownButton<String>(
          value: _addCategory,
          underline: const SizedBox.shrink(),
          onChanged: widget.isOffline()
              ? null
              : (v) => setState(() => _addCategory = v ?? 'general'),
          items: [
            for (final cat in _categoryOrder)
              DropdownMenuItem(
                value: cat,
                child: Icon(_categoryIcons[cat],
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: TextField(
            controller: _addController,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              isDense: true,
              hintText: context.l10n.checklistAddHint,
            ),
            onSubmitted: (_) => _add(),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add),
          tooltip: context.l10n.checklistAddItemTooltip,
          onPressed: widget.isOffline() ? null : _add,
        ),
      ],
    );
  }
}
