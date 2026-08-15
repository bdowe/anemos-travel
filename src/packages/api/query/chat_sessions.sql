-- name: UpsertPlanChatSession :exec
-- Whole-transcript upsert, twice per /plan turn (start + deferred end).
-- title is set once from the opening message and never overwritten, so the
-- entry keeps a stable identity in the continue list.
INSERT INTO plan_chat_sessions (
    user_id, chat_id, title, preview, summary, messages, message_count
) VALUES ($1, $2, $3, $4, $5, $6, $7)
ON CONFLICT (user_id, chat_id) DO UPDATE SET
    preview = EXCLUDED.preview,
    summary = EXCLUDED.summary,
    messages = EXCLUDED.messages,
    message_count = EXCLUDED.message_count,
    updated_at = now();

-- name: ListResumablePlanChatSessions :many
-- Summary columns only (messages can be large). A chat that already produced
-- a trip is represented by its trip card, so it is excluded here — this also
-- hides abandoned refine chats, whose chat_id belongs to an existing trip.
SELECT id, chat_id, title, preview, message_count, created_at, updated_at
FROM plan_chat_sessions s
WHERE s.user_id = $1
  AND NOT EXISTS (
      SELECT 1 FROM trips t
      WHERE t.user_id = s.user_id AND t.chat_id = s.chat_id
  )
ORDER BY s.updated_at DESC
LIMIT 10;

-- name: GetPlanChatSessionByChatID :one
SELECT * FROM plan_chat_sessions
WHERE user_id = $1 AND chat_id = $2;

-- name: DeletePlanChatSession :execrows
DELETE FROM plan_chat_sessions
WHERE user_id = $1 AND chat_id = $2;

-- name: DeleteStalePlanChatSessions :exec
-- Opportunistic prune (called from the list handler): a conversation idle for
-- two months is abandoned, not "in progress". Deliberately does NOT reach
-- trip_refine_sessions: a trip planned in August for next March must still
-- have its chat in November, so those are retained for the trip's lifetime and
-- collected by the FK cascade instead (specs/trip-refine-memory).
DELETE FROM plan_chat_sessions
WHERE updated_at < now() - interval '60 days';

-- name: UpsertTripRefineSession :exec
-- Whole-transcript upsert, twice per trip-bound /plan turn (start + deferred
-- end), under the same start→final ordering contract as
-- UpsertPlanChatSession. Keyed by (user, trip): the client's per-panel chat_id
-- is meaningless here and is deliberately not stored, which is what makes a
-- refine transcript unaddressable by chat id (specs/trip-refine-memory).
INSERT INTO trip_refine_sessions (
    user_id, trip_id, preview, summary, messages, message_count
) VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (user_id, trip_id) DO UPDATE SET
    preview = EXCLUDED.preview,
    summary = EXCLUDED.summary,
    messages = EXCLUDED.messages,
    message_count = EXCLUDED.message_count,
    updated_at = now();

-- name: GetTripRefineSession :one
SELECT * FROM trip_refine_sessions
WHERE user_id = $1 AND trip_id = $2;

-- name: GetTripRefineSessionSummary :one
-- Presence + freshness for GET /trips/{id} (the refine_chat object). Summary
-- columns only: the transcript can run to hundreds of KB and is fetched on
-- demand from GET /trips/{id}/refine-chat, never on every trip page load —
-- the same list/detail split as /chats.
SELECT preview, message_count, updated_at FROM trip_refine_sessions
WHERE user_id = $1 AND trip_id = $2;

-- name: DeleteTripRefineSession :execrows
DELETE FROM trip_refine_sessions
WHERE user_id = $1 AND trip_id = $2;
