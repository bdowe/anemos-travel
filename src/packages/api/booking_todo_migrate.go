package main

// booking_todo_migrate.go — the ONE write that moves a booked checklist row
// onto the leg that replaced it after the route changed
// (stale-transport-orphans/tickets/02-booked-todo-migration).
//
// The production shape: Gothenburg → Sorrento was marked booked, Naples was
// inserted between them, the sync pruned the stale row and derived a fresh
// unbooked Gothenburg → Naples one — and the traveler re-ticked "booked" on
// endpoints they do not hold. The reservation (a real flight, real money)
// ended with no representation in the app. Migration is the traveler's (or
// the agent's) repair: re-key the MANUAL row in place, preserving its id —
// booking_options CASCADEs off it and trip_expenses.source_id points at it —
// so the booked flag, the saved shortlist and the money all land on the leg
// the trip actually flies.
//
// What a migration is NOT, settled at plan time:
//   - never automatic and never at sync time. The sync re-derives; only the
//     traveler moves their booked flag, with both endpoint pairs named in the
//     same breath.
//   - never a rewrite of a RESERVATION's endpoints. A derived todo's
//     endpoints were the app's claim about what to book, machine-generated;
//     the reservation with the provider is untouched — only the traveler can
//     change that.
//   - never create-new + delete-old: that destroys the shortlist (CASCADE)
//     and dangles the expense link, the exact losses
//     DemoteStaleAutoBookingTodos exists to prevent.
//
// The guard — refuse when the todo's pair is still adjacent — lives HERE, in
// Go, because adjacency is a fact about the itinerary that SQL cannot see;
// the statement's own guards (manual transport row, free target key) live in
// MigrateBookingTodoLeg. Both the REST handler and the agent's
// migrate_booking_todo tool call migrateBookingTodo, so the page and the
// chat make the same move.

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"github.com/google/uuid"
	"github.com/gorilla/mux"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// The refusal vocabulary. Sentinel errors so the REST handler can map them to
// 409s and the agent tool can name the reason back to the model; the messages
// double as the tool's refusal text.
var (
	errMigrateNotFound  = errors.New("booking todo not found")
	errMigrateNotManual = errors.New(
		"only a manual (non-auto) transport checklist row can be moved — auto rows track the itinerary on their own")
	errMigrateNotRouteRow = errors.New(
		"that row's endpoints are not two stops of this trip, so there is no route position to move it from")
	errMigrateStillAdjacent = errors.New(
		"that booking still matches the route — its two places are still consecutive stops, so there is nothing to move")
	errMigrateNoReplacement = errors.New(
		"no current leg leaves from or arrives at those places, so there is nothing to move this booking to")
	errMigrateKeyHeld = errors.New(
		"another checklist row already holds that leg with traveler state of its own — resolve which one is the real booking first")
)

// bookingTodoMigration is the post-state of a successful move: the re-keyed
// row (same id), both endpoint pairs spelled out, and whether a clean auto
// row was absorbed to free the key — everything a caller needs to name the
// change back in the same breath.
type bookingTodoMigration struct {
	Todo            store.BookingTodo
	OldOrigin       string
	OldDestination  string
	NewOrigin       string
	NewDestination  string
	AbsorbedAutoRow bool
}

// migrateBookingTodo moves the manual transport todo todoID onto the leg that
// replaced its endpoints, inside the caller's transaction. The caller must
// already hold the trip row lock (GetTripForUpdate) so a concurrent sync
// cannot re-derive the checklist mid-move, and owns the commit, TouchTrip and
// any post-write events.
func migrateBookingTodo(ctx context.Context, q *store.Queries, trip store.Trip, todoID uuid.UUID) (*bookingTodoMigration, error) {
	todo, err := q.GetBookingTodo(ctx, store.GetBookingTodoParams{ID: todoID, TripID: trip.ID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, errMigrateNotFound
		}
		return nil, err
	}
	if todo.Auto || todo.Kind != "transport" {
		return nil, errMigrateNotManual
	}
	origin, dest, ok := legEndpoints(todo)
	if !ok || strings.EqualFold(origin, dest) {
		return nil, errMigrateNotRouteRow
	}
	items, err := q.GetItineraryItemsByTrip(ctx, trip.ID)
	if err != nil {
		return nil, err
	}
	stays, err := q.ListAccommodationsByTrip(ctx, trip.ID)
	if err != nil {
		return nil, err
	}

	// The same hub sequence checkStaleBookedTodos flags against, so the write
	// can never disagree with the finding that offered it.
	var hubs []string
	for _, g := range groupExportItems(trip, items) {
		if g.Hub == "" || g.Hub == "Itinerary" {
			continue
		}
		hubs = append(hubs, g.Hub)
	}
	if len(hubs) < 2 {
		return nil, errMigrateNoReplacement
	}
	if !namesLeg(hubs, origin) || !namesLeg(hubs, dest) {
		return nil, errMigrateNotRouteRow
	}
	connected, replFrom, replTo := todoLegPlacement(hubs, origin, dest)
	if connected {
		return nil, errMigrateStillAdjacent
	}
	if replFrom == "" {
		return nil, errMigrateNoReplacement
	}

	// Everything recomputed for the new leg, with the SAME derivation the sync
	// uses — the one leg-mode ladder, the one link builder — so a migrated row
	// reads exactly like the row the next sync would have derived.
	newKey := transportTodoKey(replFrom, replTo)
	legCoords := legCoordIndex(computeTripLegs(trip, items, stays))
	derivedMode := resolveLegMode(trip,
		legEndpointFrom(replFrom, legCoords), legEndpointFrom(replTo, legCoords), nil)
	effective := derivedMode
	// The traveler's per-leg mode override is a choice somebody made; it rides
	// the row untouched and still wins the link's provider.
	if m := strings.TrimSpace(strPtrVal(todo.Mode)); allowedLegModes[m] {
		effective = m
	}
	var depart pgtype.Date
	var departPtr *string
	if dt, found := hubFirstDate(trip, items, replTo); found {
		depart = pgtype.Date{Time: dt, Valid: true}
		s := dt.Format(dateLayout)
		departPtr = &s
	}
	url, provider := transportModeLink(effective, replTo, &replFrom, departPtr, 0)

	// Free the target key — but only a provably disposable auto holder. A
	// holder carrying traveler state (booked, a mode, a shortlist, an expense
	// link) survives, and MigrateBookingTodoLeg's NOT EXISTS guard then
	// refuses the move rather than merging two traveler-claimed rows.
	deleted, err := q.DeleteCleanAutoBookingTodoByKey(ctx, store.DeleteCleanAutoBookingTodoByKeyParams{
		TripID: trip.ID, TodoKey: newKey,
	})
	if err != nil {
		return nil, err
	}
	updated, err := q.MigrateBookingTodoLeg(ctx, store.MigrateBookingTodoLegParams{
		ID:               todoID,
		TripID:           trip.ID,
		TodoKey:          newKey,
		OriginLabel:      strPtrOrNil(replFrom),
		DestinationLabel: strPtrOrNil(replTo),
		Title:            replFrom + " → " + replTo,
		DepartDate:       depart,
		SearchUrl:        strPtrOrNil(url),
		Provider:         strPtrOrNil(provider),
		DerivedMode:      strPtrOrNil(derivedMode),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			// The row was validated above, so a no-row update means the target
			// key is held by a state-carrying row.
			return nil, errMigrateKeyHeld
		}
		return nil, err
	}
	return &bookingTodoMigration{
		Todo:            updated,
		OldOrigin:       origin,
		OldDestination:  dest,
		NewOrigin:       replFrom,
		NewDestination:  replTo,
		AbsorbedAutoRow: deleted > 0,
	}, nil
}

// migrateBookingTodoHandler is the page's half of the move (the Trip Health
// migrate_booking fix button): POST …/booking-todos/{todoId}/migrate re-keys
// the manual row onto the replacement leg and answers with the updated row.
// Refusals are 409 with the sentinel's reason text — writeJSONError strings
// are deliberately not localized (i18n.go header); the finding's own copy
// already told the traveler what the move is.
func migrateBookingTodoHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	tripID := trip.ID
	todoID, err := uuid.Parse(mux.Vars(r)["todoId"])
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "booking todo not found")
		return
	}

	ctx := r.Context()
	tx, err := dbPool.Begin(ctx)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not move booking todo")
		return
	}
	defer tx.Rollback(ctx)
	q := store.New(tx)

	// The same row lock the reorder handler takes: a concurrent sync must not
	// re-derive the checklist between the guard read and the write.
	if _, err := q.GetTripForUpdate(ctx, tripID); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not move booking todo")
		return
	}
	m, err := migrateBookingTodo(ctx, q, trip, todoID)
	if err != nil {
		switch {
		case errors.Is(err, errMigrateNotFound):
			writeJSONError(w, http.StatusNotFound, "booking todo not found")
		case errors.Is(err, errMigrateNotManual),
			errors.Is(err, errMigrateNotRouteRow),
			errors.Is(err, errMigrateStillAdjacent),
			errors.Is(err, errMigrateNoReplacement),
			errors.Is(err, errMigrateKeyHeld):
			writeJSONError(w, http.StatusConflict, err.Error())
		default:
			writeJSONError(w, http.StatusInternalServerError, "could not move booking todo")
		}
		return
	}
	if err := q.TouchTrip(ctx, touchedBy(tripID, r)); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not move booking todo")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not move booking todo")
		return
	}
	user, _ := userFromContext(ctx)
	safeGo("recordEvent", func() {
		recordEvent(user.ID, "booking_todo_migrated", &tripID, map[string]any{
			"from": m.OldOrigin + " → " + m.OldDestination,
			"to":   m.NewOrigin + " → " + m.NewDestination,
		})
	})
	writeJSON(w, http.StatusOK, toBookingTodoResponse(m.Todo))
}
