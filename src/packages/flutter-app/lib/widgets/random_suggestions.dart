import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../providers/suggestions_provider.dart';

/// A drawn prompt with everything a surface needs to render it: the localized
/// text — which is also exactly what gets sent — and its destination photo.
///
/// Resolution stays inside [RandomSuggestions] rather than at each call site,
/// so the "a locale switch relabels the same picks" contract below has one
/// implementation. The home hero uses only [text].
typedef ResolvedSuggestion = ({String text, String asset, String credit});

/// Draws prompts from [suggestionPool] once per element lifetime and hands
/// them, resolved, to [builder].
///
/// One draw per mount is the contract: picks stay stable across rebuilds
/// (locale, theme, app-bar state) and re-roll on remount — the chat panel
/// swaps its empty state out when a conversation starts and back in on
/// reset, which is what makes each fresh chat (and each web page load) get
/// new picks. For that to work this widget must sit INSIDE the subtree that
/// unmounts, never above the ChatPanel empty-state swap.
class RandomSuggestions extends ConsumerStatefulWidget {
  final Widget Function(
      BuildContext context, List<ResolvedSuggestion> prompts) builder;

  /// Which draw to make: [suggestionPickerProvider] for the home hero's
  /// [kSuggestionCount] chips, [suggestionOrderProvider] for the destination
  /// rails' whole shuffled pool. Required, not defaulted: a surface's
  /// count is something it states, never something it inherits.
  final Provider<List<int> Function()> picker;

  const RandomSuggestions({
    super.key,
    required this.builder,
    required this.picker,
  });

  @override
  ConsumerState<RandomSuggestions> createState() => _RandomSuggestionsState();
}

class _RandomSuggestionsState extends ConsumerState<RandomSuggestions> {
  late final List<int> _picks;

  @override
  void initState() {
    super.initState();
    _picks = ref.read(widget.picker)();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return widget.builder(context, [
      for (final i in _picks)
        (
          text: suggestionPool[i].label(l10n),
          asset: photoFor(suggestionPool[i]).asset,
          credit: photoFor(suggestionPool[i]).credit,
        ),
    ]);
  }
}
