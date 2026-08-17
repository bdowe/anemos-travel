import 'package:flutter/material.dart';

import '../theme/spacing.dart';

/// One row of a trip's `⋮` — an icon, a label, and the thing it does.
///
/// The action carries its own handler rather than a string value the caller
/// switches on. The menu it replaced dispatched by string, and its switch had
/// a `default:` arm forwarding to a *second* switch with no default of its
/// own — so an entry whose case nobody wrote compiled clean, ran clean, and
/// silently did nothing. An action that cannot be constructed without its
/// callback removes that whole class of bug.
@immutable
class TripAction {
  const TripAction({
    required this.icon,
    required this.label,
    required this.onSelected,
    this.destructive = false,
  });

  final IconData icon;
  final String label;

  /// Invoked by the *caller*, after the menu or sheet has closed — never from
  /// inside the sheet's own build context, which is gone by then.
  final VoidCallback onSelected;

  /// Tints icon and label `colorScheme.error`. Both, always: a red label over
  /// a neutral icon reads as a rendering slip rather than a warning (the
  /// convention delete/leave have followed since they moved behind the menu).
  final bool destructive;
}

/// Drops empty sections so the divider derivation below can never emit a
/// leading, trailing, or doubled separator. This is the whole point of taking
/// sections instead of a flat list: the menu this replaced placed dividers by
/// hand, each guarded by an `||` chain that grew one term per feature — and
/// was already one term out of step with the block it fenced.
List<List<TripAction>> _sections(List<List<TripAction>> sections) =>
    sections.where((s) => s.isNotEmpty).toList(growable: false);

/// The trip's actions as a modal bottom sheet — the narrow-width face of the
/// app-bar `⋮`.
///
/// A phone's overflow list had grown to ten entries anchored in the top-right
/// corner, the hardest place on the screen to reach and the one spot a
/// full-height dropdown has nowhere to grow into. Everything else on this
/// screen that shows a stack of choices is already a sheet (trip health, wear
/// & pack, add to trip, the airports picker), so this is the house vocabulary
/// rather than a new one.
///
/// Resolves to the chosen action, or null if the sheet was dismissed. The
/// caller invokes `onSelected` — see [TripAction.onSelected].
///
/// No `Scaffold` inside the sheet, so the framework's Escape→dismiss handling
/// works as-is (a nested Scaffold swallows DismissIntent — the trip_map_screen
/// trap the other sheets all document).
Future<TripAction?> showTripActionsSheet(
  BuildContext context, {
  required List<List<TripAction>> sections,
}) {
  final grouped = _sections(sections);
  if (grouped.isEmpty) return Future<TripAction?>.value();
  return showModalBottomSheet<TripAction>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    // Width cap centers the sheet on desktop, same as the health/wear/progress
    // sheets — though at wide the `⋮` renders a popup and never opens this.
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (sheetContext) {
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.8,
          ),
          child: SingleChildScrollView(
            // Horizontal padding lives on the rows, not here: a full-bleed row
            // is a bigger tap target than an inset one, and the label still
            // lines up because the ListTile insets its own content.
            padding: const EdgeInsets.only(bottom: AppSpacing.lg),
            child: TripActionsSheetBody(sections: grouped),
          ),
        ),
      );
    },
  );
}

/// The sheet's rows. Public so tests can scope finders to it.
class TripActionsSheetBody extends StatelessWidget {
  const TripActionsSheetBody({super.key, required this.sections});

  final List<List<TripAction>> sections;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final grouped = _sections(sections);
    final children = <Widget>[];
    for (final section in grouped) {
      // Only ever *between* sections, and only once — see [_sections].
      if (children.isNotEmpty) {
        children.add(Divider(
          height: 1,
          color: theme.colorScheme.outlineVariant,
        ));
      }
      for (final action in section) {
        final tint = action.destructive
            ? theme.colorScheme.error
            : theme.colorScheme.onSurfaceVariant;
        children.add(ListTile(
          leading: Icon(action.icon, color: tint),
          // Two lines here, one in the popup: a sheet has the width AND the
          // vertical room, and the label that needs them is "Copy invite link
          // (can edit)" — in Spanish the parenthetical is the only thing
          // telling it apart from the row above, so ellipsizing it away costs
          // the reader the distinction.
          title: Text(
            action.label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: action.destructive
                ? TextStyle(color: theme.colorScheme.error)
                : null,
          ),
          minTileHeight: kMinTouchTarget,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          onTap: () => Navigator.pop(context, action),
        ));
      }
    }
    return Column(mainAxisSize: MainAxisSize.min, children: children);
  }
}

/// The same actions as popup entries — the wide-width face, and the one used
/// by the trip's own share button.
///
/// Rendering both faces from one list of [TripAction]s is what keeps them
/// honest: the share entries used to be a separate builder shared between two
/// menus precisely so the two could never offer different things, and that
/// guarantee now covers every entry rather than six of them.
List<PopupMenuEntry<TripAction>> tripActionPopupEntries(
  BuildContext context,
  List<List<TripAction>> sections,
) {
  final theme = Theme.of(context);
  final entries = <PopupMenuEntry<TripAction>>[];
  for (final section in _sections(sections)) {
    if (entries.isNotEmpty) entries.add(const PopupMenuDivider());
    for (final action in section) {
      entries.add(PopupMenuItem<TripAction>(
        value: action,
        child: _popupRow(theme, action),
      ));
    }
  }
  return entries;
}

/// Icon + label row for a popup entry. `Flexible` + ellipsis keeps a long
/// translation inside Material's 280px popup cap instead of overflowing —
/// the account menu's recipe, and denser than the zero-padded ListTile the
/// trip menu used to nest inside each item.
Widget _popupRow(ThemeData theme, TripAction action) {
  final tint = action.destructive
      ? theme.colorScheme.error
      : theme.colorScheme.onSurfaceVariant;
  return Row(
    children: [
      Icon(action.icon, size: 20, color: tint),
      const SizedBox(width: AppSpacing.md),
      Flexible(
        child: Text(
          action.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: action.destructive
              ? TextStyle(color: theme.colorScheme.error)
              : null,
        ),
      ),
    ],
  );
}
