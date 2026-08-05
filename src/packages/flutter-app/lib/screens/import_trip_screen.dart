import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../navigation/app_nav.dart';
import '../navigation/app_routes.dart';
import '../providers/import_trip_provider.dart';
import '../theme/spacing.dart';
import '../widgets/gradient_app_bar.dart';
import '../widgets/page_container.dart';
import 'trip_detail_screen.dart';

/// Paste a ChatGPT/Claude conversation (or its final summary), get a real trip
/// (specs/import-trip-from-ai-chat). Also hands out the planning prompt the
/// user can seed their AI chat with so the conversation ends in an
/// import-friendly TRIP SUMMARY.
class ImportTripScreen extends ConsumerStatefulWidget {
  const ImportTripScreen({super.key});

  @override
  ConsumerState<ImportTripScreen> createState() => _ImportTripScreenState();
}

class _ImportTripScreenState extends ConsumerState<ImportTripScreen> {
  final _controller = TextEditingController();

  // Extraction takes 5–20s; a single request with cosmetic staged copy beats a
  // silent spinner. The timer only flips which stage line is shown.
  Timer? _stageTimer;
  bool _lateStage = false;

  @override
  void dispose() {
    _stageTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _copyPrompt() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: l10n.importPlanningPrompt));
    messenger.showSnackBar(SnackBar(content: Text(l10n.importPromptCopied)));
  }

  Future<void> _pasteFromClipboard() async {
    ClipboardData? data;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } catch (_) {
      // Web clipboard read can be denied by the browser; the user can still
      // paste natively into the field.
      return;
    }
    final text = data?.text;
    if (text == null || text.isEmpty || !mounted) return;
    setState(() => _controller.text = text);
  }

  Future<void> _import() async {
    FocusScope.of(context).unfocus();
    setState(() => _lateStage = false);
    _stageTimer?.cancel();
    _stageTimer = Timer(const Duration(seconds: 7), () {
      if (mounted) setState(() => _lateStage = true);
    });

    final res = await ref
        .read(importTripProvider.notifier)
        .import(_controller.text.trim());
    _stageTimer?.cancel();
    if (!mounted || res == null) return;

    if (res.warnings.isNotEmpty) {
      await _showWarnings(res.warnings);
      if (!mounted) return;
    }
    Navigator.of(context).pushReplacement(
      locatedRoute(
          TripDetailScreen(tripId: res.tripId), tripDetailLocation(res.tripId)),
    );
  }

  Future<void> _showWarnings(List<String> warnings) {
    final l10n = context.l10n;
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.importWarningsTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final w in warnings)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('•  '),
                      Expanded(child: Text(w)),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.importViewTrip),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = context.l10n;
    final state = ref.watch(importTripProvider);
    final hasText = _controller.text.trim().isNotEmpty;

    return Scaffold(
      appBar: GradientAppBar(title: Text(l10n.importFromAi)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          PageContainer(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.importExplainer,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: AppSpacing.md),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    OutlinedButton.icon(
                      onPressed: state.importing ? null : _copyPrompt,
                      icon: const Icon(Icons.copy_outlined, size: 18),
                      label: Text(l10n.importCopyPrompt),
                    ),
                    OutlinedButton.icon(
                      onPressed: state.importing ? null : _pasteFromClipboard,
                      icon: const Icon(Icons.content_paste_outlined, size: 18),
                      label: Text(l10n.importPasteButton),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _controller,
                  enabled: !state.importing,
                  minLines: 10,
                  maxLines: 20,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: l10n.importPasteHint,
                    border: const OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                if (state.error != null) ...[
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: Text(
                      state.error!.isNotEmpty
                          ? state.error!
                          : l10n.errorGeneric,
                      style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onErrorContainer),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                if (state.importing) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    _lateStage
                        ? l10n.importProgressLocating
                        : l10n.importProgressReading,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                FilledButton.icon(
                  onPressed: state.importing || !hasText ? null : _import,
                  icon: const Icon(Icons.auto_awesome),
                  label: Text(l10n.importButton),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
