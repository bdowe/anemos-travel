import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/l10n.dart';
import '../providers/api_client_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/locale_provider.dart';
import '../providers/theme_mode_provider.dart';
import '../services/account_api_service.dart';
import '../theme/app_colors.dart';
import '../theme/spacing.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/legal_links.dart';
import '../widgets/page_container.dart';
import '../utils/errors.dart';
import '../utils/trip_format.dart';
import '../utils/snack.dart';

final accountApiServiceProvider = Provider<AccountApiService>((ref) {
  return AccountApiService(ref.watch(apiClientProvider));
});

/// Below this content width a row's control drops under its label instead of
/// sharing the line — the widest control either language ships (the Spanish
/// "Cerrar sesión en todas partes" button) plus a readable label column no
/// longer fit side by side.
const double _kRowBreakpoint = 440;

/// Width of the compact dropdown controls (appearance / language). Wide
/// enough for every English label; longer Spanish labels ellipsize closed and
/// spell out in the open menu, which grows per item.
const double _kPickerWidth = 240;

/// Content width for the name/password editor dialogs — roomier than the
/// AlertDialog minimum so their floating field labels render whole at rest.
const double _kDialogFieldWidth = 360;

/// Account self-service: display name, password change, sign-out-everywhere,
/// account deletion (user-accounts spec follow-ups).
///
/// The page is a scannable index in grouped cards — label + description on
/// the left, the control on the right — rather than a form waterfall; name
/// and password edits open focused dialogs.
class AccountSettingsScreen extends ConsumerStatefulWidget {
  const AccountSettingsScreen({super.key});

  @override
  ConsumerState<AccountSettingsScreen> createState() =>
      _AccountSettingsScreenState();
}

class _AccountSettingsScreenState extends ConsumerState<AccountSettingsScreen> {
  bool _busy = false;

  void _snack(String msg) {
    if (mounted) showSnack(context, msg);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      // Localized, classified copy — never raw server prose (PR #227 rule).
      if (mounted) _snack(friendlyError(context.l10n, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editName() async {
    final current = ref.read(authProvider).user?.displayName ?? '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _EditNameDialog(initial: current),
    );
    if (name == null || !mounted) return;
    final l10n = context.l10n;
    await _run(() async {
      final user =
          await ref.read(accountApiServiceProvider).updateDisplayName(name);
      ref.read(authProvider.notifier).setUser(user);
      _snack(l10n.settingsNameUpdated);
    });
  }

  Future<void> _changePassword() async {
    final entered = await showDialog<(String, String)>(
      context: context,
      builder: (context) => const _ChangePasswordDialog(),
    );
    if (entered == null || !mounted) return;
    final l10n = context.l10n;
    await _run(() async {
      final res = await ref
          .read(accountApiServiceProvider)
          .changePassword(entered.$1, entered.$2);
      await ref.read(authProvider.notifier).adoptSession(res.token, res.user);
      _snack(l10n.settingsPasswordChanged);
    });
  }

  Future<void> _setReminders(bool enabled) {
    final l10n = context.l10n;
    return _run(() async {
      final user = await ref
          .read(accountApiServiceProvider)
          .updateEmailPreferences(remindersEnabled: enabled);
      ref.read(authProvider.notifier).setUser(user);
      _snack(l10n.settingsEmailPrefsUpdated);
    });
  }

  Future<void> _setNudges(bool enabled) {
    final l10n = context.l10n;
    return _run(() async {
      final user = await ref
          .read(accountApiServiceProvider)
          .updateEmailPreferences(nudgesEnabled: enabled);
      ref.read(authProvider.notifier).setUser(user);
      _snack(l10n.settingsEmailPrefsUpdated);
    });
  }

  Future<void> _logoutAll() async {
    final l10n = context.l10n;
    // Confirm first: this destroys the current session too, so a mis-tap
    // would eject the user from the app (same gate as deleting a trip).
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsSignOutEverywhereTitle),
        content: Text(l10n.settingsSignOutEverywhereBody),
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
            child: Text(l10n.settingsSignOutEverywhere),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await ref.read(accountApiServiceProvider).logoutAll();
      // Our own session died too; sign out locally and let AuthGate route.
      await ref.read(authProvider.notifier).signOutLocally();
    });
  }

  Future<void> _deleteAccount() async {
    // The dialog owns its password controller (see _DeleteAccountDialog) so
    // it is disposed with the route, after the exit animation — disposing it
    // here raced the closing dialog's TextField still listening to it.
    final password = await showDialog<String>(
      context: context,
      builder: (context) => const _DeleteAccountDialog(),
    );
    if (password == null || !mounted) return;
    await _run(() async {
      await ref.read(accountApiServiceProvider).deleteAccount(password);
      await ref.read(authProvider.notifier).signOutLocally();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final user = ref.watch(authProvider).user;
    final displayName = user?.displayName.trim() ?? '';

    return Scaffold(
      appBar: GradientAppBar(title: l10n.settingsTitle),
      body: Column(
        children: [
          // A thin global activity bar (the account calls all share one _busy
          // flag). Height is reserved so toggling doesn't shift the content.
          SizedBox(
            height: 2,
            child: _busy ? const LinearProgressIndicator(minHeight: 2) : null,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                // Centered 700px column on wide layouts; the ListView stays
                // full-width so wheel/scrollbar work in the gutters
                // (declutter-series pattern).
                PageContainer(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (user != null) ...[
                        _IdentityHeader(
                          displayName: displayName,
                          email: user.email,
                        ),
                        const SizedBox(height: AppSpacing.xl),
                      ],
                      _SettingsCard(
                        title: l10n.settingsAccountSection,
                        children: [
                          _SettingsRow(
                            label: l10n.settingsDisplayName,
                            subtitle: displayName.isEmpty ? null : displayName,
                            control: TextButton(
                              onPressed: _busy ? null : _editName,
                              child: Text(l10n.settingsEditAction),
                            ),
                          ),
                          const _RowDivider(),
                          _SettingsRow(
                            label: l10n.settingsPasswordSection,
                            control: OutlinedButton(
                              onPressed: _busy ? null : _changePassword,
                              child: Text(l10n.settingsChangePassword),
                            ),
                          ),
                          const _RowDivider(),
                          _SettingsRow(
                            label: l10n.settingsSessionsSection,
                            subtitle: l10n.settingsSessionsHelp,
                            control: OutlinedButton.icon(
                              icon: const Icon(Icons.logout, size: 18),
                              label: Text(l10n.settingsSignOutEverywhere),
                              onPressed: _busy ? null : _logoutAll,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      _SettingsCard(
                        title: l10n.settingsConnectedAppsSection,
                        description: l10n.settingsConnectedAppsHelp,
                        children: const [_ConnectedAppsList()],
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      _SettingsCard(
                        title: l10n.appearanceLanguageSectionTitle,
                        children: [
                          _SettingsRow(
                            label: l10n.appearanceSectionTitle,
                            control: const SizedBox(
                              width: _kPickerWidth,
                              child: _AppearancePicker(),
                            ),
                          ),
                          const _RowDivider(),
                          // Saved trips and AI notes keep the language they
                          // were written in; say so here rather than letting
                          // it look like a bug.
                          _SettingsRow(
                            label: l10n.languageSectionTitle,
                            subtitle: l10n.languageChangeNote,
                            control: const SizedBox(
                              width: _kPickerWidth,
                              child: _LanguagePicker(),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      _SettingsCard(
                        title: l10n.settingsEmailPrefsSection,
                        children: [
                          _SwitchRow(
                            title: l10n.settingsTripReminders,
                            subtitle: l10n.settingsTripRemindersSubtitle,
                            value: user?.remindersEnabled ?? true,
                            onChanged: _busy ? null : (v) => _setReminders(v),
                          ),
                          const _RowDivider(),
                          _SwitchRow(
                            title: l10n.settingsWeeklyIdeas,
                            subtitle: l10n.settingsWeeklyIdeasSubtitle,
                            value: user?.nudgesEnabled ?? true,
                            onChanged: _busy ? null : (v) => _setNudges(v),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      _SettingsCard(
                        title: l10n.settingsLegalSection,
                        children: [
                          _LinkRow(
                            label: l10n.settingsPrivacyPolicy,
                            onTap: openPrivacyPolicy,
                          ),
                          const _RowDivider(),
                          _LinkRow(
                            label: l10n.settingsTermsOfService,
                            onTap: openTermsOfService,
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      _SettingsCard(
                        title: l10n.settingsDangerZoneSection,
                        children: [
                          _SettingsRow(
                            subtitle: l10n.settingsDeleteAccountHelp,
                            control: OutlinedButton.icon(
                              icon: Icon(Icons.delete_forever,
                                  size: 18, color: theme.colorScheme.error),
                              label: Text(
                                l10n.settingsDeleteAccount,
                                style: theme.textTheme.labelLarge
                                    ?.copyWith(color: theme.colorScheme.error),
                              ),
                              style: OutlinedButton.styleFrom(
                                side:
                                    BorderSide(color: theme.colorScheme.error),
                              ),
                              onPressed: _busy ? null : _deleteAccount,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.xxl),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Who is signed in — the page opens with identity rather than a form. The
/// avatar speaks the account menu's language (brand circle, white initial);
/// the name is the page's one serif moment.
class _IdentityHeader extends StatelessWidget {
  final String displayName;
  final String email;

  const _IdentityHeader({required this.displayName, required this.email});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A nameless account leads with its email instead of an empty line.
    final title = displayName.isEmpty ? email : displayName;
    final initial = displayName.isEmpty ? '?' : displayName[0].toUpperCase();
    return Row(
      children: [
        CircleAvatar(
          radius: 28,
          backgroundColor: AppColors.brand,
          child: Text(
            initial,
            style: theme.textTheme.titleLarge
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(width: AppSpacing.lg),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineSmall,
              ),
              if (displayName.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A settings group: quiet in-card title (+ optional description) over tight
/// rows. Flat on purpose — hairline and tonal step instead of elevation, so a
/// page of seven groups doesn't become a stack of seven shadows.
class _SettingsCard extends StatelessWidget {
  final String title;
  final String? description;
  final List<Widget> children;

  const _SettingsCard({
    required this.title,
    this.description,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: AppRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(title, style: theme.textTheme.titleMedium),
          ),
          if (description != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              description!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: AppSpacing.xs),
          ...children,
        ],
      ),
    );
  }
}

/// Hairline between rows inside a [_SettingsCard].
class _RowDivider extends StatelessWidget {
  const _RowDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 1,
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}

/// One settings row: label + optional description on the left, the control on
/// the right. Below [_kRowBreakpoint] of available width the control drops
/// under the text block instead of squeezing it.
class _SettingsRow extends StatelessWidget {
  final String? label;
  final String? subtitle;
  final Widget control;

  const _SettingsRow({this.label, this.subtitle, required this.control});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null)
          Text(
            label!,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w500),
          ),
        if (subtitle != null) ...[
          if (label != null) const SizedBox(height: AppSpacing.xs),
          Text(
            subtitle!,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < _kRowBreakpoint) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                textBlock,
                const SizedBox(height: AppSpacing.sm),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: control,
                ),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: textBlock),
              const SizedBox(width: AppSpacing.lg),
              control,
            ],
          );
        },
      ),
    );
  }
}

/// Switch row on the shared settings-row register. SwitchListTile keeps the
/// whole-row tap target and toggle semantics; only the type register is ours.
class _SwitchRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        title,
        style:
            theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// Full-row external link (legal pages): the whole row is the tap target and
/// the trailing icon says it leaves the app.
class _LinkRow extends StatelessWidget {
  final String label;
  final Future<void> Function() onTap;

  const _LinkRow({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinTouchTarget),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
            Icon(Icons.open_in_new,
                size: 18, color: theme.colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// Focused editor for the display name. Pops the trimmed name on save, null
/// on cancel; the controller's lifecycle follows the route (disposed after
/// the exit animation), same as [_DeleteAccountDialog].
class _EditNameDialog extends StatefulWidget {
  final String initial;

  const _EditNameDialog({required this.initial});

  @override
  State<_EditNameDialog> createState() => _EditNameDialogState();
}

class _EditNameDialogState extends State<_EditNameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.settingsEditNameTitle),
      // Wider than the AlertDialog minimum so the field's floating label
      // renders whole at rest (the dialog otherwise hugs its two buttons).
      content: SizedBox(
        width: _kDialogFieldWidth,
        child: TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l10n.settingsDisplayName,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(l10n.settingsSaveName),
        ),
      ],
    );
  }
}

/// Focused editor for a password change. Pops (current, new) on submit, null
/// on cancel; confirm stays disabled until both fields have content so the
/// server round-trip can't start half-filled.
class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _currentController = TextEditingController();
  final _newController = TextEditingController();

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_currentController.text.isEmpty || _newController.text.isEmpty) return;
    Navigator.of(context).pop((_currentController.text, _newController.text));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      // Two focusable fields: let the dialog scroll when the keyboard
      // shrinks it on small phones.
      scrollable: true,
      title: Text(l10n.settingsPasswordSection),
      // Wider than the AlertDialog minimum so the long password labels
      // ("New password (8+ characters)" and its Spanish sibling) render
      // whole at rest instead of ellipsizing.
      content: SizedBox(
        width: _kDialogFieldWidth,
        child: AutofillGroup(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _currentController,
                obscureText: true,
                autofocus: true,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: l10n.settingsCurrentPassword,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _newController,
                obscureText: true,
                autofillHints: const [AutofillHints.newPassword],
                decoration: InputDecoration(
                  labelText: l10n.settingsNewPassword,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        ListenableBuilder(
          listenable: Listenable.merge([_currentController, _newController]),
          builder: (context, _) => FilledButton(
            onPressed:
                _currentController.text.isEmpty || _newController.text.isEmpty
                    ? null
                    : _submit,
            child: Text(l10n.settingsChangePassword),
          ),
        ),
      ],
    );
  }
}

/// Password-gated confirmation for account deletion. Pops the typed password
/// on confirm, null on cancel. A widget of its own so the controller's
/// lifecycle follows the route (disposed after the exit animation finishes).
class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog();

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _pwController = TextEditingController();

  @override
  void dispose() {
    _pwController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      // Long body copy + a focusable field: let the dialog scroll when the
      // keyboard shrinks it on small phones.
      scrollable: true,
      title: Text(l10n.settingsDeleteAccountTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.settingsDeleteAccountBody),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _pwController,
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
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        // The password is the safety mechanism for an irreversible action:
        // keep the destructive button disabled until something is typed.
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _pwController,
          builder: (context, value, _) => FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: value.text.isEmpty
                ? null
                : () => Navigator.of(context).pop(_pwController.text),
            child: Text(l10n.settingsDeleteForever),
          ),
        ),
      ],
    );
  }
}

/// Light/dark appearance choice (specs/dark-mode).
///
/// "Use device setting" is a live mode, not a resolved-once default: with it
/// selected the app follows OS appearance changes as they happen. The choice
/// is stored on this device only — appearance has no server-rendered
/// counterpart, so unlike the language it never syncs to the account.
class _AppearancePicker extends ConsumerWidget {
  const _AppearancePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final mode = ref.watch(themeModeProvider.select((s) => s.mode));

    // One source for both `items` and `selectedItemBuilder`: the two lists
    // must stay index-parallel, and deriving them can't drift.
    final options = <(ThemeMode, String)>[
      (ThemeMode.system, l10n.appearanceSystem),
      (ThemeMode.light, l10n.appearanceLight),
      (ThemeMode.dark, l10n.appearanceDark),
    ];

    return DropdownButtonFormField<ThemeMode>(
      // Not just an initial value: the field re-syncs whenever this changes,
      // so it still tracks a mode set from somewhere else.
      initialValue: mode,
      isExpanded: true,
      // Null lets a menu row grow to fit a wrapped label instead of clipping
      // it at the fixed 48px (DropdownMenuItem keeps that as a minimum, so
      // the touch target survives) — headroom for the long translations,
      // e.g. Spanish's "Usar la configuración del dispositivo".
      itemHeight: null,
      // The row's own label names the setting, so the field carries none.
      // The closed field ellipsizes to one line so a long label can never
      // grow the row; the open menu still spells each option out in full.
      selectedItemBuilder: (context) => [
        for (final (_, label) in options)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
      ],
      items: [
        for (final (value, label) in options)
          DropdownMenuItem(value: value, child: Text(label)),
      ],
      onChanged: (v) {
        if (v != null) ref.read(themeModeProvider.notifier).setMode(v);
      },
    );
  }
}

/// Language selection (specs/i18n-spanish).
///
/// The device language (or English) is resolved and stored at first launch,
/// so a concrete language is always selected here. A choice made on this
/// device syncs to the account, which is what makes it carry to a second
/// device and to the emails the server sends.
///
/// Options are built from [kSupportedLocales] rather than hardcoded, so
/// enabling a language stays a one-line change.
class _LanguagePicker extends ConsumerWidget {
  const _LanguagePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final state = ref.watch(localeProvider);

    return DropdownButtonFormField<String>(
      initialValue: state.language,
      isExpanded: true,
      itemHeight: null,
      selectedItemBuilder: (context) => [
        for (final locale in kSupportedLocales)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              languageDisplayName(l10n, locale.languageCode),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      items: [
        for (final locale in kSupportedLocales)
          DropdownMenuItem(
            value: locale.languageCode,
            child: Text(languageDisplayName(l10n, locale.languageCode)),
          ),
      ],
      onChanged: (v) {
        if (v != null) ref.read(localeProvider.notifier).setLanguage(v);
      },
    );
  }
}

/// The AI connectors this account has authorized (specs/mcp-connector), with
/// a revoke that takes effect immediately. Self-loading and self-contained so
/// the settings screen's own busy/error plumbing stays untouched.
class _ConnectedAppsList extends ConsumerStatefulWidget {
  const _ConnectedAppsList();

  @override
  ConsumerState<_ConnectedAppsList> createState() => _ConnectedAppsListState();
}

class _ConnectedAppsListState extends ConsumerState<_ConnectedAppsList> {
  late Future<List<ConnectedApp>> _future;
  String? _revoking;

  @override
  void initState() {
    super.initState();
    _future = ref.read(accountApiServiceProvider).listConnectedApps();
  }

  void _reload() {
    setState(() {
      _future = ref.read(accountApiServiceProvider).listConnectedApps();
    });
  }

  Future<void> _revoke(ConnectedApp app) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsRevokeConfirmTitle(app.clientName)),
        content: Text(l10n.settingsRevokeConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.settingsRevokeAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _revoking = app.id);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(accountApiServiceProvider).revokeConnectedApp(app.id);
      if (!mounted) return;
      messenger.showSnackBar(
          SnackBar(content: Text(l10n.settingsRevokedToast(app.clientName))));
      _reload();
    } catch (_) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text(l10n.errorGeneric)));
      }
    } finally {
      if (mounted) setState(() => _revoking = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    return FutureBuilder<List<ConnectedApp>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Text(l10n.settingsConnectedAppsError,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error)),
          );
        }
        final apps = snap.data ?? const <ConnectedApp>[];
        if (apps.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: Text(l10n.settingsConnectedAppsEmpty,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, app) in apps.indexed) ...[
              if (i > 0) const _RowDivider(),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: kMinTouchTarget),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: Row(
                    children: [
                      Icon(Icons.smart_toy_outlined,
                          size: 20, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              app.clientName,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w500),
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              app.lastUsedAt != null
                                  ? l10n.settingsConnectedLastUsed(shortDate(
                                      app.lastUsedAt!.toIso8601String()))
                                  : l10n.settingsConnectedNeverUsed,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      if (_revoking == app.id)
                        const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                      else
                        TextButton(
                          onPressed: () => _revoke(app),
                          child: Text(l10n.settingsRevokeAction),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
