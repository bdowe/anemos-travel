import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../providers/suggestions_provider.dart';

/// Draws [kSuggestionCount] random prompts from [suggestionPool] once per
/// element lifetime and hands their localized labels to [builder].
///
/// One draw per mount is the contract: picks stay stable across rebuilds
/// (locale, theme, app-bar state) and re-roll on remount — the chat panel
/// swaps its empty state out when a conversation starts and back in on
/// reset, which is what makes each fresh chat (and each web page load) get
/// new picks. For that to work this widget must sit INSIDE the subtree that
/// unmounts, never above the ChatPanel empty-state swap.
class RandomSuggestions extends ConsumerStatefulWidget {
  final Widget Function(BuildContext context, List<String> prompts) builder;

  const RandomSuggestions({super.key, required this.builder});

  @override
  ConsumerState<RandomSuggestions> createState() => _RandomSuggestionsState();
}

class _RandomSuggestionsState extends ConsumerState<RandomSuggestions> {
  late final List<int> _picks;

  @override
  void initState() {
    super.initState();
    _picks = ref.read(suggestionPickerProvider)();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return widget.builder(
      context,
      [for (final i in _picks) suggestionPool[i](l10n)],
    );
  }
}
