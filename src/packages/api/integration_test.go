package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/mux"
	"github.com/jackc/pgx/v5/pgconn"
	"golang.org/x/crypto/bcrypt"

	"travel-route-planner/store"
)

// Postgres-backed handler/authorization tests. They activate only when
// TEST_DATABASE_URL is set (CI provides a postgres:16 service); without it
// every integration test skips and the pure test suite runs as before.
//
// Isolation is TRUNCATE-between-tests (resetDB), so integration tests must
// not use t.Parallel(). goose_db_version is never truncated.

var testRouter *mux.Router

func TestMain(m *testing.M) {
	if url := os.Getenv("TEST_DATABASE_URL"); url != "" {
		if err := runMigrations(url); err != nil {
			log.Fatalf("test DB migration failed: %v", err)
		}
		pool, err := initDB(context.Background(), url)
		if err != nil {
			log.Fatalf("test DB unreachable: %v", err)
		}
		dbPool = pool
		testRouter = buildRouter()
	}
	os.Exit(m.Run())
}

func requireDB(t *testing.T) {
	t.Helper()
	if dbPool == nil {
		t.Skip("TEST_DATABASE_URL not set")
	}
}

// resetDB truncates all application tables so each test starts clean.
// The TRUNCATE can deadlock (SQLSTATE 40P01) with fire-and-forget analytics
// goroutines still committing from the previous test — retry briefly rather
// than flaking the suite.
func resetDB(t *testing.T) {
	t.Helper()
	requireDB(t)
	var err error
	for attempt := 0; attempt < 5; attempt++ {
		_, err = dbPool.Exec(context.Background(), `TRUNCATE
			users, sessions, trips, itinerary_items, traveler_preferences,
			accommodations, trip_segments, booking_todos, trip_checklist_items,
			trip_budgets, trip_expenses, trip_shares,
			trip_collaborators, email_tokens, auth_identities, analytics_events, price_alerts,
			alert_events, notifications, reminder_sends,
			local_sources, local_recommendations, local_guides,
			local_guide_recommendations, local_source_material,
			plan_chat_sessions, oauth_clients, oauth_auth_codes,
			oauth_grants, oauth_tokens CASCADE`)
		if err == nil {
			return
		}
		var pgErr *pgconn.PgError
		if !errors.As(err, &pgErr) || pgErr.Code != "40P01" {
			break
		}
		time.Sleep(time.Duration(50*(attempt+1)) * time.Millisecond)
	}
	t.Fatalf("resetDB: %v", err)
}

// testIPCounter hands every request a unique client IP. clientIP() trusts the
// rightmost X-Forwarded-For entry, so this keeps the strict per-IP rate
// limiter (5/min on auth routes) from bleeding between tests.
var testIPCounter atomic.Uint64

func nextTestIP() string {
	n := testIPCounter.Add(1)
	return fmt.Sprintf("10.99.%d.%d", (n>>8)&0xff, n&0xff)
}

// doJSON drives the shared router in-process. token "" means anonymous;
// ip "" means a fresh unique IP (pass a fixed ip to exercise rate limiting).
func doJSON(t *testing.T, method, path, token string, body any) *httptest.ResponseRecorder {
	t.Helper()
	return doJSONFromIP(t, method, path, token, nextTestIP(), body)
}

func doJSONFromIP(t *testing.T, method, path, token, ip string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatalf("encode body: %v", err)
		}
	}
	req := httptest.NewRequest(method, path, &buf)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Forwarded-For", ip)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	testRouter.ServeHTTP(rec, req)
	return rec
}

// decode unmarshals a recorder body into a map for loose assertions.
func decode(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &m); err != nil {
		t.Fatalf("decode %q: %v", rec.Body.String(), err)
	}
	return m
}

// testPasswordHash is bcrypt.MinCost so fixtures don't pay the production
// cost-12 hash (~300ms each). Only the tests that exercise the real
// register/login flow go through full-cost hashing.
var testPasswordHash = func() string {
	b, err := bcrypt.GenerateFromPassword([]byte("password123"), bcrypt.MinCost)
	if err != nil {
		panic(err)
	}
	return string(b)
}()

// createTestUser inserts a user directly (bypassing bcrypt cost 12 and the
// rate-limited register route) and returns it with a live session token.
func createTestUser(t *testing.T, email string) (store.User, string) {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	name := "Test User"
	u, err := q.CreateUser(ctx, store.CreateUserParams{
		Email: email, PasswordHash: &testPasswordHash, DisplayName: &name,
	})
	if err != nil {
		t.Fatalf("createTestUser(%s): %v", email, err)
	}
	token, err := issueSession(ctx, q, u.ID)
	if err != nil {
		t.Fatalf("issueSession(%s): %v", email, err)
	}
	return u, token
}

func makeAdmin(t *testing.T, id uuid.UUID) {
	t.Helper()
	if _, err := dbPool.Exec(context.Background(), `UPDATE users SET is_admin = true WHERE id = $1`, id); err != nil {
		t.Fatalf("makeAdmin: %v", err)
	}
}

// createTestTrip inserts a trip with n itinerary items owned by owner.
func createTestTrip(t *testing.T, owner uuid.UUID, items int) store.Trip {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	chat := uuid.NewString()
	trip, err := q.CreateTrip(ctx, store.CreateTripParams{
		UserID: owner, Title: "Test Trip", Status: "draft", ChatID: &chat,
	})
	if err != nil {
		t.Fatalf("createTestTrip: %v", err)
	}
	for i := 0; i < items; i++ {
		_, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
			TripID: trip.ID, Position: int32(i), Name: fmt.Sprintf("Place %d", i+1),
			Latitude: 37.97 + float64(i)*0.01, Longitude: 23.72,
		})
		if err != nil {
			t.Fatalf("createTestTrip item %d: %v", i, err)
		}
	}
	return trip
}
