import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../providers/locale_provider.dart';
import '../theme/spacing.dart';

/// App-bar globe button offering the same choices as the account-settings
/// language picker (specs/i18n-spanish): System default plus every entry in
/// [kSupportedLocales]. Works signed out — the locale provider persists
/// device-wide and only syncs to the account when a session exists.
///
/// Unlike `AccountMenu`, this renders at every width: the wide layout's rail
/// has no language control to defer to.
class LanguageMenuButton extends ConsumerWidget {
  const LanguageMenuButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    // Checked state mirrors the settings picker: keyed on the explicit
    // override, so "System default" stays checked while following the device.
    final override = ref.watch(localeProvider.select((s) => s.override));
    return PopupMenuButton<String>(
      tooltip: l10n.languageMenuTooltip,
      // Open below the bar, on an M3 surface, instead of the default
      // overlapping panel that would inherit the app bar's white icons.
      position: PopupMenuPosition.under,
      color: theme.colorScheme.surface,
      elevation: 3,
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.mdAll),
      // No explicit color: inherits the bar's foreground (white on the
      // gradient bars, onSurface on the auth screen's transparent bar).
      icon: const Icon(Icons.language),
      onSelected: (v) => ref.read(localeProvider.notifier).setOverride(v),
      itemBuilder: (_) => [
        CheckedPopupMenuItem<String>(
          value: kLocaleSystem,
          checked: override == kLocaleSystem,
          child: Text(l10n.languageSystemDefault),
        ),
        for (final locale in kSupportedLocales)
          CheckedPopupMenuItem<String>(
            value: locale.languageCode,
            checked: override == locale.languageCode,
            child: Text(languageDisplayName(l10n, locale.languageCode)),
          ),
      ],
    );
  }
}
