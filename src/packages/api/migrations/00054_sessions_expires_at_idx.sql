-- +goose Up
-- Perf (hot-path tax removal): DeleteExpiredSessions filters on expires_at,
-- which had no index — every prune was a sequential scan over sessions. The
-- prune now runs hourly in janitor.go instead of inside every authenticated
-- request, and this index makes that tick an index scan.
CREATE INDEX idx_sessions_expires_at ON sessions (expires_at);

-- +goose Down
DROP INDEX idx_sessions_expires_at;
