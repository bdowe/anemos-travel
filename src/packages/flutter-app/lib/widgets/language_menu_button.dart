import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../providers/locale_provider.dart';
import '../theme/spacing.dart';

/// App-bar globe button offering the same choices as the account-settings
/// language picker (specs/i18n-spanish): every entry in [kSupportedLocales].
/// Works signed out — the locale provider persists device-wide and only syncs
/// to the account when a session exists.
///
/// Unlike `AccountMenu`, this renders at every width: the wide layout's rail
/// has no language control to defer to.
class LanguageMenuButton extends ConsumerWidget {
  const LanguageMenuButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    // Checked state mirrors the settings picker.
    final language = ref.watch(localeProvider.select((s) => s.language));
    return PopupMenuButton<String>(
      tooltip: l10n.languageMenuTooltip,
      // Surface, elevation, radius and the below-the-bar position come from
      // `popupMenuTheme` (app_theme.dart).
      // No explicit color: inherits the bar's foreground (white on the
      // gradient bars, onSurface on the auth screen's transparent bar).
      // Floored so a two-entry list reads as a panel, not a hug-width strip.
      constraints: const BoxConstraints(minWidth: 200),
      icon: const Icon(Icons.language),
      onSelected: (v) => ref.read(localeProvider.notifier).setLanguage(v),
      itemBuilder: (_) => [
        for (final locale in kSupportedLocales)
          PopupMenuItem<String>(
            value: locale.languageCode,
            // Hand-rolled rather than CheckedPopupMenuItem: the stock item
            // is a ListTile with its own metrics, so its rows sat on a
            // different grid than every other menu row in the app. This row
            // shares the account menu's geometry (20px leading slot, 12px
            // gap), reserves the slot when unchecked so labels never shift,
            // and marks selection the ladder way — the check in primary plus
            // a w600 label, weight not size.
            child: Semantics(
              checked: language == locale.languageCode,
              child: _languageRow(
                theme,
                selected: language == locale.languageCode,
                label: languageDisplayName(l10n, locale.languageCode),
              ),
            ),
          ),
      ],
    );
  }
}

Widget _languageRow(ThemeData theme,
    {required bool selected, required String label}) {
  return Row(
    children: [
      if (selected)
        Icon(Icons.check_rounded, size: 20, color: theme.colorScheme.primary)
      else
        const SizedBox(width: 20),
      const SizedBox(width: AppSpacing.md),
      Expanded(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: selected ? const TextStyle(fontWeight: FontWeight.w600) : null,
        ),
      ),
    ],
  );
}
