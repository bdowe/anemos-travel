import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../utils/geolocation_stub.dart'
    if (dart.library.js_interop) '../utils/geolocation_web.dart';

/// "What's near me?" conversation starter (specs-free sibling of the
/// suggestion chips): one tap grabs a browser geolocation fix and sends a
/// seeded plan-chat message asking what's good around the traveler right now.
///
/// The seed carries the coordinates in its text — the server's search_nearby
/// tool reads them from the message stream — while [PlanNotifier.sendMessage]'s
/// `displayLabel` renders it as a compact "Near my current location" context
/// chip instead of a coordinate-bearing bubble.
///
/// When no fix is available (permission denied, non-web build, timeout), a
/// small dialog asks the traveler to type a city or neighborhood instead; that
/// branch sends a natural-language message with no coordinates and no label.
class NearMeChip extends StatefulWidget {
  /// Delivers the composed message; hosts either send directly on the plan
  /// notifier (Agent tab) or switch tabs first (Home).
  final void Function(String text, {String? displayLabel}) onSend;

  /// Styling knobs so the chip can sit among the white-on-photo hero chips as
  /// well as default Material chips. Null keeps the ambient chip theme.
  final Color? backgroundColor;
  final Color? foregroundColor;
  final TextStyle? labelStyle;

  /// Takes the chip's short spelling — the same idiom [ChatPanel] uses for its
  /// composer hint. Set by hosts whose panel is too narrow for the full label
  /// to share a row: "¿Qué hay cerca de mí?" is 210px, so the Plan tab's
  /// opening wrapped to a second row of chips in Spanish and pushed its own
  /// composer under the nav bar.
  final bool compact;

  const NearMeChip({
    super.key,
    required this.onSend,
    this.backgroundColor,
    this.foregroundColor,
    this.labelStyle,
    this.compact = false,
  });

  @override
  State<NearMeChip> createState() => _NearMeChipState();
}

class _NearMeChipState extends State<NearMeChip> {
  bool _locating = false;

  Future<void> _locate() async {
    setState(() => _locating = true);
    final result = await getCurrentPosition();
    if (!mounted) return;
    setState(() => _locating = false);

    final l10n = context.l10n;
    if (result.ok) {
      // Coordinates arrive pre-rounded to 4 decimals (~11 m) from the
      // geolocation util — the exact position never enters the transcript.
      widget.onSend(
        l10n.nearMeSeedMessage(
          result.latitude!.toStringAsFixed(4),
          result.longitude!.toStringAsFixed(4),
          (result.accuracyMeters ?? 0).round().toString(),
        ),
        displayLabel: l10n.nearMeSeedLabel,
      );
      return;
    }

    final place = await showDialog<String>(
      context: context,
      builder: (_) => const _NearMeLocationDialog(),
    );
    if (!mounted || place == null || place.trim().isEmpty) return;
    widget.onSend(context.l10n.nearMeManualMessage(place.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.foregroundColor;
    return ActionChip(
      avatar: _locating
          ? SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          : Icon(Icons.my_location, size: 16, color: color),
      label: Text(
        widget.compact
            ? context.l10n.nearMeChipLabelShort
            : context.l10n.nearMeChipLabel,
        style: widget.labelStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      backgroundColor: widget.backgroundColor,
      side: widget.backgroundColor != null ? BorderSide.none : null,
      onPressed: _locating ? null : _locate,
    );
  }
}

/// Fallback location entry when no geolocation fix is available. Pops with the
/// typed place name, or null on cancel.
class _NearMeLocationDialog extends StatefulWidget {
  const _NearMeLocationDialog();

  @override
  State<_NearMeLocationDialog> createState() => _NearMeLocationDialogState();
}

class _NearMeLocationDialogState extends State<_NearMeLocationDialog> {
  final _controller = TextEditingController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) setState(() => _hasText = hasText);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final place = _controller.text.trim();
    if (place.isEmpty) return;
    Navigator.of(context).pop(place);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.nearMeDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.nearMeDialogMessage),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(hintText: l10n.nearMeDialogHint),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        FilledButton(
          onPressed: _hasText ? _submit : null,
          child: Text(l10n.nearMeDialogCta),
        ),
      ],
    );
  }
}
