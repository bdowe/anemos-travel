# Tasks: Trip Refine Memory

## Stage 1 — Back stops destroying things (client only)

- [ ] `PopScope(canPop: !_panelOpen)` around trip detail's root builder.
- [ ] Escape closes the panel.
- [ ] Move the `trip_updated` → `_refresh` listener from `TripRefinePanel` into
      the screen; drop `onTripUpdated`.
- [ ] Delete `_refineTarget`; panel title derives from the newest labeled
      message.
- [ ] FAB shows a spinner while a turn streams with the panel closed.

## Stage 2 — One conversation (client only)

- [ ] `appendSectionRefinement` replaces `beginSectionRefinement`; earlier seeds
      stubbed in place (never removed).
- [ ] All five ✨ call sites repointed.
- [ ] "New chat" in the panel header, with a confirm.

## Stage 3 — Persistence

- [ ] `migrations/00069_trip_refine_sessions.sql`.
- [ ] Four queries in `query/chat_sessions.sql`; `make api-sqlc`.
- [ ] `planTranscriptFields` extracted in `chat_session_handler.go`.
- [ ] `trip_refine_handler.go` + routes + startup log lines.
- [ ] `plan_handler.go` persistence gate split.
- [ ] `TripResponse.RefineChat` in `getTripHandler`'s errgroup.
- [ ] `trip_refine_sessions` added to `resetDB`'s TRUNCATE list.
- [ ] Dart models + `make flutter-build-models`; service methods throwing
      `ApiException` with the status.
- [ ] `planMessagesFrom` + `resumeTripRefineChat`; `resumeConversation.chatId`
      optional.
- [ ] `_ensureRefineHydrated` gate (aborts the send on failure), Continue-chat
      row, FAB gate widened, offline hides both.
- [ ] Restoring / expired / failed panel states.

## Stage 4 — Freshness

- [ ] `runGetTripTool` returns the bound trip when `trip_id` is omitted;
      description updated.
- [ ] Bound system-prompt suffix rewritten to require `get_trip` before an edit.

## Tests

- [ ] Go: `trip_refine_chat_integration_test.go` (persistence, one-row append,
      unaddressable-as-plan-chat, `refine_chat` on the trip, GET/DELETE/access,
      idempotent DELETE, per-user rows, cascade, revoked collaborator,
      reengagement unaffected).
- [ ] Go: `TestTranscriptFieldsParity`, `TestBoundPromptSteersToGetTrip`,
      `TestGetTripToolReturnsBoundTripWithoutArgs`.
- [ ] Go: amend `TestPlanTurnNotPersistedWhenAnonymousOrBound`.
- [ ] Flutter: `trip_detail_chat_back_test.dart`,
      `trip_detail_resume_chat_test.dart`,
      `trip_detail_refine_append_test.dart`,
      `plan_provider_refine_append_test.dart`, plus the URL pin in
      `url_plan_chat_test.dart`.
- [ ] Mutation-check: back-closes-panel, append-not-reset, hydrate-before-send.

## Spec amendments

- [ ] `continue-where-you-left-off`, `collaborator-refine`,
      `refine-panel-polish`, `url-page-persistence`, `conversation-compaction`.

## Verification

- [ ] `make api-fmt && make api-vet && make api-sqlc`; `go test ./...` with
      `TEST_DATABASE_URL`; goose up/down of 00069 round-trips.
- [ ] `make flutter-build-models && make flutter-analyze` (CI runs
      `--no-fatal-infos --fatal-warnings`) and `make flutter-test`.
- [ ] Manual through the lane gateway: back closes the panel; ✨ appends; a hard
      refresh leaves the Continue-chat row; restore shows the transcript; an
      edit calls `get_trip` first; New chat clears; `GET /chats` never lists it.
- [ ] `docs/friction-log.md` entry.
