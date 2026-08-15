package main

import (
	"database/sql"
	"net/url"
	"os"
	"strings"
	"testing"

	"github.com/pressly/goose/v3"
)

// migration_00064_backfill_test.go — the part of 00064 that touches live data.
//
// "Migrations apply from zero" (CI) runs the backfill against an empty table,
// which proves the SQL parses and proves nothing about what it does to the rows
// already in production. Every home leg a traveler owns goes through these
// statements exactly once, on deploy day, and a row the backfill leaves behind
// falls outside the next sync's key set — so this is the one test standing
// between a booked flight and a demoted orphan.
//
// It migrates a scratch database to 00063, seeds rows in the OLD shape, then
// applies 00064 and reads back what happened.

// migrateScratchDB creates a throwaway database, brings it to `version`, and
// returns a handle plus a cleanup. Skips (rather than fails) when the test
// server won't allow CREATE DATABASE — the assertions below are worth having
// wherever they can run, and are not worth a red build where they can't.
func migrateScratchDB(t *testing.T, version int64) *sql.DB {
	t.Helper()
	base := os.Getenv("TEST_DATABASE_URL")
	if base == "" {
		t.Skip("TEST_DATABASE_URL not set")
	}
	u, err := url.Parse(base)
	if err != nil {
		t.Fatalf("parse TEST_DATABASE_URL: %v", err)
	}
	const scratch = "travel_mig64_scratch"

	adminURL := *u
	adminURL.Path = "/postgres"
	admin, err := sql.Open("pgx", adminURL.String())
	if err != nil {
		t.Fatalf("open admin db: %v", err)
	}
	defer admin.Close()
	if _, err := admin.Exec(`DROP DATABASE IF EXISTS ` + scratch); err != nil {
		t.Skipf("cannot manage databases on this server: %v", err)
	}
	if _, err := admin.Exec(`CREATE DATABASE ` + scratch); err != nil {
		t.Skipf("cannot create a scratch database on this server: %v", err)
	}

	scratchURL := *u
	scratchURL.Path = "/" + scratch
	db, err := sql.Open("pgx", scratchURL.String())
	if err != nil {
		t.Fatalf("open scratch db: %v", err)
	}
	t.Cleanup(func() {
		db.Close()
		admin2, err := sql.Open("pgx", adminURL.String())
		if err != nil {
			return
		}
		defer admin2.Close()
		admin2.Exec(`DROP DATABASE IF EXISTS ` + scratch)
	})

	goose.SetBaseFS(embeddedMigrations)
	if err := goose.SetDialect("postgres"); err != nil {
		t.Fatalf("goose dialect: %v", err)
	}
	if err := goose.UpTo(db, "migrations", version); err != nil {
		t.Fatalf("migrate to %d: %v", version, err)
	}
	return db
}

// seedLegacyTrip writes rows exactly as the pre-00064 code stored them: keys
// built from the endpoint labels, no role, no endpoint columns.
func seedLegacyTrip(t *testing.T, db *sql.DB, rows [][3]any) string {
	t.Helper()
	var userID, tripID string
	if err := db.QueryRow(
		`INSERT INTO users (email) VALUES ($1) RETURNING id`,
		// Emails are stored lowercased, enforced by a CHECK since 00002.
		strings.ToLower("legacy-"+t.Name()+"@example.com")).Scan(&userID); err != nil {
		t.Fatalf("seed user: %v", err)
	}
	if err := db.QueryRow(`INSERT INTO trips (user_id, title) VALUES ($1, 'Legacy trip') RETURNING id`,
		userID).Scan(&tripID); err != nil {
		t.Fatalf("seed trip: %v", err)
	}
	for i, r := range rows {
		kind, key, title := r[0].(string), r[1].(string), r[2].(string)
		if _, err := db.Exec(
			`INSERT INTO booking_todos (trip_id, kind, todo_key, title, position, auto, booked)
			 VALUES ($1, $2, $3, $4, $5, true, $6)`,
			tripID, kind, key, title, i, i == 0); err != nil {
			t.Fatalf("seed row %q: %v", key, err)
		}
	}
	return tripID
}

type legacyRow struct {
	key, role, originLabel, destLabel string
	booked                            bool
}

func readRows(t *testing.T, db *sql.DB, tripID string) map[string]legacyRow {
	t.Helper()
	rows, err := db.Query(
		`SELECT title, todo_key, coalesce(role,''), coalesce(origin_label,''),
		        coalesce(destination_label,''), booked
		   FROM booking_todos WHERE trip_id = $1`, tripID)
	if err != nil {
		t.Fatalf("read rows: %v", err)
	}
	defer rows.Close()
	out := map[string]legacyRow{}
	for rows.Next() {
		var title string
		var r legacyRow
		if err := rows.Scan(&title, &r.key, &r.role, &r.originLabel, &r.destLabel, &r.booked); err != nil {
			t.Fatalf("scan: %v", err)
		}
		out[title] = r
	}
	return out
}

func TestMigration00064BackfillsLiveRows(t *testing.T) {
	db := migrateScratchDB(t, 63)

	// A two-city round trip out of EWR, stored the old way. The outbound is
	// booked — the flag the old prune destroyed.
	tripID := seedLegacyTrip(t, db, [][3]any{
		{"transport", "transport:ewr>>amsterdam", "EWR → Amsterdam"},
		{"stay", "stay:amsterdam", "Stay in Amsterdam"},
		{"transport", "transport:amsterdam>>rome", "Amsterdam → Rome"},
		{"stay", "stay:rome", "Stay in Rome"},
		{"transport", "transport:rome>>ewr", "Rome → EWR"},
	})

	if err := goose.UpTo(db, "migrations", 64); err != nil {
		t.Fatalf("apply 00064: %v", err)
	}

	got := readRows(t, db, tripID)
	cases := []struct {
		title string
		want  legacyRow
	}{
		{"EWR → Amsterdam", legacyRow{
			key: "transport:@home>>amsterdam", role: roleHomeOutbound,
			originLabel: "EWR", destLabel: "Amsterdam", booked: true}},
		{"Rome → EWR", legacyRow{
			key: "transport:rome>>@home", role: roleHomeReturn,
			originLabel: "Rome", destLabel: "EWR"}},
		// An inter-city leg is not a journey endpoint: its key is untouched.
		{"Amsterdam → Rome", legacyRow{
			key: "transport:amsterdam>>rome", role: roleInterCity,
			originLabel: "Amsterdam", destLabel: "Rome"}},
		{"Stay in Amsterdam", legacyRow{
			key: "stay:amsterdam", role: roleStay, destLabel: "Amsterdam"}},
	}
	for _, tc := range cases {
		t.Run(tc.title, func(t *testing.T) {
			r, ok := got[tc.title]
			if !ok {
				t.Fatalf("row %q vanished in the backfill", tc.title)
			}
			if r != tc.want {
				t.Fatalf("row %q = %+v, want %+v", tc.title, r, tc.want)
			}
		})
	}

	// The identity the runtime canonicalizer produces for the same payload must
	// be the one the backfill just wrote — otherwise the first sync after the
	// deploy prunes every home leg it didn't recognize.
	idents := classifyDerivedTodos([]DerivedBookingTodo{
		leg("transport:ewr>>amsterdam", "EWR", "Amsterdam"),
		stay("Amsterdam"),
		leg("transport:amsterdam>>rome", "Amsterdam", "Rome"),
		stay("Rome"),
		leg("transport:rome>>ewr", "Rome", "EWR"),
	})
	if idents[0].key != got["EWR → Amsterdam"].key {
		t.Fatalf("runtime key %q != backfilled key %q", idents[0].key, got["EWR → Amsterdam"].key)
	}
	if idents[4].key != got["Rome → EWR"].key {
		t.Fatalf("runtime key %q != backfilled key %q", idents[4].key, got["Rome → EWR"].key)
	}
}

// A trip whose canonical key is already taken must not lose a leg, and must not
// end up with a home role on a non-canonical key — the 00064 CHECK constraints
// reject that pairing, so a careless backfill would abort the whole migration.
func TestMigration00064CollisionKeepsBothRows(t *testing.T) {
	db := migrateScratchDB(t, 63)

	tripID := seedLegacyTrip(t, db, [][3]any{
		{"transport", "transport:ewr>>amsterdam", "EWR → Amsterdam"},
		{"transport", "transport:@home>>amsterdam", "@home → Amsterdam"},
		{"stay", "stay:amsterdam", "Stay in Amsterdam"},
	})

	if err := goose.UpTo(db, "migrations", 64); err != nil {
		t.Fatalf("apply 00064 over a collision: %v", err)
	}

	got := readRows(t, db, tripID)
	if len(got) != 3 {
		t.Fatalf("rows after backfill = %d, want 3 (nothing may be dropped): %+v", len(got), got)
	}
	loser := got["EWR → Amsterdam"]
	if loser.key != "transport:ewr>>amsterdam" {
		t.Fatalf("blocked rename should keep the literal key, got %q", loser.key)
	}
	if isHomeRole(loser.role) {
		t.Fatalf("a home role on a literal key violates the CHECK pairing: %+v", loser)
	}
}
