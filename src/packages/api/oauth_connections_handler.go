package main

import (
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/mux"

	"travel-route-planner/store"
)

// oauth_connections_handler.go: the Connected-apps surface in account settings
// (specs/mcp-connector). Listing and revoking the OAuth grants that let an AI
// connector act on the user's behalf — the kill switch the smallest compliant
// OAuth implementation would otherwise lack.
//
// These stay available even when MCP_ENABLED is false: a user must always be
// able to see and revoke a connection that was granted while it was on.

type oauthConnectionResponse struct {
	ID         string     `json:"id"`
	ClientName string     `json:"client_name"`
	Scopes     []string   `json:"scopes"`
	CreatedAt  time.Time  `json:"created_at"`
	LastUsedAt *time.Time `json:"last_used_at"`
}

func listOAuthConnectionsHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	user, ok := userFromContext(r.Context())
	if !ok {
		writeJSONError(w, http.StatusUnauthorized, "authentication required")
		return
	}
	rows, err := store.New(dbPool).ListOAuthConnectionsByUser(r.Context(), user.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not list connections")
		return
	}
	out := make([]oauthConnectionResponse, 0, len(rows))
	for _, row := range rows {
		conn := oauthConnectionResponse{
			ID:         row.ID.String(),
			ClientName: row.ClientName,
			Scopes:     strings.Fields(row.Scope),
			CreatedAt:  row.CreatedAt,
		}
		if row.LastUsedAt.Valid {
			t := row.LastUsedAt.Time
			conn.LastUsedAt = &t
		}
		out = append(out, conn)
	}
	writeJSON(w, http.StatusOK, out)
}

// revokeOAuthConnectionHandler kills a grant and every token minted under it,
// in one transaction: a half-revoked connection (grant dead, tokens live)
// would keep working until each access token expired.
func revokeOAuthConnectionHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	user, ok := userFromContext(r.Context())
	if !ok {
		writeJSONError(w, http.StatusUnauthorized, "authentication required")
		return
	}
	id, err := uuid.Parse(mux.Vars(r)["id"])
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid id")
		return
	}

	tx, err := dbPool.Begin(r.Context())
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not revoke connection")
		return
	}
	defer tx.Rollback(r.Context())
	q := store.New(tx)

	// Owner-scoped: a grant belonging to someone else is a 404, not a 403.
	if _, err := q.RevokeOAuthGrant(r.Context(), store.RevokeOAuthGrantParams{
		ID: id, UserID: user.ID,
	}); err != nil {
		writeJSONError(w, http.StatusNotFound, "connection not found")
		return
	}
	if err := q.RevokeOAuthTokensByGrant(r.Context(), id); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not revoke connection")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not revoke connection")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
