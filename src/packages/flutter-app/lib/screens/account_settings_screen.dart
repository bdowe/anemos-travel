import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../providers/api_client_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/locale_provider.dart';
import '../services/account_api_service.dart';
import '../theme/spacing.dart';
import '../widgets/legal_links.dart';
import '../widgets/page_container.dart';
import '../widgets/section_header.dart';
import '../utils/snack.dart';

final accountApiServiceProvider = Provider<AccountApiService>((ref) {
  return AccountApiService(ref.watch(apiClientProvider));
});

/// Account self-service: display name, password change, sign-out-everywhere,
/// account deletion (user-accounts spec follow-ups).
class AccountSettingsScreen extends ConsumerStatefulWidget {
  const AccountSettingsScreen({super.key});

  @override
  ConsumerState<AccountSettingsScreen> createState() =>
      _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends ConsumerState<AccountSettingsScreen> {
  late final TextEditingController _nameController;
  final _currentPwController = TextEditingController();
  final _newPwController = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: ref.read(authProvider).user?.displayName ?? '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _currentPwController.dispose();
    _newPwController.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (mounted) showSnack(context, msg);
  }

  String _errText(Object e) => '$e'.replaceFirst('Exception: ', '');

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      _snack(_errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveName() {
    final l10n = context.l10n;
    return _run(() async {
      final name = _nameController.text.trim();
      final user =
          await ref.read(accountApiServiceProvider).updateDisplayName(name);
      ref.read(authProvider.notifier).setUser(user);
      _snack(l10n.settingsNameUpdated);
    });
  }

  Future<void> _changePassword() {
    final l10n = context.l10n;
    return _run(() async {
      final res = await ref.read(accountApiServiceProvider).changePassword(
            _currentPwController.text,
            _newPwController.text,
          );
      await ref.read(authProvider.notifier).adoptSession(res.token, res.user);
      _currentPwController.clear();
      _newPwController.clear();
      _snack(l10n.settingsPasswordChanged);
    });
  }

  Future<void> _setReminders(bool enabled) => _run(() async {
        final user = await ref
            .read(accountApiServiceProvider)
            .updateEmailPreferences(remindersEnabled: enabled);
        ref.read(authProvider.notifier).setUser(user);
      });

  Future<void> _setNudges(bool enabled) => _run(() async {
        final user = await ref
            .read(accountApiServiceProvider)
            .updateEmailPreferences(nudgesEnabled: enabled);
        ref.read(authProvider.notifier).setUser(user);
      });

  Future<void> _logoutAll() => _run(() async {
        await ref.read(accountApiServiceProvider).logoutAll();
        // Our own session died too; sign out locally and let AuthGate route.
        await ref.read(authProvider.notifier).signOutLocally();
      });

  Future<void> _deleteAccount() async {
    final l10n = context.l10n;
    final pwController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsDeleteAccountTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.settingsDeleteAccountBody),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: pwController,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              decoration: InputDecoration(
                labelText: l10n.settingsConfirmPassword,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.settingsDeleteForever),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      pwController.dispose();
      return;
    }
    await _run(() async {
      await ref
          .read(accountApiServiceProvider)
          .deleteAccount(pwController.text);
      await ref.read(authProvider.notifier).signOutLocally();
    });
    pwController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final user = ref.watch(authProvider).user;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: PageContainer(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            SectionHeader(title: l10n.settingsProfileSection),
            const SizedBox(height: AppSpacing.md),
            if (user != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Text(user.email, style: theme.textTheme.bodyMedium),
              ),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: l10n.settingsDisplayName,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _busy ? null : _saveName,
                child: Text(l10n.settingsSaveName),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            SectionHeader(title: l10n.settingsPasswordSection),
            const SizedBox(height: AppSpacing.md),
            AutofillGroup(
              child: Column(
                children: [
                  TextField(
                    controller: _currentPwController,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: InputDecoration(
                      labelText: l10n.settingsCurrentPassword,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  TextField(
                    controller: _newPwController,
                    obscureText: true,
                    autofillHints: const [AutofillHints.newPassword],
                    decoration: InputDecoration(
                      labelText: l10n.settingsNewPassword,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _busy ? null : _changePassword,
                child: Text(l10n.settingsChangePassword),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            SectionHeader(title: l10n.settingsSessionsSection),
            const SizedBox(height: AppSpacing.sm),
            Text(
              l10n.settingsSessionsHelp,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.logout),
                label: Text(l10n.settingsSignOutEverywhere),
                onPressed: _busy ? null : _logoutAll,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            SectionHeader(title: l10n.languageSectionTitle),
            const SizedBox(height: AppSpacing.sm),
            const _LanguagePicker(),
            const SizedBox(height: AppSpacing.xl),
            SectionHeader(title: l10n.settingsEmailPrefsSection),
            const SizedBox(height: AppSpacing.sm),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.settingsTripReminders),
              subtitle: Text(l10n.settingsTripRemindersSubtitle),
              value: user?.remindersEnabled ?? true,
              onChanged: _busy ? null : (v) => _setReminders(v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.settingsWeeklyIdeas),
              subtitle: Text(l10n.settingsWeeklyIdeasSubtitle),
              value: user?.nudgesEnabled ?? true,
              onChanged: _busy ? null : (v) => _setNudges(v),
            ),
            const SizedBox(height: AppSpacing.xl),
            SectionHeader(title: l10n.settingsLegalSection),
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: AppSpacing.sm,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(l10n.settingsPrivacyPolicy),
                    onPressed: openPrivacyPolicy,
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(l10n.settingsTermsOfService),
                    onPressed: openTermsOfService,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            SectionHeader(title: l10n.settingsDangerZoneSection),
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon:
                    Icon(Icons.delete_forever, color: theme.colorScheme.error),
                label: Text(l10n.settingsDeleteAccount,
                    style: TextStyle(color: theme.colorScheme.error)),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: theme.colorScheme.error),
                ),
                onPressed: _busy ? null : _deleteAccount,
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }
}

/// Language selection (specs/i18n-spanish).
///
/// "System default" is the initial state and keeps following the device, so a
/// traveler who changes their phone's language is followed rather than pinned.
/// An explicit choice wins on this device and syncs to the account, which is
/// what makes it carry to a second device and to the emails the server sends.
///
/// Options are built from [kSupportedLocales] rather than hardcoded, so
/// enabling a language stays a one-line change.
class _LanguagePicker extends ConsumerWidget {
  const _LanguagePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final state = ref.watch(localeProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RadioGroup<String>(
          groupValue: state.override,
          onChanged: (v) {
            if (v != null) ref.read(localeProvider.notifier).setOverride(v);
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RadioListTile<String>(
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.languageSystemDefault),
                value: kLocaleSystem,
              ),
              for (final locale in kSupportedLocales)
                RadioListTile<String>(
                  contentPadding: EdgeInsets.zero,
                  title: Text(languageDisplayName(l10n, locale.languageCode)),
                  value: locale.languageCode,
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        // Saved trips and AI notes keep the language they were written in;
        // say so here rather than letting it look like a bug.
        Text(
          l10n.languageChangeNote,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}
