package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"net/mail"
	"strings"
	"time"

	"github.com/google/uuid"
	"golang.org/x/crypto/bcrypt"

	"travel-route-planner/store"
)

const sessionDuration = 30 * 24 * time.Hour // 30 days (see user-accounts spec)

func hashPassword(plain string) (string, error) {
	b, err := bcrypt.GenerateFromPassword([]byte(plain), 12)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func checkPassword(hash, plain string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(plain)) == nil
}

// hasPassword reports whether the account can authenticate with a password.
// SSO-only accounts (created via Google) have a nil hash until they set one
// through the password-reset flow.
func hasPassword(u store.User) bool {
	return u.PasswordHash != nil && *u.PasswordHash != ""
}

func checkUserPassword(u store.User, plain string) bool {
	return hasPassword(u) && checkPassword(*u.PasswordHash, plain)
}

// generateSessionToken returns a 64-char hex string from 32 random bytes.
func generateSessionToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// hashBearerToken returns the SHA-256 hex digest of a bearer token. Session
// tokens are stored as this digest so a database read can't yield a usable
// token; the raw token (held only by the client) is hashed the same way on
// every lookup. Matches the Postgres `encode(sha256(id::bytea),'hex')` the
// hashing migration applies to pre-existing rows, so old sessions keep working.
func hashBearerToken(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

// issueSession mints a new session and returns the RAW token for the client.
// The database stores only its hash — the raw is never persisted.
func issueSession(ctx context.Context, q *store.Queries, userID uuid.UUID) (string, error) {
	token, err := generateSessionToken()
	if err != nil {
		return "", err
	}
	if _, err := q.CreateSession(ctx, store.CreateSessionParams{
		ID:        hashBearerToken(token),
		UserID:    userID,
		ExpiresAt: time.Now().Add(sessionDuration),
	}); err != nil {
		return "", err
	}
	return token, nil
}

func validateEmail(email string) bool {
	_, err := mail.ParseAddress(email)
	return err == nil
}

// defaultDisplayName uses the local part of the email when the user supplies none.
func defaultDisplayName(email string) string {
	if i := strings.Index(email, "@"); i > 0 {
		return email[:i]
	}
	return email
}
