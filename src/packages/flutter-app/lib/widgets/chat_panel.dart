import 'dart:math' show min;
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import '../l10n/l10n.dart';
import '../models/plan_message.dart';
import '../providers/auth_provider.dart';
import '../providers/api_client_provider.dart';
import '../providers/dictation_provider.dart';
import '../providers/plan_provider.dart';
import '../services/dictation_controller.dart';
import '../services/image_attachment_pipeline.dart';
import '../theme/app_colors.dart';
import '../theme/app_shadows.dart';
import '../theme/spacing.dart';
import '../utils/errors.dart';
import '../utils/clipboard_images_stub.dart'
    if (dart.library.js_interop) '../utils/clipboard_images_web.dart';
import '../utils/place_links.dart';
import '../utils/money_format.dart';
import '../utils/tracked_launch.dart';
import 'add_to_trip_sheet.dart';
import 'place_photo_card.dart';
import 'source_links_card.dart';
import 'result_summary_chip.dart';

/// The panel height below which the Plan tab's empty state keeps the
/// composer on the floor and scrolls the intro, instead of joining them
/// into one [intro, gap, composer] group.
///
/// Height is what is asked because height is what runs out (the rule
/// _PlanIntro's old field floor stated): a 568pt phone offers the panel
/// ~510px once the app bar is gone, and an open keyboard takes most of any
/// field — both must keep the composer at the floor, which is the layout
/// the app has always had. The joined group measures ~471px at default
/// text scale (browser-measured at 1440x900: intro 263→634, the 33px seam,
/// composer 667→734), so 650 admits it with at least ~100px of air above
/// and ~75 below — less, and the split reads as crowding rather than
/// composition.
const double _kComposerJoinFloor = 650;

/// Where the Plan tab's joined [intro, gap, composer] group sits in its
/// field, as an [Alignment] y. 1/7 splits the leftover air 4:3 above/below:
/// at the 938px field this composition was measured against that is ~215
/// over ~156 — the heading holds the position #517 set for it while the
/// 268px void #520 left between the block and the input closes.
const double _kComposerGroupBias = 1 / 7;

/// The plan-agent chat surface (messages, tool chips, result chips, input bar)
/// decoupled from any screen, so the full-screen Agent tab and the trip-detail
/// refine panel share one implementation. The provider pair is passed in:
/// AgentScreen hands the global [planProvider], the refine panel hands its
/// per-trip [tripRefineProvider] instance.
///
/// Streamed tokens arrive many times per frame, so the widget tree is split so
/// a token flush rebuilds only the streaming bubble: committed messages live in
/// a keyed ListView.builder, and the live tail (_ChatTail) is a column of leaf
/// widgets each watching a narrow select of PlanState.
class ChatPanel extends ConsumerStatefulWidget {
  final ProviderListenable<PlanState> state;
  final ProviderListenable<PlanNotifier> notifier;

  /// Composer placeholder. Null falls back to the generic localized hint —
  /// a default can't be a const literal now that it is translated.
  final String? inputHint;

  /// A shorter spelling of [inputHint], used when the composer measures too
  /// narrow for the full one. Null falls back to the generic short hint.
  final String? shortInputHint;

  /// Shown instead of the message list while the conversation is empty.
  final Widget? emptyState;

  /// Optional extra content rendered after the messages (e.g. the Agent tab's
  /// completed-itinerary banner).
  final Widget Function(BuildContext context, PlanState state)? footerBuilder;

  /// When set, result summary chips (flights, events, local picks, ferries)
  /// become tappable once a trip id exists and open that trip. The refine
  /// panel leaves this null — the trip is already on screen.
  final void Function(String tripId)? onViewTrip;

  /// Downscale/validate stage for attached images. Injectable for tests.
  final ImageAttachmentPipeline attachmentPipeline;

  /// Source for the paperclip button, returning (bytes, mimeType) pairs.
  /// Defaults to the platform file picker; injectable for tests.
  final Future<List<(Uint8List, String)>> Function()? pickImages;

  /// Renders the composer as a rounded floating card instead of a full-bleed
  /// bottom bar. Set by hosts that width-cap the panel mid-screen (the 760px
  /// Agent column); the refine dock and mobile sheet keep the default.
  final bool floatingComposer;

  const ChatPanel({
    super.key,
    required this.state,
    required this.notifier,
    this.inputHint,
    this.shortInputHint,
    this.emptyState,
    this.footerBuilder,
    this.onViewTrip,
    this.attachmentPipeline = const ImageAttachmentPipeline(),
    this.pickImages,
    this.floatingComposer = false,
  });

  @override
  ConsumerState<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends ConsumerState<ChatPanel> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocus = FocusNode();

  /// Removes the web paste listener (no-op off web).
  late final void Function() _cancelPasteListener;

  /// Voice dictation for this composer (specs/voice-dictation): writes
  /// transcripts into [_controller]; the user reviews and sends normally.
  late final DictationController _dictation;

  /// Autoscroll follows the stream only while the user is at the bottom;
  /// scrolling up to re-read pauses it until they return to the bottom.
  bool _stickToBottom = true;

  /// At most one bottom-jump pending per frame, no matter how many state
  /// changes request one.
  bool _scrollScheduled = false;

  /// Images attached but not yet sent (specs/chat-image-attachments), shown as
  /// removable chips above the input bar.
  final List<PlanAttachment> _pending = [];

  /// Images currently going through the downscale pipeline (spinner chips);
  /// sending is deferred until this reaches zero. Deliberately NOT part of the
  /// kept draft: the `await` it counts cannot outlive this State, so an image
  /// still being downscaled when the panel closes is genuinely gone.
  int _processingCount = 0;

  /// Which kept draft is ours — see [chatDraftKeyFor].
  late final String _draftKey;

  /// Whether a drag hovers over the panel — drives the drop overlay.
  bool _dragging = false;

  static const _maxAttachments = 4;

  @override
  void initState() {
    super.initState();
    // Fixed for this panel's life: a notifier's tripId is final, and neither
    // host ever swaps the notifier it passes.
    _draftKey = chatDraftKeyFor(ref.read(widget.notifier).tripId);
    _restoreDraft();
    _dictation = ref.read(dictationControllerFactoryProvider)(_controller);
    _dictation.addListener(_onDictationChanged);
    // Paste-from-clipboard (web only): focus-gated so exactly one mounted
    // panel handles a paste, and pastes outside the composer are untouched.
    _cancelPasteListener = listenForPastedImages(
      () => mounted && _inputFocus.hasFocus,
      (files) {
        if (mounted) _addFiles(files);
      },
    );
  }

  /// Puts back whatever was composed and not sent before this panel was last
  /// torn down. Called from `initState` only — never from `build`, where it
  /// would clobber the character just typed.
  ///
  /// `read`, never `watch`: the draft is written on every keystroke, so
  /// watching it would rebuild the whole transcript per character.
  void _restoreDraft() {
    final draft = ref.read(chatDraftProvider(_draftKey));
    // Never assign `controller.text` — that setter parks the selection at
    // offset -1, which the engine normalizes to 0, so the next keystroke lands
    // in *front* of the restored text (see airport_field.dart).
    _controller.value = TextEditingValue(
      text: draft.text,
      selection: TextSelection.collapsed(offset: draft.text.length),
    );
    _pending.addAll(draft.attachments);
    // After the seed, so restoring cannot echo back into the draft it read.
    _controller.addListener(_saveDraft);
  }

  /// Records the composer as it stands. Called on every change rather than on
  /// the way out: this panel is unmounted without warning — closing it, and
  /// the trip body re-inflating when it opens or crosses the docked width —
  /// and by the time `dispose` runs the element is already unmounted, so `ref`
  /// throws there.
  void _saveDraft() => ref
      .read(chatDraftProvider(_draftKey).notifier)
      .setText(_controller.text);

  /// The attachment half. Separate from [_saveDraft] because the two are
  /// edited by different gestures and the list write copies.
  void _saveDraftAttachments() => ref
      .read(chatDraftProvider(_draftKey).notifier)
      .setAttachments(_pending);

  void _onDictationChanged() {
    final error = _dictation.consumeError();
    if (error != null && mounted) {
      final l10n = context.l10n;
      final message = switch (error) {
        DictationError.permissionBlocked => l10n.chatDictationPermission,
        DictationError.unsupportedBrowser => l10n.chatDictationUnsupported,
        DictationError.unavailable => l10n.chatDictationUnavailable,
        DictationError.transcriptionFailed => l10n.chatDictationFailed,
      };
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  void dispose() {
    _cancelPasteListener();
    _dictation.removeListener(_onDictationChanged);
    _dictation.dispose();
    _controller.dispose();
    _scrollController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (_stickToBottom && _scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  // Only UserScrollNotification flips the flag off — the programmatic jumpTo
  // emits only ScrollUpdateNotifications, so it can't disarm itself.
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is UserScrollNotification &&
        notification.direction == ScrollDirection.forward) {
      _stickToBottom = false;
    } else if (notification is ScrollUpdateNotification) {
      final position = notification.metrics;
      if (position.pixels >= position.maxScrollExtent - 50) {
        _stickToBottom = true;
      }
    }
    return false;
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty && _pending.isEmpty) return;
    if (_processingCount > 0) {
      _notify(context.l10n.chatStillPreparingImage);
      return;
    }
    final attachments = List<PlanAttachment>.of(_pending);
    _controller.clear();
    setState(_pending.clear);
    // One call for both halves — and the only thing that frees the kept
    // attachment bytes.
    ref.read(chatDraftProvider(_draftKey).notifier).clear();
    ref.read(widget.notifier).sendMessage(text, attachments: attachments);
    _stickToBottom = true;
    _scrollToBottom();
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Single intake seam: drag-drop, the paperclip picker, and any future
  /// paste path all feed (bytes, mimeType) pairs through here.
  Future<void> _addFiles(Iterable<(Uint8List, String)> files) async {
    // Resolved up front: the loop awaits, so a later lookup could run against
    // an unmounted State.
    final l10n = context.l10n;
    for (final (bytes, mime) in files) {
      if (_pending.length + _processingCount >= _maxAttachments) {
        _notify(l10n.chatAttachLimit(_maxAttachments));
        return;
      }
      setState(() => _processingCount++);
      final attachment = await widget.attachmentPipeline.process(bytes, mime);
      if (!mounted) return;
      setState(() {
        _processingCount--;
        if (attachment != null) _pending.add(attachment);
      });
      if (attachment != null) _saveDraftAttachments();
      if (attachment == null) {
        _notify(l10n.chatImageUnreadable);
      }
    }
  }

  Future<void> _pickImages() async {
    final pick = widget.pickImages ?? _pickImagesFromPlatform;
    final files = await pick();
    if (files.isNotEmpty) await _addFiles(files);
  }

  static Future<List<(Uint8List, String)>> _pickImagesFromPlatform() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: true,
    );
    if (result == null) return const [];
    return [
      for (final f in result.files)
        if (f.bytes != null) (f.bytes!, _mimeFromName(f.name)),
    ];
  }

  Future<void> _onDragDone(DropDoneDetails detail) async {
    final l10n = context.l10n;
    final files = <(Uint8List, String)>[];
    for (final item in detail.files) {
      final mime = (item.mimeType?.isNotEmpty ?? false)
          ? item.mimeType!
          : _mimeFromName(item.name);
      if (!mime.startsWith('image/')) continue;
      files.add((await item.readAsBytes(), mime));
    }
    if (!mounted) return;
    if (files.isEmpty) {
      _notify(l10n.chatOnlyImages);
      return;
    }
    await _addFiles(files);
  }

  static String _mimeFromName(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg',
      'png' => 'image/png',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      _ => 'application/octet-stream',
    };
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(widget.state.select((s) => s.messages));
    final isStreaming = ref.watch(widget.state.select((s) => s.isStreaming));
    final isEmpty = ref.watch(widget.state.select((s) =>
        s.messages.isEmpty &&
        s.streamingText == null &&
        s.queuedMessages.isEmpty));

    // External draft-text writes (the pending-prompt resume,
    // specs/landing-prompt-handoff) reach a MOUNTED composer too — without
    // this an external chatDraftProvider write lands only on the next
    // remount's _restoreDraft, a silent-loss window. Loop-safe: _saveDraft
    // echoes every keystroke into the provider, so for our own edits `next`
    // already equals the controller text and the guard no-ops.
    ref.listen(chatDraftProvider(_draftKey).select((d) => d.text), (_, next) {
      if (next == _controller.text) return;
      // Never assign controller.text — that parks the caret at -1 (see
      // _restoreDraft).
      _controller.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      );
    });

    ref.listen(widget.state.select((s) => s.streamingText),
        (_, __) => _scrollToBottom());
    ref.listen(widget.state.select((s) => s.messages.length),
        (_, __) => _scrollToBottom());
    ref.listen(widget.state.select((s) => s.queuedMessages.length),
        (_, __) => _scrollToBottom());
    // Working indicators (tool chips, typing dots, summarizing chip) grow the
    // tail below the last text — without a scroll they can appear out of view
    // and the turn looks stalled. _scrollToBottom itself keeps respecting the
    // user's upward-scroll disarm.
    ref.listen(widget.state.select((s) => s.activeTools.length),
        (_, __) => _scrollToBottom());
    ref.listen(
        widget.state.select((s) => s.isThinking), (_, __) => _scrollToBottom());
    ref.listen(widget.state.select((s) => s.isCompacting),
        (_, __) => _scrollToBottom());

    // LayoutBuilder (house rule: widths computed from the panel's own
    // constraints): the bubble cap must track the surface the panel actually
    // occupies — the 400px refine dock and the 760px agent column — not the
    // window, or dock bubbles run the full dock width on desktop.
    return LayoutBuilder(builder: (context, constraints) {
      final bubbleMaxWidth = _bubbleMaxWidthFor(constraints.maxWidth);
      // The composer and its pending-attachments row as ONE unit. On the
      // Plan tab's empty state it leaves the floor and joins the intro
      // block — see _kComposerJoinFloor — so it is built once, here, and
      // placed by the branch below rather than hard-coded to the column's
      // tail.
      final composer = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_pending.isNotEmpty || _processingCount > 0)
            _PendingAttachmentsRow(
              pending: _pending,
              processingCount: _processingCount,
              onRemove: (i) {
                setState(() => _pending.removeAt(i));
                _saveDraftAttachments();
              },
            ),
          _InputBar(
            controller: _controller,
            focusNode: _inputFocus,
            isStreaming: isStreaming,
            hint: widget.inputHint ?? context.l10n.chatInputHint,
            shortHint: widget.shortInputHint ?? context.l10n.chatInputHintShort,
            onSend: _send,
            onStop: () => ref.read(widget.notifier).stopStreaming(),
            hasDraftAttachments: _pending.isNotEmpty || _processingCount > 0,
            onAttach: _pickImages,
            dictation: _dictation,
            floating: widget.floatingComposer,
          ),
        ],
      );

      final Widget panel;
      if (isEmpty && widget.emptyState != null) {
        // The Plan tab before a word is typed. The gate is HEIGHT — the
        // thing that runs out — never width. Below the floor (a phone, an
        // open keyboard) the composer keeps the floor and the intro
        // scrolls, exactly as _PlanIntro's old field rule arranged. At or
        // above it the composer joins the block as [intro, gap,
        // composer], placed by _kComposerGroupBias. The scroll wrapper only
        // ever runs when text scaling makes the group taller than the
        // field.
        panel = constraints.maxHeight < _kComposerJoinFloor
            ? Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(top: AppSpacing.xl),
                      child: widget.emptyState!,
                    ),
                  ),
                  composer,
                ],
              )
            : Align(
                alignment: const Alignment(0, _kComposerGroupBias),
                // Loose constraints from Align, so the group shrink-wraps
                // unless the largest text scales make it taller than the
                // field — then it scrolls instead of overflowing.
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      widget.emptyState!,
                      const SizedBox(height: AppSpacing.lg),
                      composer,
                    ],
                  ),
                ),
              );
      } else {
        panel = Column(
          children: [
            Expanded(
              child: isEmpty
                  ? const SizedBox.shrink()
                  // SelectionArea wraps only the message list: the composer's
                  // TextField below has native selection and must keep its own
                  // gesture handling.
                  : SelectionArea(
                      child: NotificationListener<ScrollNotification>(
                        onNotification: _onScrollNotification,
                        child: ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.lg,
                              vertical: AppSpacing.md),
                          itemCount: messages.length + 1,
                          itemBuilder: (context, i) {
                            if (i < messages.length) {
                              final msg = messages[i];
                              // Labeled messages (e.g. the machine-built refine
                              // seed) collapse to a context chip; the full content
                              // still went to the server history.
                              if (msg.displayLabel != null) {
                                return _SeedContextChip(
                                  key: ValueKey('msg-$i'),
                                  label: msg.displayLabel!,
                                );
                              }
                              // Append-only list, so index keys are stable.
                              return ChatMessageBubble(
                                key: ValueKey('msg-$i'),
                                message: msg,
                                maxWidth: bubbleMaxWidth,
                              );
                            }
                            return _ChatTail(
                              key: const ValueKey('chat-tail'),
                              state: widget.state,
                              notifier: widget.notifier,
                              footerBuilder: widget.footerBuilder,
                              onViewTrip: widget.onViewTrip,
                              bubbleMaxWidth: bubbleMaxWidth,
                            );
                          },
                        ),
                      ),
                    ),
            ),
            composer,
          ],
        );
      }

      // DropTarget is a no-op on platforms without drag-drop (mobile), so the
      // wrap is unconditional. The overlay invites the drop while a drag
      // hovers.
      return DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (detail) {
          setState(() => _dragging = false);
          _onDragDone(detail);
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            panel,
            if (_dragging) const _DropOverlay(),
          ],
        ),
      );
    });
  }
}

/// Full-panel affordance shown while image files hover over the chat.
class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IgnorePointer(
      child: Container(
        color: theme.colorScheme.surface.withValues(alpha: 0.85),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.xl, vertical: 20),
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.primary, width: 2),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add_photo_alternate_outlined,
                    size: 40, color: theme.colorScheme.primary),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  context.l10n.chatDropImages,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Not-yet-sent attachment chips above the input bar: thumbnails with a
/// remove ✕, plus spinner chips while the pipeline processes new drops.
class _PendingAttachmentsRow extends StatelessWidget {
  final List<PlanAttachment> pending;
  final int processingCount;
  final void Function(int index) onRemove;

  const _PendingAttachmentsRow({
    required this.pending,
    required this.processingCount,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
      child: SizedBox(
        height: 64,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (var i = 0; i < pending.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: AppSpacing.sm),
                child: Stack(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6, right: 6),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.memory(
                          pending[i].bytes!,
                          width: 56,
                          height: 56,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                      ),
                    ),
                    // ≥ kMinTouchTarget hit box; the visible badge stays
                    // small and pinned to the thumbnail corner via the
                    // topRight alignment.
                    Positioned(
                      top: 0,
                      right: 0,
                      child: Semantics(
                        button: true,
                        label: context.l10n.chatRemoveImage,
                        child: SizedBox(
                          width: kMinTouchTarget,
                          height: kMinTouchTarget,
                          child: InkWell(
                            onTap: () => onRemove(i),
                            customBorder: const CircleBorder(),
                            child: Align(
                              alignment: Alignment.topRight,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.inverseSurface,
                                  shape: BoxShape.circle,
                                ),
                                padding: const EdgeInsets.all(2),
                                child: Icon(Icons.close,
                                    size: 12,
                                    color: theme.colorScheme.onInverseSurface),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            for (var i = 0; i < processingCount; i++)
              Padding(
                padding: const EdgeInsets.only(top: 6, right: 14),
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Everything below the committed messages — the live streaming bubble, tool
/// chips, result chips, footer, and error banner. Each child watches its own
/// narrow select so a token flush rebuilds only [_StreamingBubble].
class _ChatTail extends StatelessWidget {
  final ProviderListenable<PlanState> state;
  final ProviderListenable<PlanNotifier> notifier;
  final Widget Function(BuildContext context, PlanState state)? footerBuilder;
  final void Function(String tripId)? onViewTrip;
  final double bubbleMaxWidth;

  const _ChatTail({
    super.key,
    required this.state,
    required this.notifier,
    required this.footerBuilder,
    required this.onViewTrip,
    required this.bubbleMaxWidth,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Compaction runs before the model call, so its chip leads the tail.
        _CompactingChip(state: state),
        _TypingIndicatorBubble(state: state),
        _StreamingBubble(state: state, maxWidth: bubbleMaxWidth),
        _ActiveToolChips(state: state),
        _ProfileNoteChip(state: state),
        _ItineraryUpdatedChip(state: state),
        _ResultStrips(state: state, notifier: notifier, onViewTrip: onViewTrip),
        _ResultChips(state: state, notifier: notifier, onViewTrip: onViewTrip),
        _ResultLinks(state: state),
        _QuickReplyChips(state: state, notifier: notifier),
        if (footerBuilder != null)
          _ChatFooter(state: state, footerBuilder: footerBuilder!),
        _ErrorBanner(state: state, notifier: notifier),
        // Last: queued messages read as "up next", below the current turn and
        // any error it produced.
        _QueuedMessages(
          state: state,
          notifier: notifier,
          bubbleMaxWidth: bubbleMaxWidth,
        ),
      ],
    );
  }
}

class _StreamingBubble extends ConsumerWidget {
  final ProviderListenable<PlanState> state;
  final double maxWidth;

  const _StreamingBubble({required this.state, required this.maxWidth});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = ref.watch(state.select((s) => s.streamingText));
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    return ChatMessageBubble(
      message: PlanMessage(role: MessageRole.assistant, content: text),
      isStreaming: true,
      maxWidth: maxWidth,
    );
  }
}

/// Immediate "assistant is working" cue: an animated three-dot bubble shown
/// from the instant a turn starts (isStreaming flips synchronously on send,
/// before any SSE event arrives) until streamed text, a tool chip, or the
/// compacting chip takes over — and shown AGAIN below the streamed text
/// whenever the server signals `thinking` (waiting on the model between
/// steps, specs/chat-working-indicator). Since the model's first token clears
/// isThinking, the dots still never overlap an actively-streaming reply. Its
/// own leaf watching one derived bool, so token flushes never rebuild it.
class _TypingIndicatorBubble extends ConsumerWidget {
  final ProviderListenable<PlanState> state;

  const _TypingIndicatorBubble({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // streamingText is '' while a turn starts and null when idle; either way
    // no streaming bubble is visible yet.
    final visible = ref.watch(state.select((s) =>
        s.isStreaming &&
        (s.streamingText == null || s.streamingText!.isEmpty || s.isThinking) &&
        s.activeTools.isEmpty &&
        !s.isCompacting));
    if (!visible) return const SizedBox.shrink();
    return const _TypingDotsBubble(key: ValueKey('typing-indicator'));
  }
}

/// Assistant-styled bubble with three staggered rising/fading dots — the
/// familiar "typing" affordance, louder than the streaming caret.
class _TypingDotsBubble extends StatefulWidget {
  const _TypingDotsBubble({super.key});

  @override
  State<_TypingDotsBubble> createState() => _TypingDotsBubbleState();
}

class _TypingDotsBubbleState extends State<_TypingDotsBubble>
    with SingleTickerProviderStateMixin {
  // In the tree only while visible, so the controller's lifetime tracks
  // visibility for free (same pattern as _StreamingCursor).
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(4),
            bottomRight: Radius.circular(16),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++) ...[
              if (i > 0) const SizedBox(width: 5),
              _Dot(controller: _controller, index: i),
            ],
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final AnimationController controller;
  final int index;

  const _Dot({required this.controller, required this.index});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final animation = CurvedAnimation(
      parent: controller,
      curve: Interval(index * 0.2, index * 0.2 + 0.6, curve: Curves.easeInOut),
    );
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        // Rise-and-settle arc per cycle: 0→1→0 across the dot's interval.
        final t = animation.value;
        final wave = t < 0.5 ? t * 2 : (1 - t) * 2;
        return Transform.translate(
          offset: Offset(0, -3 * wave),
          child: Opacity(
            opacity: 0.25 + 0.65 * wave,
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant,
                shape: BoxShape.circle,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ActiveToolChips extends ConsumerWidget {
  final ProviderListenable<PlanState> state;

  const _ActiveToolChips({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeTools = ref.watch(state.select((s) => s.activeTools));
    if (activeTools.isEmpty) return const SizedBox.shrink();
    final l10n = context.l10n;
    // Parallel tool_use blocks announce one activeTools entry each; identical
    // labels collapse to one chip — the chip says what's happening, not how
    // many calls are in flight. Deduped on the rendered label (not the tool
    // name) so unnamed tools sharing the generic "Working..." collapse too;
    // the set keeps first-occurrence order, and the chip stays up until the
    // last same-label call finishes.
    final labels = <String>{
      for (final tool in activeTools) _toolLabel(l10n, tool),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Wrap(
        spacing: AppSpacing.sm,
        children: labels.map((label) {
          return Chip(
            avatar: const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            label: Text(label),
          );
        }).toList(),
      ),
    );
  }

  // `tool` is the canonical server tool name (never translated); only its
  // display label is localized.
  static String _toolLabel(AppLocalizations l10n, String tool) {
    switch (tool) {
      case 'search_places':
        return l10n.chatToolSearchPlaces;
      case 'create_itinerary':
        return l10n.chatToolCreateItinerary;
      case 'update_itinerary_section':
        return l10n.chatToolUpdateItinerary;
      case 'search_flights':
        return l10n.chatToolSearchFlights;
      case 'check_flight_connectivity':
        return l10n.chatToolCheckConnectivity;
      case 'search_events':
        return l10n.chatToolSearchEvents;
      case 'suggest_ferries':
        return l10n.chatToolSuggestFerries;
      case 'find_parking':
        return l10n.chatToolFindParking;
      case 'search_local_recommendations':
        return l10n.chatToolLocalRecs;
      case 'review_trip':
        return l10n.chatToolReviewTrip;
      case 'get_weather':
        return l10n.chatToolWeather;
      case 'search_nearby':
        return l10n.chatToolSearchNearby;
      case 'search_hotels':
        return l10n.chatToolSearchHotels;
      default:
        // Every other tool gets a real localized label, never the raw
        // snake_case name — quick writes flash by; naming them all would be
        // key sprawl for no clarity.
        return l10n.chatToolWorking;
    }
  }
}

/// Transient indicator that the server is summarizing the conversation's
/// older messages before this turn (SSE `compacting`); cleared by whatever
/// event follows.
class _CompactingChip extends ConsumerWidget {
  final ProviderListenable<PlanState> state;

  const _CompactingChip({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final compacting = ref.watch(state.select((s) => s.isCompacting));
    if (!compacting) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Chip(
          avatar: const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          label: Text(context.l10n.chatSummarizing),
        ),
      ),
    );
  }
}

class _ProfileNoteChip extends ConsumerWidget {
  final ProviderListenable<PlanState> state;

  const _ProfileNoteChip({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final note = ref.watch(state.select((s) => s.profileUpdateNote));
    if (note == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Tooltip(
          message: note.isEmpty ? context.l10n.chatProfileUpdatedTooltip : note,
          child: Chip(
            avatar: Icon(Icons.check_circle_outline,
                size: 16, color: theme.colorScheme.primary),
            label: Text(context.l10n.chatProfileUpdated),
          ),
        ),
      ),
    );
  }
}

/// Transient acknowledgment that the current turn patched the bound trip
/// (server `trip_updated` event — itinerary edits or booking-checklist
/// changes). Cleared at the start of the next send, mirroring the
/// profile-note chip lifecycle.
class _ItineraryUpdatedChip extends ConsumerWidget {
  final ProviderListenable<PlanState> state;

  const _ItineraryUpdatedChip({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updated = ref.watch(state.select((s) => s.tripUpdatedThisTurn));
    if (!updated) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Chip(
          avatar: Icon(Icons.check_circle_outline,
              size: 16, color: theme.colorScheme.primary),
          label: Text(context.l10n.chatTripUpdated),
        ),
      ),
    );
  }
}

/// Centered session marker rendered in place of a machine-built message (the
/// refine seed) — keeps the conversation readable without hiding that a new
/// refinement session started here.
class _SeedContextChip extends StatelessWidget {
  final String label;

  const _SeedContextChip({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Center(
        child: Chip(
          avatar: Icon(Icons.auto_awesome,
              size: 14, color: theme.colorScheme.onSurfaceVariant),
          label: Text(label),
          labelStyle: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          visualDensity: VisualDensity.compact,
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
    );
  }
}

/// Horizontal photo-card rails for the recommendation-shaped results (Google
/// places, local picks, events) — the sources where seeing the place matters.
/// Replaces those sources' summary chips; link-shaped results (flights,
/// ferries, event sources) stay chips in [_ResultChips]. Fixed-height rails,
/// single-slot per-turn state: images can pop in but never reflow the tail.
class _ResultStrips extends ConsumerWidget {
  final ProviderListenable<PlanState> state;
  final ProviderListenable<PlanNotifier> notifier;
  final void Function(String tripId)? onViewTrip;

  /// Cards per rail — matches the server's places cap; local picks/events are
  /// capped client-side to keep the rails skimmable.
  static const _maxCards = 8;

  const _ResultStrips({
    required this.state,
    required this.notifier,
    required this.onViewTrip,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Record equality compares the lists by identity, which works because the
    // provider replaces each list whole on its SSE event — never mutates one
    // in place (the _ResultChips invariant).
    final r = ref.watch(state.select((s) => (
          places: s.places,
          placesQuery: s.placesQuery,
          localRecs: s.localRecs,
          localRecsCity: s.localRecsCity,
          events: s.eventResults,
          eventsCity: s.eventsCityLabel,
          parkingSpots: s.parkingSpots,
          parkingBeach: s.parkingBeach,
          hotels: s.hotels,
          savedTripId: s.savedTripId,
        )));
    final signedIn = ref.watch(authProvider.select((s) => s.isSignedIn));
    final apiBase = ref.watch(apiClientProvider).baseUrl;
    final scheme = Theme.of(context).colorScheme;

    final tripId = r.savedTripId ?? ref.read(notifier).tripId;
    final onHeaderTap = (onViewTrip != null && tripId != null)
        ? () => onViewTrip!(tripId)
        : null;

    String label(String base, String? suffix) =>
        (suffix == null || suffix.trim().isEmpty) ? base : '$base · $suffix';

    Future<void> addToTrip(AddToTripPayload payload) async {
      await showAddToTripSheet(context, payload, currentTripId: tripId);
    }

    Future<void> openMaps(String name, String placeId) async {
      await trackedLaunchUrl(context, googleMapsSearchUrl(name, placeId),
          provider: 'google_maps', surface: 'chat_place_card');
    }

    String? photoUrl(String ref) =>
        ref.isEmpty ? null : placePhotoUrl(apiBase, ref);

    final l10n = context.l10n;
    final strips = <Widget>[
      if (r.places != null && r.places!.isNotEmpty)
        PlacePhotoStrip(
          icon: Icons.place_outlined,
          accent: scheme.primary,
          label: label(l10n.chatStripPlaces(r.places!.length), r.placesQuery),
          onViewTrip: onHeaderTap,
          cards: [
            for (final place in r.places!.take(_maxCards))
              PlacePhotoCard(
                data: PlaceCardData.place(place,
                    photoUrl: photoUrl(place.photoRef), scheme: scheme),
                onTap: () => openMaps(place.name, place.placeId),
                onAddToTrip: signedIn
                    ? () => addToTrip(AddToTripPayload.fromPlace(place))
                    : null,
              ),
          ],
        ),
      if (r.localRecs != null && r.localRecs!.isNotEmpty)
        PlacePhotoStrip(
          icon: Icons.verified,
          accent: AppColors.toolLocal(scheme.brightness),
          label: label(
              l10n.chatChipLocalPicks(r.localRecs!.length), r.localRecsCity),
          onViewTrip: onHeaderTap,
          cards: [
            for (final rec in r.localRecs!.take(_maxCards))
              PlacePhotoCard(
                data: PlaceCardData.localRec(rec,
                    photoUrl: photoUrl(rec.photoRef),
                    brightness: scheme.brightness),
                onTap: () => openMaps(rec.name, rec.placeId),
                onAddToTrip: signedIn
                    ? () => addToTrip(AddToTripPayload.fromLocalRec(rec))
                    : null,
              ),
          ],
        ),
      if (r.events != null && r.events!.isNotEmpty)
        PlacePhotoStrip(
          icon: Icons.local_activity,
          accent: AppColors.toolEvents(scheme.brightness),
          label: label(l10n.chatChipEvents(r.events!.length), r.eventsCity),
          onViewTrip: onHeaderTap,
          cards: [
            for (final event in r.events!.take(_maxCards))
              PlacePhotoCard(
                data: PlaceCardData.event(event, brightness: scheme.brightness),
                onTap: event.url.isEmpty
                    ? null
                    : () => trackedLaunchUrl(context, event.url,
                        provider: 'ticketmaster', surface: 'chat_event_card'),
                onAddToTrip: signedIn
                    ? () => addToTrip(AddToTripPayload.fromEvent(event))
                    : null,
              ),
          ],
        ),
      if (r.parkingSpots != null && r.parkingSpots!.isNotEmpty)
        PlacePhotoStrip(
          icon: Icons.local_parking,
          accent: AppColors.toolParking(scheme.brightness),
          label: label(
              l10n.chatStripParking(r.parkingSpots!.length), r.parkingBeach),
          onViewTrip: onHeaderTap,
          cards: [
            for (final spot in r.parkingSpots!.take(_maxCards))
              PlacePhotoCard(
                data: PlaceCardData.parking(spot,
                    photoUrl: photoUrl(spot.photoRef),
                    freeLabel: l10n.chatCardFreeListed,
                    brightness: scheme.brightness),
                onTap: () => openMaps(spot.name, spot.placeId),
                onAddToTrip: signedIn
                    ? () => addToTrip(AddToTripPayload.fromPlace(spot))
                    : null,
              ),
          ],
        ),
      if (r.hotels != null && r.hotels!.stays.isNotEmpty)
        PlacePhotoStrip(
          icon: Icons.hotel,
          accent: AppColors.toolStays(scheme.brightness),
          // The "no live rates" caveat rides the HEADER, not the cards: the
          // tier is a property of the whole result set, and a 200x160 card
          // showing a rating has no room for a disclaimer anyway.
          label: label(
            l10n.chatStripHotels(r.hotels!.stays.length),
            [
              if (r.hotels!.city.isNotEmpty) r.hotels!.city,
              if (!r.hotels!.ratesLive) l10n.chatStripHotelsNoRates,
            ].join(' · '),
          ),
          onViewTrip: onHeaderTap,
          cards: [
            for (final stay in r.hotels!.stays.take(_maxCards))
              PlacePhotoCard(
                data: PlaceCardData.hotel(
                  stay,
                  brightness: scheme.brightness,
                  photoUrl: stay.resolvedPhotoUrl(apiBase),
                  priceLabel: stay.ratePerNight == null || stay.currency == null
                      ? null
                      : l10n.chatCardPerNight(
                          formatMoney(stay.ratePerNight!, stay.currency!)),
                ),
                onTap: stay.bookingUrl.isEmpty
                    ? null
                    : () => trackedLaunchUrl(context, stay.bookingUrl,
                        provider: 'booking', surface: 'chat_hotel_card'),
              ),
          ],
        ),
    ];

    if (strips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch, children: strips),
    );
  }
}

/// One quiet summary line per result set the agent found. The full results
/// live on the trip detail screen (booking checklist, embedded events,
/// itinerary pins), so the chat only names what arrived and links there.
/// Recommendation-shaped results (places, local picks, events) render as
/// photo rails in [_ResultStrips] instead of chips here.
class _ResultChips extends ConsumerWidget {
  final ProviderListenable<PlanState> state;
  final ProviderListenable<PlanNotifier> notifier;
  final void Function(String tripId)? onViewTrip;

  const _ResultChips({
    required this.state,
    required this.notifier,
    required this.onViewTrip,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Record equality compares the lists by identity, which works because the
    // provider replaces each list whole on its SSE event — never mutates one
    // in place. In-place mutation would silently stop chip updates.
    final r = ref.watch(state.select((s) => (
          flights: s.flightOffers,
          flightRoute: s.flightRouteLabel,
          ferries: s.ferryOptions,
          ferryRoute: s.ferryRouteLabel,
          eventLinks: s.eventLinks,
          eventLinksCity: s.eventLinksCity,
          savedTripId: s.savedTripId,
        )));

    // Agent-tab chips are plain labels until `done` delivers savedTripId,
    // then flip tappable; the refine panel passes no onViewTrip at all.
    final tripId = r.savedTripId ?? ref.read(notifier).tripId;
    final onTap = (onViewTrip != null && tripId != null)
        ? () => onViewTrip!(tripId)
        : null;

    // The count phrase is a localized plural; the optional city/route suffix is
    // live data appended the same way in every language.
    String label(String base, String? suffix) =>
        (suffix == null || suffix.trim().isEmpty) ? base : '$base · $suffix';

    final l10n = context.l10n;
    final chips = <Widget>[
      if (r.flights != null && r.flights!.isNotEmpty)
        ResultSummaryChip(
          icon: Icons.flight,
          accent: AppColors.toolFlights(Theme.of(context).brightness),
          label: label(
              l10n.chatChipFlightOptions(r.flights!.length), r.flightRoute),
          onTap: onTap,
        ),
      if (r.ferries != null && r.ferries!.isNotEmpty)
        ResultSummaryChip(
          icon: Icons.directions_boat,
          accent: AppColors.toolFerries(Theme.of(context).brightness),
          label:
              label(l10n.chatChipFerryOptions(r.ferries!.length), r.ferryRoute),
          onTap: onTap,
        ),
      if (r.eventLinks != null && r.eventLinks!.isNotEmpty)
        ResultSummaryChip(
          icon: Icons.link,
          accent: AppColors.toolEvents(Theme.of(context).brightness),
          label: label(l10n.chatChipEventSources(r.eventLinks!.length),
              r.eventLinksCity),
          onTap: onTap,
        ),
    ];

    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child:
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: chips),
    );
  }
}

/// Browse-out links from `suggest_stays` / `suggest_transport`.
///
/// Both events were emitted by the server and had NO case in the client's
/// provider switch, so each tool rendered a working-chip that vanished leaving
/// no artifact at all — the traveler asked for lodging and got nothing
/// (docs/friction-log.md). They render as [SourceLinksCard] rather than a
/// [ResultSummaryChip] because these results ARE the links: a summary chip
/// opens the trip, which is not where an Airbnb search lives.
class _ResultLinks extends ConsumerWidget {
  final ProviderListenable<PlanState> state;

  const _ResultLinks({required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Same record-select invariant as the strips: the provider replaces each
    // list whole on its event, never mutates one in place.
    final r = ref.watch(state.select((s) => (
          stayLinks: s.stayLinks,
          stayWhere: s.stayLinksWhere,
          transportLinks: s.transportLinks,
          transportRoute: s.transportRoute,
        )));
    final l10n = context.l10n;

    String title(String base, String? suffix) =>
        (suffix == null || suffix.trim().isEmpty) ? base : '$base · $suffix';

    final cards = <Widget>[
      if (r.stayLinks != null && r.stayLinks!.isNotEmpty)
        SourceLinksCard(
          icon: Icons.hotel,
          accent: AppColors.toolStays(Theme.of(context).brightness),
          title: title(l10n.chatLinksStays, r.stayWhere),
          links: r.stayLinks!,
        ),
      if (r.transportLinks != null && r.transportLinks!.isNotEmpty)
        SourceLinksCard(
          icon: Icons.directions,
          accent: AppColors.toolFlights(Theme.of(context).brightness),
          title: title(l10n.chatLinksTransport, r.transportRoute),
          links: r.transportLinks!,
        ),
    ];

    if (cards.isEmpty) return const SizedBox.shrink();
    return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch, children: cards);
  }
}

/// One-tap quick replies for the assistant's last question (SSE
/// `suggest_replies`, specs/chat-quick-replies). Shown only once the turn has
/// settled: hidden while streaming (the terminal agent-loop iteration is
/// still running when the event arrives) and while a queued follow-up
/// supersedes the question; cleared upstream on send, error, and reset. The
/// chip text is BOTH what the traveler reads and what gets sent — the server
/// generates it in the conversation language, matching the
/// display-text==sent-text rule of the starter suggestion chips.
class _QuickReplyChips extends ConsumerWidget {
  final ProviderListenable<PlanState> state;
  final ProviderListenable<PlanNotifier> notifier;

  const _QuickReplyChips({required this.state, required this.notifier});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Record select; list identity works because the provider replaces the
    // list whole on every suggest_replies event — never mutates in place.
    final r = ref.watch(state.select((s) => (
          replies: s.suggestedReplies,
          isStreaming: s.isStreaming,
          hasQueue: s.queuedMessages.isNotEmpty,
        )));
    if (r.replies.isEmpty || r.isStreaming || r.hasQueue) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: [
          for (final reply in r.replies)
            ActionChip(
              label: Text(reply),
              onPressed: () => ref.read(notifier).sendMessage(reply),
            ),
        ],
      ),
    );
  }
}

/// Bridges the whole-state `footerBuilder(context, state)` contract into the
/// select-based tail. Watching the full state here is fine — this leaf is
/// nearly empty until the itinerary completes.
class _ChatFooter extends ConsumerWidget {
  final ProviderListenable<PlanState> state;
  final Widget Function(BuildContext context, PlanState state) footerBuilder;

  const _ChatFooter({required this.state, required this.footerBuilder});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final planState = ref.watch(state);
    return footerBuilder(context, planState);
  }
}

class _ErrorBanner extends ConsumerWidget {
  final ProviderListenable<PlanState> state;
  final ProviderListenable<PlanNotifier> notifier;

  const _ErrorBanner({required this.state, required this.notifier});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final error = ref.watch(state.select((s) => s.error));
    if (error == null) return const SizedBox.shrink();
    // Narrow derived select: retry only makes sense once a user turn exists
    // for [PlanNotifier.retryLastSend] to re-run.
    final canRetry = ref.watch(
        state.select((s) => s.messages.any((m) => m.role == MessageRole.user)));
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            friendlyError(context.l10n, error),
            style: TextStyle(color: theme.colorScheme.onErrorContainer),
          ),
          if (canRetry)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.onErrorContainer,
                ),
                onPressed: () => ref.read(notifier).retryLastSend(),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(context.l10n.chatTryAgain),
              ),
            ),
        ],
      ),
    );
  }
}

/// User messages queued while a turn streams, rendered below the tail as
/// dimmed "up next" bubbles with a remove affordance. Kept out of the
/// committed-messages ListView so its append-only index keys stay valid.
class _QueuedMessages extends ConsumerWidget {
  final ProviderListenable<PlanState> state;
  final ProviderListenable<PlanNotifier> notifier;
  final double bubbleMaxWidth;

  const _QueuedMessages({
    required this.state,
    required this.notifier,
    required this.bubbleMaxWidth,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Identity select works because the notifier replaces the list whole.
    final queued = ref.watch(state.select((s) => s.queuedMessages));
    if (queued.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final m in queued)
          _QueuedBubble(
            key: ValueKey('queued-${m.id}'),
            message: m,
            maxWidth: bubbleMaxWidth,
            onRemove: () => ref.read(notifier).removeQueued(m.id),
          ),
      ],
    );
  }
}

class _QueuedBubble extends StatelessWidget {
  final QueuedMessage message;
  final double maxWidth;
  final VoidCallback onRemove;

  const _QueuedBubble({
    super.key,
    required this.message,
    required this.maxWidth,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        constraints: BoxConstraints(maxWidth: maxWidth),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.45),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(4),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.attachments.isNotEmpty) ...[
                    _BubbleAttachments(attachments: message.attachments),
                    const SizedBox(height: AppSpacing.xs),
                  ],
                  if (message.text.isNotEmpty || message.displayLabel != null)
                    Text(
                      message.displayLabel ?? message.text,
                      style: TextStyle(color: theme.colorScheme.onPrimary),
                    ),
                  Text(
                    context.l10n.chatQueued,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onPrimary.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: context.l10n.chatRemoveQueued,
              onPressed: onRemove,
              icon: Icon(
                Icons.close,
                size: 16,
                color: theme.colorScheme.onPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bubbles span 78% of the hosting panel's width but cap at a readable
/// measure on wide panels. Derived from the panel's own LayoutBuilder
/// constraints — never the window — so the 400px refine dock and the 760px
/// agent column both keep the ragged 78% edge.
const double _kBubbleMaxWidth = 720;

double _bubbleMaxWidthFor(double panelWidth) =>
    min(panelWidth * 0.78, _kBubbleMaxWidth);

/// gpt_markdown component lists with the LaTeX components removed. A travel
/// chat never renders LaTeX, but the package's defaults include
/// LatexMath/LatexMathMultiLine, which (a) add their regex alternations to
/// every parse of every bubble and (b) are the only reachable path into
/// flutter_math_fork's KaTeX rendering. Excluding them here keeps that path
/// dead at runtime; the deployment Dockerfile separately strips the 16 KaTeX
/// font families from the shipped web bundle (tool/strip_katex_fonts.dart).
///
/// These mirror `MarkdownComponent.globalComponents` / `.inlineComponents`
/// in gpt_markdown 1.1.7 (lib/markdown_component.dart) minus the two LaTeX
/// entries, in the SAME order — the list order is the combined-regex
/// alternation order, so reordering would change parse precedence.
final List<MarkdownComponent> _markdownComponents = [
  CodeBlockMd(),
  NewLines(),
  BlockQuote(),
  TableMd(),
  HTag(),
  UnOrderedList(),
  OrderedList(),
  RadioButtonMd(),
  CheckBoxMd(),
  HrLine(),
  IndentMd(),
];

final List<MarkdownComponent> _markdownInlineComponents = [
  ATagMd(),
  ImageMd(),
  TableMd(),
  StrikeMd(),
  BoldMd(),
  ItalicMd(),
  UnderLineMd(),
  HighlightedText(),
  SourceTag(),
];

class ChatMessageBubble extends StatelessWidget {
  final PlanMessage message;
  final bool isStreaming;

  /// Cap for the bubble, computed by the hosting panel from its own width.
  final double maxWidth;

  const ChatMessageBubble({
    super.key,
    required this.message,
    required this.maxWidth,
    this.isStreaming = false,
  });

  Future<void> _openLink(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    // Agent-emitted markdown links can point at any provider, so the link
    // host stands in as the provider label.
    await trackedLaunchUrl(
      context,
      url,
      provider: uri.host.isEmpty ? 'unknown' : uri.host,
      surface: 'chat',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.role == MessageRole.user;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: maxWidth),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: isUser
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (message.attachments.isNotEmpty) ...[
                          _BubbleAttachments(attachments: message.attachments),
                          if (message.content.isNotEmpty)
                            const SizedBox(height: 6),
                        ],
                        if (message.content.isNotEmpty)
                          Text(
                            message.content,
                            style:
                                TextStyle(color: theme.colorScheme.onPrimary),
                          ),
                      ],
                    )
                  // While streaming, the growing string is re-rendered every
                  // token flush; a full markdown parse each time is O(n²)
                  // over the reply. Plain Text keeps flushes O(n) — the
                  // enclosing SelectionArea keeps it selectable — and the
                  // bubble switches to GptMarkdown naturally when the message
                  // commits into the messages list (so bold/lists appear on
                  // commit rather than live: accepted trade).
                  : isStreaming
                      ? Text(
                          message.content,
                          style: TextStyle(color: theme.colorScheme.onSurface),
                        )
                      : GptMarkdown(
                          message.content,
                          style: TextStyle(color: theme.colorScheme.onSurface),
                          components: _markdownComponents,
                          inlineComponents: _markdownInlineComponents,
                          onLinkTap: (url, title) => _openLink(context, url),
                        ),
            ),
            if (isStreaming) ...[
              const SizedBox(width: 6),
              const _StreamingCursor(),
            ],
          ],
        ),
      ),
    );
  }
}

/// Image thumbnails inside a sent user bubble. Placeholders (null bytes —
/// resumed transcripts, where the server keeps only the media type) render as
/// an icon chip instead.
class _BubbleAttachments extends StatelessWidget {
  final List<PlanAttachment> attachments;

  const _BubbleAttachments({required this.attachments});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.end,
      children: [
        for (final a in attachments)
          if (a.bytes != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(
                a.bytes!,
                width: 160,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.onPrimary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.image_outlined,
                      size: 18, color: theme.colorScheme.onPrimary),
                  const SizedBox(width: 6),
                  Text(context.l10n.chatImagePlaceholder,
                      style: TextStyle(color: theme.colorScheme.onPrimary)),
                ],
              ),
            ),
      ],
    );
  }
}

/// A softly blinking caret shown at the end of the live streaming bubble —
/// quieter than a spinner.
class _StreamingCursor extends StatefulWidget {
  const _StreamingCursor();

  @override
  State<_StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<_StreamingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FadeTransition(
      opacity: _controller.drive(Tween(begin: 0.15, end: 0.7)),
      child: Container(
        width: 2.5,
        height: 16,
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.onSurface,
          borderRadius: BorderRadius.circular(1.25),
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool isStreaming;
  final String hint;

  /// Used in place of [hint] when the field is too narrow to render it on one
  /// line. See [_hintFor].
  final String shortHint;

  final VoidCallback onSend;
  final VoidCallback onStop;
  final bool hasDraftAttachments;
  final VoidCallback onAttach;
  final DictationController dictation;
  final bool floating;

  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.isStreaming,
    required this.hint,
    required this.shortHint,
    required this.onSend,
    required this.onStop,
    required this.hasDraftAttachments,
    required this.onAttach,
    required this.dictation,
    this.floating = false,
  });

  /// [full] when it renders on one line inside [textWidth], else [short].
  ///
  /// Measured, not switched on a width breakpoint. Three things move this
  /// boundary and a breakpoint would have to guess all three: whether the mic
  /// button is on screen at all (`_MicButton` collapses to nothing when
  /// dictation is unavailable — a 48px swing), which locale is loaded, and the
  /// traveler's text scale. Measuring answers all three at once, and answers
  /// them for the refine dock's hints as well as the agent screen's.
  static String _hintFor(
    BuildContext context,
    double textWidth, {
    required String full,
    required String short,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: full, style: Theme.of(context).textTheme.bodyLarge),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final fits = painter.width <= textWidth;
    painter.dispose();
    return fits ? full : short;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      // Floating mode: a rounded card inside a width-capped column (the 760px
      // agent screen), where the full-bleed bar's square corners and side
      // shadow would otherwise show mid-screen. Radius 32 keeps the card
      // concentric with the radius-24 field pill through the sm padding.
      margin: floating
          ? const EdgeInsets.fromLTRB(
              AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg)
          : null,
      decoration: floating
          ? BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: theme.colorScheme.outlineVariant),
              boxShadow: AppShadows.soft,
            )
          : BoxDecoration(
              color: theme.colorScheme.surface,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 8,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
      padding: floating
          ? const EdgeInsets.all(AppSpacing.sm)
          : const EdgeInsets.fromLTRB(
              AppSpacing.sm, AppSpacing.sm, AppSpacing.sm, AppSpacing.lg),
      child: Row(
        children: [
          IconButton(
            tooltip: context.l10n.chatAttachImages,
            onPressed: onAttach,
            icon: const Icon(Icons.attach_file),
          ),
          Expanded(
            // The LayoutBuilder is here, inside the Expanded, because this is
            // the only place the field's REAL width is known: it already
            // accounts for the mic having collapsed (see [_hintFor]).
            child: LayoutBuilder(
              builder: (context, constraints) {
                final textWidth = constraints.maxWidth - AppSpacing.lg * 2;
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  maxLines: null,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                  decoration: InputDecoration(
                    hintText: _hintFor(
                      context,
                      textWidth,
                      full: isStreaming ? context.l10n.chatFollowUpHint : hint,
                      short: isStreaming
                          ? context.l10n.chatFollowUpHintShort
                          : shortHint,
                    ),
                    // The structural guarantee. Without it InputDecorator
                    // renders the hint with maxLines: null and a hint too wide
                    // for the field takes the whole composer to two lines —
                    // which is exactly what "Where do you want to go?" did on
                    // a phone. A short hint that still overflows now clips.
                    hintMaxLines: 1,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: theme.colorScheme.surfaceContainerHighest,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg, vertical: 10),
                  ),
                );
              },
            ),
          ),
          _MicButton(dictation: dictation),
          const SizedBox(width: AppSpacing.sm),
          // Contextual swap: while streaming with nothing drafted the send
          // button becomes a stop button; any draft (text or attachment)
          // flips it back to send so queue-ahead keeps working.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              final showStop = isStreaming &&
                  value.text.trim().isEmpty &&
                  !hasDraftAttachments;
              if (showStop) {
                return IconButton.filled(
                  tooltip: context.l10n.chatStopGenerating,
                  onPressed: onStop,
                  icon: const Icon(Icons.stop),
                );
              }
              return IconButton.filled(
                tooltip: context.l10n.chatSend,
                onPressed: onSend,
                icon: const Icon(Icons.send),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// The dictation mic (specs/voice-dictation). Rebuilds only itself on
/// dictation state changes; absent entirely when no capture path exists.
class _MicButton extends StatelessWidget {
  final DictationController dictation;

  const _MicButton({required this.dictation});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: dictation,
      builder: (context, _) {
        if (!dictation.available) return const SizedBox.shrink();
        switch (dictation.status) {
          case DictationStatus.transcribing:
            return const Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          case DictationStatus.listening:
            return IconButton(
              tooltip: context.l10n.chatStopDictating,
              onPressed: dictation.toggle,
              icon: Icon(Icons.mic, color: theme.colorScheme.error),
            );
          case DictationStatus.idle:
            return IconButton(
              tooltip: context.l10n.chatDictate,
              onPressed: dictation.toggle,
              icon: const Icon(Icons.mic_none),
            );
        }
      },
    );
  }
}
