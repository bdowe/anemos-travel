-- name: ListTripsForReminder :many
-- Latest dated trip per lineage departing on the target date (today+3 for
-- 'trip_soon', today for 'trip_today'), joined to its owner. There is no
-- status gate (specs/retire-trip-status): a departure date in the window IS
-- the signal. The NOT EXISTS collapses a trip's version chain to its newest
-- dated version so one lineage reminds once. reminders_opt_out is RETURNED,
-- not filtered: the caller still writes the in-app notification for opted-out
-- users and only the email is skipped. Rows already recorded in reminder_sends
-- for this (user, lineage, kind) are excluded so a kind fires once across
-- ticks.
SELECT t.id,
       t.user_id,
       t.title,
       t.start_date,
       COALESCE(t.chat_id, t.id::text)::text AS lineage_key,
       u.email,
       u.display_name,
       u.reminders_opt_out,
       -- The email is rendered with no request context, so the recipient's
       -- stored language rides along with the row (NULL => English).
       u.locale
FROM trips t
JOIN users u ON u.id = t.user_id
WHERE t.start_date = sqlc.arg('target_date')
  -- Latest dated version of this lineage: no newer dated version exists (the
  -- flat equivalent of ListLatestTripsByOwner's DISTINCT ON, so one lineage
  -- yields at most one reminder row).
  AND NOT EXISTS (
    SELECT 1 FROM trips t2
    WHERE COALESCE(t2.chat_id, t2.id::text) = COALESCE(t.chat_id, t.id::text)
      AND t2.start_date IS NOT NULL
      AND t2.created_at > t.created_at
  )
  AND NOT EXISTS (
    SELECT 1 FROM reminder_sends rs
    WHERE rs.user_id = t.user_id
      AND rs.trip_lineage_key = COALESCE(t.chat_id, t.id::text)
      AND rs.kind = sqlc.arg('kind')
  )
ORDER BY t.start_date
LIMIT sqlc.arg('row_limit');

-- name: RecordReminderSent :exec
-- Dedup guard for the trip-reminder checker. Written BEFORE the email so a
-- crashed/retried tick can never double-send.
-- ON CONFLICT is belt-and-suspenders — ListTripsForReminder already excludes
-- recorded rows, but two overlapping ticks must not error on the unique index.
INSERT INTO reminder_sends (user_id, trip_lineage_key, kind)
VALUES ($1, $2, $3)
ON CONFLICT (user_id, trip_lineage_key, kind) DO NOTHING;

-- name: ListUsersForWeeklyNudge :many
-- Users who started planning but went quiet: their most recent activity (max
-- updated_at across trips and un-graduated plan chats) is older than the idle
-- cutoff, unfinished work remains, and they haven't been nudged within the
-- window. "Unfinished work" is derived, not a status flag
-- (specs/retire-trip-status):
--   (a) an undated trip — the latest version of a lineage with no start_date
--       (started planning, never scheduled), OR
--   (b) an upcoming trip with unbooked homework — the latest version of a
--       lineage departing on/after 'today' that still has an unbooked
--       booking todo, OR
--   (c) a resumable plan chat — one whose chat_id has not become a trip.
-- 'today' is the checker's calendar date (the same injectable-clock seam as
-- ListTripsForReminder's target_date). nudges_opt_out is RETURNED, not
-- filtered: the caller writes the in-app nudge for everyone and only the
-- email is skipped. The cutoff is now()-7d supplied by the caller; it gates
-- both the idle test and the once-a-week guard.
SELECT u.id,
       u.email,
       u.display_name,
       u.nudges_opt_out,
       -- Same as ListTripsForReminder: request-less job, so the language comes
       -- from the row (NULL => English).
       u.locale
FROM users u
WHERE (u.last_weekly_nudge_at IS NULL OR u.last_weekly_nudge_at < sqlc.arg('cutoff'))
  AND (
    EXISTS (
      SELECT 1 FROM trips t
      WHERE t.user_id = u.id
        AND t.start_date IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM trips tn
          WHERE tn.user_id = u.id
            AND COALESCE(tn.chat_id, tn.id::text) = COALESCE(t.chat_id, t.id::text)
            AND tn.created_at > t.created_at
        )
    )
    OR EXISTS (
      SELECT 1 FROM trips t
      JOIN booking_todos bt ON bt.trip_id = t.id AND NOT bt.booked
      WHERE t.user_id = u.id
        AND t.start_date >= sqlc.arg('today')
        AND NOT EXISTS (
          SELECT 1 FROM trips tn
          WHERE tn.user_id = u.id
            AND COALESCE(tn.chat_id, tn.id::text) = COALESCE(t.chat_id, t.id::text)
            AND tn.created_at > t.created_at
        )
    )
    OR EXISTS (
      SELECT 1 FROM plan_chat_sessions s
      WHERE s.user_id = u.id
        AND NOT EXISTS (SELECT 1 FROM trips t2 WHERE t2.chat_id = s.chat_id)
    )
  )
  AND GREATEST(
        COALESCE((SELECT max(updated_at) FROM trips t3 WHERE t3.user_id = u.id), 'epoch'::timestamptz),
        COALESCE((SELECT max(updated_at) FROM plan_chat_sessions s2 WHERE s2.user_id = u.id), 'epoch'::timestamptz)
      ) < sqlc.arg('cutoff')
ORDER BY u.id
LIMIT sqlc.arg('row_limit');

-- name: TouchWeeklyNudge :exec
-- Records that we just nudged this user; the timestamp is the once-a-week guard
-- ListUsersForWeeklyNudge checks. Written BEFORE the email so a crashed tick
-- can't re-nudge.
UPDATE users SET last_weekly_nudge_at = now() WHERE id = $1;
