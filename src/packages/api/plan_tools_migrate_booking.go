package main

// plan_tools_migrate_booking.go — migrate_booking_todo: the agent's half of
// the booked-todo migration (stale-transport-orphans ticket 2; the write is
// booking_todo_migrate.go, shared with the REST handler).
//
// The tool exists because the model reached for the only move it had on
// 2026-08-20: remove_booking_todo — and deleted the traveler's booked
// Gothenburg → Sorrento row six minutes after the sync had safely demoted
// it. Migration is strictly safer than that delete: the SAME row is
// re-pointed at the leg that replaced its endpoints, so the booked tick, the
// saved shortlist and the linked expense survive, and the guard refuses the
// move outright when the row's places are still consecutive stops.
//
// The reporting idiom is replace_leg's: every change is named back in the
// same turn — both endpoint pairs, what carried over, and what deliberately
// did NOT change (the reservation with the provider; only the traveler can
// touch that).
//
// Registry: one entry, appended at the tail (plan_tool_registry.go). The
// tools array is the Anthropic prompt-cache prefix, so a reorder silently
// destroys caching and no test fails.

import (
	"encoding/json"
	"fmt"
	"strings"

	anthropic "github.com/anthropics/anthropic-sdk-go"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

var migrateBookingTodoTool = anthropic.ToolParam{
	Name: "migrate_booking_todo",
	Description: anthropic.String("Move a booking-checklist row onto the leg that replaced it after the route changed — the SAFE alternative to remove_booking_todo for a booked row whose two places are no longer consecutive stops (review_trip flags exactly these with fix=migrate_booking). " +
		"The SAME row is re-pointed at the current leg: the booked tick, any saved shortlist and any linked expense all carry over, where removing the row would destroy them. " +
		"It refuses when the row's places are still consecutive stops, when no current leg matches either endpoint, and when another checklist row already holds the target leg — in that last case two rows claim to be the real booking and the traveler must say which one it is. " +
		"It does NOT change the traveler's actual reservation with the provider — only they can do that — so name BOTH the old and the new leg in your reply and say plainly what carried over. " +
		"Requires the trip's id and the row's todo_id (review_trip's finding carries it as item_id, or call get_trip)."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"trip_id": map[string]any{
				"type":        "string",
				"description": "The saved trip's id",
			},
			"todo_id": map[string]any{
				"type":        "string",
				"description": "The checklist row's todo_id — from a review_trip finding's item_id or get_trip",
			},
		},
		Required: []string{"trip_id", "todo_id"},
	},
}

func runMigrateBookingTodoTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		TripID string `json:"trip_id"`
		TodoID string `json:"todo_id"`
	}
	json.Unmarshal(input, &in)

	tid, msg, failed := checkBookingTodoSession(s, in.TripID)
	if failed {
		return msg, true
	}
	todoID, err := uuid.Parse(strings.TrimSpace(in.TodoID))
	if err != nil {
		return "That todo_id is not valid; call get_trip to see the checklist with ids.", true
	}

	tx, err := dbPool.Begin(s.ctx)
	if err != nil {
		return "Could not move the booking right now.", true
	}
	defer tx.Rollback(s.ctx)
	q := store.New(tx)

	// The same row lock replace_leg and the REST handler take: a concurrent
	// sync must not re-derive the checklist between the guard read and the
	// write. The lock read doubles as the trip row the core needs.
	trip, err := q.GetTripForUpdate(s.ctx, tid)
	if err != nil {
		return "Could not load the trip to change it.", true
	}
	m, err := migrateBookingTodo(s.ctx, q, trip, todoID)
	if err != nil {
		// The sentinel refusal texts are written FOR the model — they say
		// exactly why the move was refused and what to do instead.
		return err.Error(), true
	}
	if err := q.TouchTrip(s.ctx, store.TouchTripParams{
		ID: tid, UpdatedBy: pgtype.UUID{Bytes: s.uid, Valid: true},
	}); err != nil {
		return "Could not move the booking right now.", true
	}
	if err := tx.Commit(s.ctx); err != nil {
		return "Could not move the booking right now.", true
	}

	sendSSE(s.w, "trip_updated", map[string]string{"trip_id": tid.String()})
	s.tripID = &tid
	safeGo("recordEvent", func() {
		recordEvent(s.uid, "agent_booking_todo_migrated", &tid, map[string]any{
			"from": m.OldOrigin + " → " + m.OldDestination,
			"to":   m.NewOrigin + " → " + m.NewDestination,
		})
	})
	// replace_leg's collaborator signal; the SQL self-gates for owners.
	if s.uid != s.boundTripOwnerID {
		safeGo("notifyCollabEdit", func() { notifyCollabEdit(tid, s.uid) })
	}

	return migrateBookingTodoResult(m), false
}

// migrateBookingTodoResult names every change back in the same turn, the
// replace_leg idiom: both endpoint pairs, the date, what carried over, and —
// the sentence that keeps this honest — what did NOT change.
func migrateBookingTodoResult(m *bookingTodoMigration) string {
	oldPair := m.OldOrigin + " → " + m.OldDestination
	newPair := m.NewOrigin + " → " + m.NewDestination
	var b strings.Builder
	fmt.Fprintf(&b, "Moved the booked checklist row %s onto %s", oldPair, newPair)
	if m.Todo.DepartDate.Valid {
		fmt.Fprintf(&b, ", departing %s", m.Todo.DepartDate.Time.Format(dateLayout))
	}
	b.WriteString(". It is the SAME checklist row: the booked tick, any saved booking shortlist and any linked budget expense all carried over.")
	if m.AbsorbedAutoRow {
		fmt.Fprintf(&b, " The untouched itinerary-derived row for %s was absorbed into it, so the leg has exactly one checklist row.", newPair)
	}
	b.WriteString(" The trip page has refreshed. " +
		"Name both legs to the traveler in your reply, and be plain about what did NOT change: the reservation itself. " +
		"If their ticket really is " + oldPair + ", they still hold that ticket with the provider — only they can change or cancel it; " +
		"the app now tracks the booking against " + newPair + " because that is the leg the trip flies.")
	return b.String()
}
