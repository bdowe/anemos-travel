import 'dart:async';
import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/plan_message.dart';
import '../models/agent_place.dart';
import '../models/flight_offer.dart';
import '../models/event.dart';
import '../models/ferry_option.dart';
import '../models/source_link.dart';
import '../models/local_recommendation.dart';
import '../services/api_client.dart';
import '../services/plan_service.dart';
import 'preferences_provider.dart';
import 'api_client_provider.dart';

/// A user message waiting to be sent once the in-flight turn finishes.
/// [id] is a notifier-local monotonic id — stable identity for remove buttons
/// and widget keys while the queue head is popped by the drain.
class QueuedMessage {
  final int id;
  final String text;
  final String? displayLabel;
  final List<PlanAttachment> attachments;

  const QueuedMessage({
    required this.id,
    required this.text,
    this.displayLabel,
    this.attachments = const [],
  });
}

class PlanState {
  final List<PlanMessage> messages;
  final bool isStreaming;
  final String? streamingText;
  final List<String> activeTools;
  final List<Map<String, dynamic>>? completedLocations;
  final String? completedSummary;
  final String? savedTripId;
  final List<FlightOffer>? flightOffers;
  final String? flightRouteLabel;
  final List<Event>? eventResults;
  final String? eventsCityLabel;
  final List<FerryOption>? ferryOptions;
  final String? ferryRouteLabel;
  final List<SourceLink>? eventLinks;
  final String? eventLinksCity;
  final List<LocalRecommendation>? localRecs;
  final String? localRecsCity;

  /// Google places the agent surfaced this turn (SSE `places`) — the photo
  /// card strip's data. Replaced whole, never mutated; nulled per turn and on
  /// itinerary turns (search_places doubles as geocoding there, so a leftover
  /// strip would be noise under the itinerary banner).
  final List<AgentPlace>? places;

  /// The search query behind [places], for the strip's header label.
  final String? placesQuery;

  /// Parking spots the agent surfaced near a beach this turn (SSE `parking`,
  /// specs/find-parking-near-beach). Replaced whole, never mutated. Unlike
  /// [places] there is no itinerary-turn guard: find_parking never runs as
  /// geocoding, so the rail is real advice even under a trip banner (matches
  /// ferries/events).
  final List<AgentPlace>? parkingSpots;

  /// The beach behind [parkingSpots], for the rail's header label.
  final String? parkingBeach;

  // Either a friendly String the /plan SSE stream sent, or a raw caught error
  // (ApiException) from a failed connect. friendlyError() renders both: it
  // passes a String through unchanged and classifies an ApiException.
  final Object? error;

  /// Messages the user sent while a turn was streaming, waiting FIFO to be
  /// sent. Always replaced whole, never mutated in place.
  final List<QueuedMessage> queuedMessages;

  /// One-tap answers the agent attached to its last question (SSE
  /// `suggest_replies`, specs/chat-quick-replies). Model-generated in the
  /// conversation language; tapping sends the text verbatim. Empty = none.
  /// Replaced whole, never mutated; cleared on every send and on error.
  final List<String> suggestedReplies;

  /// Short excerpt of profile notes the agent just saved (server
  /// `profile_updated` event); shown as a transient "Noted" chip in the chat.
  final String? profileUpdateNote;

  /// Bumped each time a trip-bound session patches the trip in place
  /// (server `trip_updated` event); listeners reload the trip when it grows.
  final int tripUpdateCount;

  /// Whether the current/most recent turn patched the trip — drives the
  /// transient "Trip updated" chip. Reset at the start of each send;
  /// unlike [tripUpdateCount] it is not monotonic.
  final bool tripUpdatedThisTurn;

  /// Server-produced summary of the conversation's compacted-away prefix
  /// (SSE `compacted`). Sent back as the request's `summary` so the server
  /// doesn't re-summarize; the visible transcript is never touched.
  final String? compactedSummary;

  /// How many leading [messages] are covered by [compactedSummary] and must be
  /// excluded from the wire history. Start-anchored, so appends never shift it.
  final int compactedCount;

  /// Whether the server is currently summarizing the conversation (between
  /// SSE `compacting` and the first event that follows it) — drives the
  /// transient "Summarizing earlier conversation…" chip.
  final bool isCompacting;

  /// Whether the server is between steps waiting on the model (between SSE
  /// `thinking` and the first event that follows it) — lets the typing
  /// indicator return mid-turn after text has already streamed
  /// (specs/chat-working-indicator).
  final bool isThinking;

  /// The conversation's stable chat id, mirrored from the notifier's private
  /// one once a conversation exists (first send, or a resume) — the public
  /// read path URL sync needs to emit /plan/<chatId>
  /// (specs/url-page-persistence). Null until then and after Start over.
  final String? chatId;

  const PlanState({
    this.messages = const [],
    this.isStreaming = false,
    this.streamingText,
    this.activeTools = const [],
    this.completedLocations,
    this.completedSummary,
    this.savedTripId,
    this.flightOffers,
    this.flightRouteLabel,
    this.eventResults,
    this.eventsCityLabel,
    this.ferryOptions,
    this.ferryRouteLabel,
    this.eventLinks,
    this.eventLinksCity,
    this.localRecs,
    this.localRecsCity,
    this.places,
    this.placesQuery,
    this.parkingSpots,
    this.parkingBeach,
    this.error,
    this.queuedMessages = const [],
    this.suggestedReplies = const [],
    this.profileUpdateNote,
    this.tripUpdateCount = 0,
    this.tripUpdatedThisTurn = false,
    this.compactedSummary,
    this.compactedCount = 0,
    this.isCompacting = false,
    this.isThinking = false,
    this.chatId,
  });

  PlanState copyWith({
    List<PlanMessage>? messages,
    bool? isStreaming,
    Object? streamingText = _sentinel,
    List<String>? activeTools,
    Object? completedLocations = _sentinel,
    Object? completedSummary = _sentinel,
    Object? savedTripId = _sentinel,
    Object? flightOffers = _sentinel,
    Object? flightRouteLabel = _sentinel,
    Object? eventResults = _sentinel,
    Object? eventsCityLabel = _sentinel,
    Object? ferryOptions = _sentinel,
    Object? ferryRouteLabel = _sentinel,
    Object? eventLinks = _sentinel,
    Object? eventLinksCity = _sentinel,
    Object? localRecs = _sentinel,
    Object? localRecsCity = _sentinel,
    Object? places = _sentinel,
    Object? placesQuery = _sentinel,
    Object? parkingSpots = _sentinel,
    Object? parkingBeach = _sentinel,
    Object? error = _sentinel,
    List<QueuedMessage>? queuedMessages,
    List<String>? suggestedReplies,
    Object? profileUpdateNote = _sentinel,
    int? tripUpdateCount,
    bool? tripUpdatedThisTurn,
    Object? compactedSummary = _sentinel,
    int? compactedCount,
    bool? isCompacting,
    bool? isThinking,
    Object? chatId = _sentinel,
  }) {
    return PlanState(
      messages: messages ?? this.messages,
      isStreaming: isStreaming ?? this.isStreaming,
      streamingText: streamingText == _sentinel ? this.streamingText : streamingText as String?,
      activeTools: activeTools ?? this.activeTools,
      completedLocations: completedLocations == _sentinel
          ? this.completedLocations
          : completedLocations as List<Map<String, dynamic>>?,
      completedSummary: completedSummary == _sentinel ? this.completedSummary : completedSummary as String?,
      savedTripId: savedTripId == _sentinel ? this.savedTripId : savedTripId as String?,
      flightOffers: flightOffers == _sentinel ? this.flightOffers : flightOffers as List<FlightOffer>?,
      flightRouteLabel: flightRouteLabel == _sentinel ? this.flightRouteLabel : flightRouteLabel as String?,
      eventResults: eventResults == _sentinel ? this.eventResults : eventResults as List<Event>?,
      eventsCityLabel: eventsCityLabel == _sentinel ? this.eventsCityLabel : eventsCityLabel as String?,
      ferryOptions: ferryOptions == _sentinel ? this.ferryOptions : ferryOptions as List<FerryOption>?,
      ferryRouteLabel: ferryRouteLabel == _sentinel ? this.ferryRouteLabel : ferryRouteLabel as String?,
      eventLinks: eventLinks == _sentinel ? this.eventLinks : eventLinks as List<SourceLink>?,
      eventLinksCity: eventLinksCity == _sentinel ? this.eventLinksCity : eventLinksCity as String?,
      localRecs: localRecs == _sentinel ? this.localRecs : localRecs as List<LocalRecommendation>?,
      localRecsCity: localRecsCity == _sentinel ? this.localRecsCity : localRecsCity as String?,
      places: places == _sentinel ? this.places : places as List<AgentPlace>?,
      placesQuery: placesQuery == _sentinel ? this.placesQuery : placesQuery as String?,
      parkingSpots: parkingSpots == _sentinel ? this.parkingSpots : parkingSpots as List<AgentPlace>?,
      parkingBeach: parkingBeach == _sentinel ? this.parkingBeach : parkingBeach as String?,
      error: error == _sentinel ? this.error : error,
      queuedMessages: queuedMessages ?? this.queuedMessages,
      suggestedReplies: suggestedReplies ?? this.suggestedReplies,
      profileUpdateNote:
          profileUpdateNote == _sentinel ? this.profileUpdateNote : profileUpdateNote as String?,
      tripUpdateCount: tripUpdateCount ?? this.tripUpdateCount,
      tripUpdatedThisTurn: tripUpdatedThisTurn ?? this.tripUpdatedThisTurn,
      compactedSummary:
          compactedSummary == _sentinel ? this.compactedSummary : compactedSummary as String?,
      compactedCount: compactedCount ?? this.compactedCount,
      isCompacting: isCompacting ?? this.isCompacting,
      isThinking: isThinking ?? this.isThinking,
      chatId: chatId == _sentinel ? this.chatId : chatId as String?,
    );
  }
}

const _sentinel = Object();

class PlanNotifier extends StateNotifier<PlanState> {
  final PlanService _service;
  final ApiClient _apiClient;

  /// When set, every request carries trip_id and the server refines that saved
  /// trip in place (update_itinerary_section) instead of creating new versions.
  final String? tripId;

  // Stable id for the current conversation. Every create_itinerary in this chat
  // is stamped with it server-side so refinements collapse to one trip in My
  // Trips instead of spawning duplicate drafts. Regenerated on reset().
  String? _chatId;

  // Identity source for QueuedMessage.id.
  int _nextQueuedId = 0;

  // Turn generation: bumped by reset() and every _sendNow, checked by the
  // in-flight stream loop so a superseded turn self-terminates instead of
  // writing its events (or its stream-teardown) into the fresh conversation
  // — e.g. a late suggest_replies leaking chips after Start over.
  int _turn = 0;

  /// Called with the profile fields the agent just wrote server-side, so the
  /// app can refresh anything derived from them. Set by the providers below;
  /// null in tests that don't care.
  final void Function(Set<String> fields)? onProfileFieldsChanged;

  PlanNotifier(this._service, this._apiClient,
      {this.tripId, this.onProfileFieldsChanged})
      : super(const PlanState());

  // Streamed text_deltas arrive faster than a frame; pushing a new state per
  // token rebuilds the chat per token. Deltas accumulate in [_streamBuffer]
  // and reach [state] at most once per [_streamFlushInterval].
  static const _streamFlushInterval = Duration(milliseconds: 48);
  Timer? _streamFlushTimer;
  StringBuffer? _streamBuffer;

  // Completes when the in-flight turn is deliberately torn down (stop button,
  // Start over, dispose). PlanService feeds it to AbortableRequest, which
  // aborts the transport immediately — even while the socket is idle during a
  // server-side tool call — so the server's request context cancels and
  // generation stops instead of streaming to a dead client.
  Completer<void>? _abortCurrent;

  void _abortInFlight() {
    final abort = _abortCurrent;
    _abortCurrent = null;
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  void _scheduleStreamFlush() {
    _streamFlushTimer ??= Timer(_streamFlushInterval, _flushStreamText);
  }

  void _flushStreamText() {
    _streamFlushTimer?.cancel();
    _streamFlushTimer = null;
    final buffer = _streamBuffer;
    if (buffer == null || !mounted) return;
    state = state.copyWith(streamingText: buffer.toString());
  }

  // Must run before any state change that clears streamingText, or a pending
  // timer fires afterwards and resurrects a ghost streaming bubble.
  void _endStreamBuffer() {
    _streamFlushTimer?.cancel();
    _streamFlushTimer = null;
    _streamBuffer = null;
  }

  @override
  void dispose() {
    // Refine-panel family instances can be disposed mid-stream.
    _abortInFlight();
    _endStreamBuffer();
    super.dispose();
  }

  // 0x7fffffff (not 1 << 32) because on the web target `1 << 32` overflows JS's
  // 32-bit bitwise ops to 0, and Random.nextInt(0) throws RangeError.
  static String _newChatId() =>
      'chat-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${Random.secure().nextInt(0x7fffffff).toRadixString(16)}';


  /// Sends [text], or queues it if a turn is already streaming (or a backlog
  /// exists post-error). Queued messages drain FIFO as each turn completes
  /// successfully; the returned future completes once the whole chain settles.
  Future<void> sendMessage(String text,
      {String? displayLabel, List<PlanAttachment> attachments = const []}) {
    if (state.isStreaming || state.queuedMessages.isNotEmpty) {
      state = state.copyWith(queuedMessages: [
        ...state.queuedMessages,
        QueuedMessage(
            id: _nextQueuedId++,
            text: text,
            displayLabel: displayLabel,
            attachments: attachments),
      ]);
      // Idle with a backlog (post-error state): an explicit send is fresh user
      // intent — start draining now. FIFO holds because the new message went
      // to the back and the drain pops the head.
      if (!state.isStreaming) return _drainQueue();
      return Future.value();
    }
    return _sendNow(text, displayLabel: displayLabel, attachments: attachments);
  }

  /// Removes a not-yet-sent queued message by its [QueuedMessage.id].
  void removeQueued(int id) {
    state = state.copyWith(
      queuedMessages: state.queuedMessages.where((m) => m.id != id).toList(),
    );
  }

  /// Pops the queue head and sends it. Dequeues BEFORE sending and bypasses
  /// the [sendMessage] gatekeeper — otherwise the still-queued head would be
  /// re-enqueued at the back. Chained by each turn's success tail; errors stop
  /// the chain with the remainder still queued.
  Future<void> _drainQueue() async {
    if (!mounted) return;
    if (state.isStreaming || state.queuedMessages.isEmpty) return;
    final next = state.queuedMessages.first;
    state = state.copyWith(queuedMessages: state.queuedMessages.sublist(1));
    await _sendNow(next.text,
        displayLabel: next.displayLabel, attachments: next.attachments);
  }

  Future<void> _sendNow(String text,
      {String? displayLabel, List<PlanAttachment> attachments = const []}) async {
    final turn = ++_turn;
    final abort = Completer<void>();
    _abortCurrent = abort;
    _chatId ??= _newChatId();

    final userMessage = PlanMessage(
        role: MessageRole.user,
        content: text,
        displayLabel: displayLabel,
        attachments: attachments);
    final updatedMessages = [...state.messages, userMessage];

    state = state.copyWith(
      messages: updatedMessages,
      isStreaming: true,
      streamingText: '',
      chatId: _chatId,
      activeTools: [],
      isThinking: false,
      flightOffers: null,
      flightRouteLabel: null,
      eventResults: null,
      eventsCityLabel: null,
      ferryOptions: null,
      ferryRouteLabel: null,
      eventLinks: null,
      eventLinksCity: null,
      localRecs: null,
      localRecsCity: null,
      places: null,
      placesQuery: null,
      parkingSpots: null,
      parkingBeach: null,
      error: null,
      suggestedReplies: [],
      profileUpdateNote: null,
      tripUpdatedThisTurn: false,
    );

    // Messages covered by the compacted summary stay visible but leave the
    // wire history — the summary stands in for them server-side.
    // Resume placeholders (null bytes) stay out of the wire history — the
    // server persists images as data-less markers and skips them anyway.
    final history = updatedMessages
        .sublist(state.compactedCount.clamp(0, updatedMessages.length))
        .map((m) => <String, dynamic>{
              'role': m.role == MessageRole.user ? 'user' : 'assistant',
              'content': m.content,
              // Seed-chip metadata: titles the persisted session server-side
              // and must be resent every turn — the transcript is upserted
              // wholesale, so omitting it would erase the label.
              if (m.displayLabel != null) 'display_label': m.displayLabel,
              if (m.attachments.any((a) => a.bytes != null))
                'images': [
                  for (final a in m.attachments)
                    if (a.bytes != null)
                      {'media_type': a.mediaType, 'data': a.base64Data},
                ],
            })
        .toList();

    final textBuffer = StringBuffer();
    _streamBuffer = textBuffer;
    // Assistant text blocks on either side of a tool call stream into the same
    // buffer; without a separator they render run together
    // ("…committing.Great news…"). Set at tool boundaries, consumed by the
    // next delta — at APPEND time, so the flush timer and both commit paths
    // (mid-turn error, final) all see already-separated text.
    var needsSeparator = false;
    // Whether this turn streamed `done` or `trip_updated`: the itinerary
    // banner owns such a turn, so reply chips are dropped in either event
    // order (specs/chat-quick-replies).
    var itineraryThisTurn = false;

    try {
      await for (final event in _service.streamPlan(history,
          bearerToken: _apiClient.authToken,
          chatId: _chatId,
          tripId: tripId,
          summary: state.compactedSummary,
          abortTrigger: abort.future)) {
        // Superseded by reset()/Start over: stop consuming and touch nothing
        // — the successor turn owns the state and the stream buffer now.
        if (turn != _turn) return;

        // Keep buffered text ahead of any other state transition so tool chips
        // and results never appear before the text that introduced them.
        if (event.type != 'text_delta') _flushStreamText();

        // A failed compaction sends no `compacted` terminator — whatever event
        // follows `compacting` ends the chip.
        if (state.isCompacting && event.type != 'compacting') {
          state = state.copyWith(isCompacting: false);
        }

        // `thinking` has no terminator of its own either — the model's first
        // token (or a tool announcement) is what ends the wait.
        if (state.isThinking && event.type != 'thinking') {
          state = state.copyWith(isThinking: false);
        }

        switch (event.type) {
          case 'text_delta':
            final delta = event.data['text'] as String? ?? '';
            if (delta.isNotEmpty) {
              // Skip only when a NEWLINE already sits on either side of the
              // boundary; a plain space still gets the paragraph break (the
              // two beats are separate thoughts, not one sentence).
              if (needsSeparator &&
                  !delta.startsWith('\n') &&
                  !textBuffer.toString().endsWith('\n')) {
                textBuffer.write('\n\n');
              }
              needsSeparator = false;
              textBuffer.write(delta);
            }
            _scheduleStreamFlush();

          case 'tool_call':
            if (textBuffer.isNotEmpty) needsSeparator = true;
            final name = event.data['name'] as String? ?? '';
            // The quick-replies meta-tool renders chips, not work worth a
            // spinner chip; tool_result's list-remove is a harmless no-op.
            if (name != 'suggest_replies') {
              state = state.copyWith(activeTools: [...state.activeTools, name]);
            }

          case 'tool_result':
            if (textBuffer.isNotEmpty) needsSeparator = true;
            final name = event.data['name'] as String? ?? '';
            final tools = state.activeTools.toList()..remove(name);
            state = state.copyWith(activeTools: tools);

          case 'done':
            itineraryThisTurn = true;
            final rawLocs = event.data['locations'] as List<dynamic>? ?? [];
            final locations = rawLocs.cast<Map<String, dynamic>>();
            final summary = event.data['summary'] as String?;
            // `done` IS create_itinerary's result (the tool suppresses
            // tool_result); without this the "Building itinerary…" chip spins
            // on while the banner already says finished.
            final tools = state.activeTools.toList()..remove('create_itinerary');
            state = state.copyWith(
              completedLocations: locations,
              completedSummary: summary,
              savedTripId: event.data['trip_id'] as String?,
              activeTools: tools,
              suggestedReplies: [],
              // The itinerary banner owns this turn; any places strip would be
              // geocoding leftovers (covers the places-then-done order).
              places: null,
              placesQuery: null,
            );

          case 'trip_updated':
            itineraryThisTurn = true;
            state = state.copyWith(
              tripUpdateCount: state.tripUpdateCount + 1,
              tripUpdatedThisTurn: true,
              suggestedReplies: [],
              places: null,
              placesQuery: null,
            );

          case 'profile_updated':
            state = state.copyWith(
                profileUpdateNote: event.data['notes_preview'] as String? ?? '');
            // The server names which fields it wrote. Anything cached from the
            // traveler's profile is now stale — the home airport especially,
            // which the trip page reads for its map pin and its checklist
            // fallback and would otherwise keep showing until an app restart.
            final fields = (event.data['fields'] as List<dynamic>?)
                    ?.whereType<String>()
                    .toSet() ??
                const <String>{};
            if (fields.isNotEmpty) onProfileFieldsChanged?.call(fields);

          case 'suggest_replies':
            // An itinerary turn's banner owns the tail — drop the chips
            // (covers the suggest-then-create order; the server refuses the
            // create-then-suggest order outright).
            if (itineraryThisTurn) break;
            final raw = event.data['replies'] as List<dynamic>? ?? [];
            // Replaced whole (record-select invariant); a later call in the
            // same turn overwrites — last-write-wins. The chips widget stays
            // hidden until the stream closes.
            state = state.copyWith(
                suggestedReplies: raw.whereType<String>().toList());

          case 'thinking':
            state = state.copyWith(isThinking: true);

          case 'compacting':
            state = state.copyWith(isCompacting: true);

          case 'compacted':
            // through_index counts wire messages, and the wire history was
            // exactly messages.sublist(compactedCount) at send time — so the
            // new boundary is the old one advanced by through_index.
            final through =
                (event.data['through_index'] as num?)?.toInt() ?? 0;
            state = state.copyWith(
              isCompacting: false,
              compactedSummary:
                  event.data['summary'] as String? ?? state.compactedSummary,
              compactedCount: (state.compactedCount + through)
                  .clamp(0, state.messages.length),
            );

          case 'flights':
            final raw = event.data['offers'] as List<dynamic>? ?? [];
            final offers = raw
                .map((e) => FlightOffer.fromJson(e as Map<String, dynamic>))
                .toList();
            final origin = event.data['origin'] as String? ?? '';
            final dest = event.data['destination'] as String? ?? '';
            state = state.copyWith(
              flightOffers: offers,
              flightRouteLabel: '$origin → $dest',
            );

          case 'events':
            final raw = event.data['events'] as List<dynamic>? ?? [];
            final events = raw
                .map((e) => Event.fromJson(e as Map<String, dynamic>))
                .toList();
            state = state.copyWith(
              eventResults: events,
              eventsCityLabel: event.data['city'] as String?,
            );

          case 'ferries':
            final raw = event.data['options'] as List<dynamic>? ?? [];
            final options = raw
                .map((e) => FerryOption.fromJson(e as Map<String, dynamic>))
                .toList();
            final origin = event.data['origin'] as String? ?? '';
            final dest = event.data['destination'] as String? ?? '';
            state = state.copyWith(
              ferryOptions: options,
              ferryRouteLabel: '$origin → $dest',
            );

          case 'event_links':
            final raw = event.data['links'] as List<dynamic>? ?? [];
            final links = raw
                .map((e) => SourceLink.fromJson(e as Map<String, dynamic>))
                .toList();
            state = state.copyWith(
              eventLinks: links,
              eventLinksCity: event.data['city'] as String?,
            );

          case 'local_recs':
            final raw = event.data['recommendations'] as List<dynamic>? ?? [];
            final recs = raw
                .map((e) =>
                    LocalRecommendation.fromJson(e as Map<String, dynamic>))
                .toList();
            state = state.copyWith(
              localRecs: recs,
              localRecsCity: event.data['city'] as String?,
            );

          case 'places':
            // search_places also runs as geocoding during itinerary builds; an
            // itinerary turn's banner owns the tail, so drop the strip data —
            // same guard suggest_replies uses (covers the done-then-places
            // order; places-then-done is cleared in the done case).
            if (itineraryThisTurn) break;
            final raw = event.data['places'] as List<dynamic>? ?? [];
            final places = raw
                .map((e) => AgentPlace.fromJson(e as Map<String, dynamic>))
                .toList();
            // Replaced whole (record-select invariant); last-write-wins
            // within a turn, matching flights/events.
            state = state.copyWith(
              places: places,
              placesQuery: event.data['query'] as String?,
            );

          case 'parking':
            final raw = event.data['spots'] as List<dynamic>? ?? [];
            final spots = raw
                .map((e) => AgentPlace.fromJson(e as Map<String, dynamic>))
                .toList();
            // Replaced whole (record-select invariant). No itineraryThisTurn
            // guard — see the field doc on PlanState.parkingSpots.
            state = state.copyWith(
              parkingSpots: spots,
              parkingBeach: event.data['beach'] as String?,
            );

          case 'error':
            _endStreamBuffer();
            // Commit whatever the model already said before the error —
            // iteration-cap / max_tokens stops arrive mid-turn, and the
            // streamed reply must not vanish from the transcript.
            final partial = textBuffer.toString();
            state = state.copyWith(
              isStreaming: false,
              streamingText: null,
              activeTools: [],
              isCompacting: false,
              isThinking: false,
              // A turn that ends in an error must not leave reply chips
              // competing with the error banner's Try again.
              suggestedReplies: [],
              messages: partial.isEmpty
                  ? state.messages
                  : [
                      ...state.messages,
                      PlanMessage(
                          role: MessageRole.assistant, content: partial),
                    ],
              error: event.data['message'] as String? ?? 'Unknown error',
            );
            return;
        }
      }

      if (turn != _turn) return;
      _endStreamBuffer();
      if (!mounted) return;

      // Commit streamed assistant text as a message
      final assistantText = textBuffer.toString();
      if (assistantText.isNotEmpty) {
        state = state.copyWith(
          messages: [
            ...state.messages,
            PlanMessage(role: MessageRole.assistant, content: assistantText),
          ],
        );
      }

      state = state.copyWith(
        isStreaming: false,
        streamingText: null,
        activeTools: [],
        isCompacting: false,
        isThinking: false,
      );

      // Success is the only drain point: after an error the queue stays put
      // (visible next to the error banner) until the user retries or resends.
      await _drainQueue();
    } catch (e) {
      if (turn != _turn) return;
      _endStreamBuffer();
      if (!mounted) return;
      state = state.copyWith(
        isStreaming: false,
        streamingText: null,
        activeTools: [],
        isCompacting: false,
        isThinking: false,
        suggestedReplies: [],
        error: e,
      );
    }
  }

  /// Re-runs the last user turn after a failed stream. [sendMessage] appends
  /// the user message to history before streaming, and the error paths keep it
  /// (plus any committed partial reply), so retrying by calling [sendMessage]
  /// again would double-append. Instead this rolls the transcript back to just
  /// before that user message (whole-list replacement, never in-place) and
  /// re-enters the one and only send path — exactly one copy of the user
  /// message ends up in history and in the server payload.
  Future<void> retryLastSend() async {
    if (state.isStreaming || state.error == null) return;
    final messages = state.messages;
    final lastUser = messages.lastIndexWhere((m) => m.role == MessageRole.user);
    if (lastUser == -1) return;
    final failed = messages[lastUser];
    // Cancel-before-clear: both error paths already ended the stream buffer,
    // but never replace messages/streaming state with a flush timer live.
    _endStreamBuffer();
    state = state.copyWith(
      messages: messages.sublist(0, lastUser),
      error: null,
    );
    // _sendNow, not sendMessage: with a post-error backlog the gatekeeper
    // would enqueue the retried turn at the BACK. The retried turn must run
    // first; on success its tail drains the queue.
    await _sendNow(failed.content,
        displayLabel: failed.displayLabel, attachments: failed.attachments);
  }

  /// Stops the in-flight turn: commits whatever the model already streamed as
  /// a normal assistant message (matching what the server persists — its
  /// deferred transcript upsert survives the abort) and aborts the transport.
  void stopStreaming() {
    if (!state.isStreaming) return; // idle / double-tap: no-op
    // Supersede FIRST: the abort surfaces in _sendNow as a stream teardown,
    // and the turn guards must make it a no-op — never a second commit or an
    // error banner.
    _turn++;
    // Read before _endStreamBuffer nulls the buffer; using the buffer (not
    // state.streamingText) captures the un-flushed 48ms coalescing tail,
    // exactly like the error-path commit.
    final partial = _streamBuffer?.toString() ?? '';
    _endStreamBuffer();
    state = state.copyWith(
      isStreaming: false,
      streamingText: null,
      activeTools: [],
      isCompacting: false,
      isThinking: false,
      suggestedReplies: [],
      messages: partial.isEmpty
          ? state.messages
          : [
              ...state.messages,
              PlanMessage(role: MessageRole.assistant, content: partial),
            ],
    );
    // Queue stays put (same as post-error): stopping is not "success", and
    // auto-draining would immediately start a turn the user just killed.
    _abortInFlight();
  }

  void reset() {
    _turn++; // any in-flight stream loop self-terminates without touching state
    _chatId = null;
    _abortInFlight(); // kill the socket too, or the server keeps generating
    _endStreamBuffer();
    state = const PlanState();
  }

  /// Restore a server-persisted conversation ("continue where you left off")
  /// without sending anything: the transcript renders immediately and the next
  /// send carries the same chat_id plus [summary] (the server-side compaction
  /// summary) exactly as a never-closed session would.
  ///
  /// [chatId] is optional because a trip's own conversation has none
  /// (specs/trip-refine-memory): it is keyed by (traveler, trip) server-side,
  /// and the throwaway id the next send mints is ignored for a bound turn.
  void resumeConversation({
    String? chatId,
    required List<PlanMessage> messages,
    String? summary,
  }) {
    reset();
    _chatId = chatId;
    state = state.copyWith(
      messages: messages,
      chatId: chatId,
      compactedSummary:
          (summary == null || summary.isEmpty) ? null : summary,
    );
  }

  /// Reopen a saved trip for refinement: clears any prior conversation, binds the
  /// session to the trip's chat group so new itineraries persist as versions of
  /// it, then sends the seed describing the current itinerary.
  void beginRefinement({required String chatId, required String seedMessage}) {
    reset();
    _chatId = chatId;
    sendMessage(seedMessage);
  }

  /// Point the trip's running conversation at another section
  /// (specs/trip-refine-memory). A refine tap is a change of subject, not a new
  /// chat — it appends a context chapter and discards nothing; only
  /// [startOver] discards. Requires [tripId]; the server patches that trip
  /// directly, so no chat-group binding is needed.
  ///
  /// Every EARLIER seed's itinerary listing is collapsed to a stub first. The
  /// seed built by the trip screen dumps every item with coordinates and tags,
  /// so without this a conversation would accumulate near-duplicate snapshots
  /// and the agent could not tell which one is current — the failure class
  /// behind the update_itinerary_section scope bugs. Costs the reader nothing:
  /// a labeled message renders as a context chip and its content is never shown.
  ///
  /// Rewrites content **in place and never removes a message**: [compactedCount]
  /// is a start-anchored index into [PlanState.messages], so dropping one would
  /// misalign the wire history against the server's compaction summary.
  void appendSectionRefinement(String seedMessage, {String? displayLabel}) {
    var hadEarlierSeed = false;
    final superseded = [
      for (final m in state.messages)
        if (m.role == MessageRole.user && m.displayLabel != null) ...[
          if (m.content.startsWith(_supersededSeedPrefix))
            m
          else
            PlanMessage(
              role: m.role,
              content: _supersededSeed(m.displayLabel!),
              displayLabel: m.displayLabel,
              attachments: m.attachments,
            ),
        ] else
          m,
    ];
    for (final m in state.messages) {
      if (m.role == MessageRole.user && m.displayLabel != null) {
        hadEarlierSeed = true;
        break;
      }
    }
    state = state.copyWith(messages: superseded);
    // Only when there is something to ignore. A first seed — especially a
    // server-built Next Step prompt — reaches the model verbatim.
    sendMessage(
        hadEarlierSeed ? '$seedMessage\n\n$_ignoreStaleListings' : seedMessage,
        displayLabel: displayLabel);
  }

  /// Explicit "New chat" on a trip: drop the transcript and the chat id. The
  /// caller is responsible for clearing the stored copy
  /// (`DELETE /trips/{id}/refine-chat`) — otherwise the page would go on
  /// advertising a conversation the traveler just dismissed.
  void startOver() => reset();
}

/// Canonical **English**, like RefineTarget.label: these strings go on the wire
/// to the agent, never to the reader (see [PlanNotifier.appendSectionRefinement]).
const _supersededSeedPrefix = '(Earlier listing for ';

String _supersededSeed(String label) =>
    '$_supersededSeedPrefix$label — superseded; the itinerary as it stands is '
    'described in the latest message below, and get_trip returns the '
    'authoritative version.)';

const _ignoreStaleListings =
    'Ignore any earlier itinerary listings in this conversation; they are '
    'stale. This one, and get_trip, are current.';

/// Re-reads the traveler profile after the agent writes it. `load()`, not
/// `loadIfNeeded()`: the cached copy is exactly what is wrong here.
void _refetchProfileFields(Ref ref, Set<String> fields) {
  if (fields.contains('home_airport')) {
    ref.read(preferencesProvider.notifier).load();
  }
}

final planProvider = StateNotifierProvider<PlanNotifier, PlanState>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return PlanNotifier(PlanService(apiClient.baseUrl), apiClient,
      onProfileFieldsChanged: (f) => _refetchProfileFields(ref, f));
});

/// Per-trip refinement session for the trip-detail panel, kept separate from
/// the global [planProvider] so panel chats never clobber the Agent tab's
/// conversation. keepAlive preserves the conversation across panel
/// close/reopen while the app runs; it is reset explicitly when a new
/// refinement target is chosen.
final tripRefineProvider = StateNotifierProvider.family<PlanNotifier, PlanState, String>((ref, tripId) {
  final apiClient = ref.watch(apiClientProvider);
  return PlanNotifier(PlanService(apiClient.baseUrl), apiClient,
      tripId: tripId,
      onProfileFieldsChanged: (f) => _refetchProfileFields(ref, f));
});
