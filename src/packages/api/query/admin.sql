-- Admin analytics dashboard extensions (trends / totals / activity / users).
-- Read-only rollups behind /api/v1/admin/metrics/*; nothing here is written to.

-- name: EventDailyCounts :many
-- Daily buckets for the Trends tab. Bucketing is explicit UTC so results do
-- not depend on the server's TimeZone GUC. Output is sparse — days with zero
-- events are absent; the client fills gaps (it knows start_day and days, so
-- shipping generate_series zeros would only bloat the payload).
SELECT (created_at AT TIME ZONE 'UTC')::date AS day,
       event_type,
       count(*)::bigint AS n
FROM analytics_events
WHERE created_at >= sqlc.arg(since) AND event_type = ANY(sqlc.arg(event_types)::text[])
GROUP BY 1, 2
ORDER BY 1;

-- name: AdminTotals :one
-- All-time live counts straight off the domain tables — the numbers the
-- event-log rollups in analytics.sql cannot produce (events only exist since
-- 00026, and deletes never reach the log). One round trip of scalar
-- subselects; each is an index or small-table scan at current scale.
SELECT
  (SELECT count(*) FROM users)::bigint AS users,
  (SELECT count(*) FROM users WHERE email_verified_at IS NOT NULL)::bigint AS verified_users,
  (SELECT count(*) FROM users WHERE onboarded_at IS NOT NULL)::bigint AS onboarded_users,
  (SELECT count(*) FROM trips)::bigint AS trips,
  -- Lineages: COALESCE(chat_id, id) — the My Trips grouping, same rule as
  -- UserEngagementCounts in analytics.sql.
  (SELECT count(DISTINCT COALESCE(chat_id, id::text)) FROM trips)::bigint AS trip_lineages,
  (SELECT count(*) FROM itinerary_items)::bigint AS itinerary_items,
  (SELECT count(*) FROM booking_todos)::bigint AS booking_todos,
  (SELECT count(*) FROM local_recommendations WHERE status = 'published')::bigint AS published_local_recs,
  (SELECT count(*) FROM local_guides)::bigint AS local_guides,
  (SELECT count(*) FROM trip_collaborators WHERE revoked_at IS NULL)::bigint AS active_collaborators,
  (SELECT count(*) FROM trip_shares WHERE revoked_at IS NULL)::bigint AS active_shares,
  (SELECT count(*) FROM sessions WHERE expires_at > now())::bigint AS active_sessions,
  (SELECT count(*) FROM analytics_events)::bigint AS analytics_events;

-- name: RecentAnalyticsEvents :many
-- Activity-feed tail, keyset-paginated: the client passes the last row's
-- created_at back as $1 for the next page. COALESCE keeps sqlc's LEFT-JOIN
-- nullability simple; the handler decides "anonymous" from user_id being
-- NULL, never from an empty email. When exclude_admins is true, rows from
-- admin users are dropped so the operator's own clicks don't pollute the
-- funnel/activity feed (anonymous rows survive — NULL is_admin COALESCEs to
-- false). ORDER BY created_at DESC is served by the bare created_at index
-- added in 00043.
SELECT e.id, e.event_type, e.user_id,
       COALESCE(u.email, '')::text AS user_email,
       COALESCE(u.is_admin, false)::boolean AS user_is_admin,
       e.trip_id, e.metadata, e.created_at
FROM analytics_events e
LEFT JOIN users u ON u.id = e.user_id
WHERE e.created_at < sqlc.arg(before)
  AND (NOT sqlc.arg(exclude_admins)::bool OR NOT COALESCE(u.is_admin, false))
ORDER BY e.created_at DESC
LIMIT sqlc.arg(page_limit);

-- name: AdminUserActivity :many
-- Per-user drill-down rows: users LEFT JOIN two grouped subqueries (trips by
-- lineage, and analytics rollups). Token sums are FILTERed to
-- plan_session_completed — the same guard as PlanSessionTotals — so no other
-- event's metadata is ever summed; (metadata->>'k')::bigint is NULL when the
-- key is absent and sum() skips NULLs.
SELECT u.id, u.email, u.display_name, u.is_admin,
       u.created_at AS signed_up_at,
       (u.onboarded_at IS NOT NULL)::boolean AS onboarded,
       (u.email_verified_at IS NOT NULL)::boolean AS email_verified,
       COALESCE(t.trips, 0)::bigint AS trips,
       COALESCE(t.trip_lineages, 0)::bigint AS trip_lineages,
       COALESCE(a.plan_sessions, 0)::bigint AS plan_sessions,
       COALESCE(a.booking_clicks, 0)::bigint AS booking_clicks,
       COALESCE(a.input_tokens, 0)::bigint AS plan_input_tokens,
       COALESCE(a.output_tokens, 0)::bigint AS plan_output_tokens,
       COALESCE(a.cache_read_tokens, 0)::bigint AS plan_cache_read_tokens,
       COALESCE(a.cache_creation_tokens, 0)::bigint AS plan_cache_creation_tokens,
       a.last_event_at
FROM users u
LEFT JOIN (
  SELECT user_id, count(*) AS trips,
         count(DISTINCT COALESCE(chat_id, id::text)) AS trip_lineages
  FROM trips GROUP BY user_id
) t ON t.user_id = u.id
LEFT JOIN (
  SELECT user_id,
         count(*) FILTER (WHERE event_type = 'plan_session_started') AS plan_sessions,
         count(*) FILTER (WHERE event_type = 'booking_link_clicked') AS booking_clicks,
         sum((metadata->>'input_tokens')::bigint) FILTER (WHERE event_type = 'plan_session_completed') AS input_tokens,
         sum((metadata->>'output_tokens')::bigint) FILTER (WHERE event_type = 'plan_session_completed') AS output_tokens,
         sum((metadata->>'cache_read_tokens')::bigint) FILTER (WHERE event_type = 'plan_session_completed') AS cache_read_tokens,
         sum((metadata->>'cache_creation_tokens')::bigint) FILTER (WHERE event_type = 'plan_session_completed') AS cache_creation_tokens,
         max(created_at) AS last_event_at
  FROM analytics_events
  WHERE user_id IS NOT NULL
  GROUP BY user_id
) a ON a.user_id = u.id
ORDER BY a.last_event_at DESC NULLS LAST, u.created_at DESC
LIMIT $1 OFFSET $2;

-- name: CountUsers :one
SELECT count(*)::bigint FROM users;
