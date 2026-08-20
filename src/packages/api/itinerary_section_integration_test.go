package main

import (
	"context"
	"strings"
	"testing"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// seedSectionTrip writes items in position order and returns the trip.
func seedSectionTrip(t *testing.T, owner uuid.UUID, rows []store.ItineraryItem) store.Trip {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	chat := uuid.NewString()
	trip, err := q.CreateTrip(ctx, store.CreateTripParams{
		UserID: owner, Title: "Section Guard Trip", ChatID: &chat,
	})
	if err != nil {
		t.Fatalf("CreateTrip: %v", err)
	}
	for i, it := range rows {
		p := itemParamsFromLocation(trip.ID, int32(i), locationFromItem(it))
		if _, err := q.CreateItineraryItem(ctx, p); err != nil {
			t.Fatalf("CreateItineraryItem %d: %v", i, err)
		}
	}
	return trip
}

func tripItemSummary(t *testing.T, tripID uuid.UUID) string {
	t.Helper()
	items, err := store.New(dbPool).GetItineraryItemsByTrip(context.Background(), tripID)
	if err != nil {
		t.Fatalf("GetItineraryItemsByTrip: %v", err)
	}
	var b strings.Builder
	for _, it := range items {
		// describeItem already carries position, name, hub and day — the whole
		// of what a rewrite could have changed.
		b.WriteString(describeItem(it) + "\n")
	}
	return b.String()
}

// THE ordering guarantee this guard depends on: replaceTripSection calls
// spliceSection BEFORE its delete, so a rejected whole-trip rewrite leaves the
// trip byte-for-byte unchanged and the model retries against real state. If that
// ordering ever inverts, the guard turns from a safety net into a way to empty
// somebody's itinerary — a rejection that has already deleted every row.
//
// Asserted against Postgres rather than by reading the source, because the claim
// is about what the transaction leaves behind, not about statement order.
func TestReplaceTripSectionWritesNothingWhenTripScopeRejected(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "section-guard@example.com")
	trip := seedSectionTrip(t, owner.ID, []store.ItineraryItem{
		item("Charles Bridge", 1, "Prague", ""),
		item("Old Town Square", 2, "Prague", ""),
		item("Wawel Castle", 3, "Krakow", ""),
		item("Rynek Glowny", 4, "Krakow", ""),
	})
	before := tripItemSummary(t, trip.ID)
	if strings.TrimSpace(before) == "" {
		t.Fatal("fixture did not seed: nothing to prove unchanged")
	}

	// The 2026-08-20 shape: Krakow split into twin runs disagreeing about dates.
	bad := []map[string]any{
		rl("Wawel Castle", 1, "Krakow", ""),
		rl("Rynek Glowny", 2, "Krakow", ""),
		rl("Charles Bridge", 3, "Prague", ""),
		rl("Old Town Square", 4, "Prague", ""),
		rl("Wawel Castle", 3, "Krakow", ""),
		rl("Rynek Glowny", 4, "Krakow", ""),
	}
	err := replaceTripSection(context.Background(), trip.ID, owner.ID,
		sectionSelector{Scope: "trip"}, bad)
	if err == nil {
		t.Fatal("a fragmented whole-trip payload must be rejected")
	}
	if !strings.Contains(err.Error(), "Krakow") {
		t.Fatalf("rejection %q should name the offending city", err)
	}
	if after := tripItemSummary(t, trip.ID); after != before {
		t.Fatalf("a rejected rewrite wrote to the trip:\nbefore:\n%safter:\n%s", before, after)
	}
}

// The complement, and the reason the test above is not just asserting that
// nothing works: a legal whole-trip rewrite through the SAME path must still
// land. Paris → Rome → Paris, written for real.
func TestReplaceTripSectionWritesGenuineRevisit(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "section-guard-ok@example.com")
	trip := seedSectionTrip(t, owner.ID, []store.ItineraryItem{
		item("Louvre", 1, "Paris", ""),
		item("Colosseum", 3, "Rome", ""),
	})

	revisit := []map[string]any{
		rl("Louvre", 1, "Paris", ""),
		rl("Orsay", 2, "Paris", ""),
		rl("Colosseum", 3, "Rome", ""),
		rl("Forum", 4, "Rome", ""),
		rl("Sacre-Coeur", 5, "Paris", ""),
	}
	if err := replaceTripSection(context.Background(), trip.ID, owner.ID,
		sectionSelector{Scope: "trip"}, revisit); err != nil {
		t.Fatalf("Paris → Rome → Paris must still write: %v", err)
	}
	items, err := store.New(dbPool).GetItineraryItemsByTrip(context.Background(), trip.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 5 {
		t.Fatalf("expected 5 items written, got %d", len(items))
	}
	// The revisit must survive as two Paris runs — that is the shape under test.
	runs := hubRuns(runItemsOfStored(items))
	if len(runs) != 3 {
		t.Fatalf("expected Paris/Rome/Paris to persist as 3 runs, got %d", len(runs))
	}
}
