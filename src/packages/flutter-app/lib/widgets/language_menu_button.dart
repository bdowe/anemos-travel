import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../providers/locale_provider.dart';

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
    final l10n = context.l10n;
    // Checked state mirrors the settings picker.
    final language = ref.watch(localeProvider.select((s) => s.language));
    return PopupMenuButton<String>(
      tooltip: l10n.languageMenuTooltip,
      // Surface, elevation, radius and the below-the-bar position come from
      // `popupMenuTheme` (app_theme.dart).
      // No explicit color: inherits the bar's foreground (white on the
      // gradient bars, onSurface on the auth screen's transparent bar).
      icon: const Icon(Icons.language),
      onSelected: (v) => ref.read(localeProvider.notifier).setLanguage(v),
      itemBuilder: (_) => [
        for (final locale in kSupportedLocales)
          CheckedPopupMenuItem<String>(
            value: locale.languageCode,
            checked: language == locale.languageCode,
            child: Text(languageDisplayName(l10n, locale.languageCode)),
          ),
      ],
    );
  }
}
