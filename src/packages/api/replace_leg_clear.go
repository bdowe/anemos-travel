package main

// replace_leg_clear.go — what stops belonging to the trip when a city leaves
// it, and how the traveler is told.
//
// A Copenhagen hotel is meaningless in Belgrade, but tidiness is not the
// load-bearing reason. computeTripLegs takes a leg's span from `confirmed stay
// > item days > auto allocation`, so a stay left attached is a HIGHER
// precedence date source than the places the swap just wrote. On a same-city
// refill that is exactly right and the stay must be left alone. On a real swap
// it is a hazard, and on the one shape where the hub name still matches the old
// city's hotel — the model re-typing a near-identical name, "Stay in
// Copenhagen" against a hub of "Copenhagen K" — the retained stay would keep
// dictating the new city's dates. Clearing is the option that cannot go wrong
// that way.
//
// THE FAILURE MODE THIS IS DESIGNED AGAINST IS THE OTHER ONE. Over-clearing
// destroys a real reservation and is unrecoverable from a chat message; an
// under-clear is a visible oddity the traveler can fix in two taps. So every
// rule here matches on STRUCTURE, never on prose:
//
//   - stays and transport are matched with the predicates that already decide
//     which leg they belong to (stayMatchesHub, the origin/destination
//     fuzzyMatch set_leg_dates uses for boundary transport) — no third matcher;
//   - checklist rows are matched on the derived todo_key GRAMMAR
//     (`stay:<hub>`, `transport:<a>>><b>`), never on their title, so
//     "Book the Copenhagen harbour tour" added by hand is left alone;
//   - drafts (auto=true stays and segments) are left to the client's own
//     prune, which already keys them by auto_key and can't be raced from here;
//   - a checklist row carrying traveler state — booked, a per-leg mode, a saved
//     shortlist, a linked expense — is DEMOTED rather than deleted, by calling
//     the same DemoteStaleAutoBookingTodos the sync's prune calls. That policy
//     was decided in 00064/00065 and is not this tool's to re-litigate.
//
// Nothing here reports a count. "3 bookings removed" is unactionable; the model
// has to be able to tell the traveler which hotel it just dropped and offer to
// rebook it, and PRODUCT.md's "degrade, never invent" makes a silently-dropped
// reservation a defect rather than an implementation detail.

import (
	"context"
	"fmt"
	"strings"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// clearedRow is one removed attachment, named the way the traveler would
// recognize it. Booked rides along because it changes what the model must say:
// a real reservation the app just detached still exists with the provider.
type clearedRow struct {
	Label  string
	Booked bool
}

// clearedLeg is the account of what left the trip with the replaced city.
type clearedLeg struct {
	Stays    []clearedRow
	Segments []clearedRow
	// TodosDeleted / TodosDemoted are checklist rows the itinerary derivation
	// owned. Demoted ones still exist, under "Other bookings" — the traveler
	// keeps their booked flag and any shortlist hanging off them.
	TodosDeleted []string
	TodosDemoted []string
}

// empty reports whether the swap detached nothing at all.
func (c clearedLeg) empty() bool {
	return len(c.Stays) == 0 && len(c.Segments) == 0 &&
		len(c.TodosDeleted) == 0 && len(c.TodosDemoted) == 0
}

// booked lists the removed rows that were marked booked — the ones the model
// must not describe as merely "removed from the plan".
func (c clearedLeg) booked() []string {
	var out []string
	for _, rows := range [][]clearedRow{c.Stays, c.Segments} {
		for _, r := range rows {
			if r.Booked {
				out = append(out, r.Label)
			}
		}
	}
	return out
}

// segmentTouchesHub reports whether a transport segment runs into or out of a
// hub. Same predicate set_leg_dates uses to decide which segments ride a leg's
// boundary move, so the tool that DELETES a leg and the tool that MOVES one
// agree about which transport is the leg's.
//
// Undirected on purpose: an inter-city segment is arrival for one leg and
// departure for the other, and both readings are the same fact about the city
// that is leaving the trip.
func segmentTouchesHub(seg store.TripSegment, hubLower string) bool {
	o := strings.ToLower(strings.TrimSpace(strPtrVal(seg.Origin)))
	d := strings.ToLower(strings.TrimSpace(strPtrVal(seg.Destination)))
	return fuzzyMatch(o, hubLower) || fuzzyMatch(d, hubLower)
}

// segmentLabel names a segment the way the trip page's row reads.
func segmentLabel(seg store.TripSegment) string {
	o := strings.TrimSpace(strPtrVal(seg.Origin))
	d := strings.TrimSpace(strPtrVal(seg.Destination))
	switch {
	case o != "" && d != "":
		return fmt.Sprintf("%s → %s (%s)", o, d, seg.Mode)
	case d != "":
		return fmt.Sprintf("to %s (%s)", d, seg.Mode)
	case o != "":
		return fmt.Sprintf("from %s (%s)", o, seg.Mode)
	}
	return seg.Mode + " leg"
}

// todoKeyNamesHub reports whether a derived checklist key is one of THIS hub's
// rows: `stay:<hub>`, or a transport leg with the hub at either end.
//
// Grammar, not text. transportTodoKey lowercases and trims both tokens, so the
// comparison goes through sameHub for the same case/diacritic tolerance the run
// split uses. A key that doesn't speak the derived grammar belongs to nobody's
// leg — an agent-added or hand-written row — and is never claimed here.
// homeEndpointToken can't collide: `@` occurs in no city label.
func todoKeyNamesHub(key, hub string) bool {
	if rest, ok := strings.CutPrefix(key, "stay:"); ok {
		return sameHub(rest, hub)
	}
	rest, ok := strings.CutPrefix(key, "transport:")
	if !ok {
		return false
	}
	a, b, found := strings.Cut(rest, ">>")
	if !found {
		return false
	}
	return sameHub(a, hub) || sameHub(b, hub)
}

// clearLegAttachments removes what belonged to `hub` and returns the account of
// it. Runs inside the caller's transaction, under the trip row lock the swap
// already holds, so the checklist key set it computes cannot be raced.
//
// Confirmed rows only. An auto stay or segment is a client-side draft whose
// prune is keyed on auto_key by DeleteStaleDraftAccommodations /
// DeleteStaleDraftSegments; deleting one here would race that sync for no gain
// — a draft is re-derived from the itinerary the swap just rewrote, and
// firstConfirmedStayForHub skips drafts entirely, so no draft can date a leg.
func clearLegAttachments(ctx context.Context, q *store.Queries, tripID uuid.UUID, hub string) (clearedLeg, error) {
	var out clearedLeg
	hubLower := strings.ToLower(strings.TrimSpace(hub))
	if hubLower == "" {
		return out, nil
	}

	stays, err := q.ListAccommodationsByTrip(ctx, tripID)
	if err != nil {
		return out, err
	}
	for _, a := range stays {
		if a.Auto || !stayMatchesHub(a, hubLower) {
			continue
		}
		if _, err := q.DeleteAccommodation(ctx, store.DeleteAccommodationParams{ID: a.ID, TripID: tripID}); err != nil {
			return out, err
		}
		out.Stays = append(out.Stays, clearedRow{Label: a.Name, Booked: a.Booked})
	}

	segs, err := q.ListSegmentsByTrip(ctx, tripID)
	if err != nil {
		return out, err
	}
	for _, s := range segs {
		if s.Auto || !segmentTouchesHub(s, hubLower) {
			continue
		}
		if _, err := q.DeleteSegment(ctx, store.DeleteSegmentParams{ID: s.ID, TripID: tripID}); err != nil {
			return out, err
		}
		out.Segments = append(out.Segments, clearedRow{Label: segmentLabel(s), Booked: s.Booked})
	}

	todos, err := q.ListBookingTodosByTrip(ctx, tripID)
	if err != nil {
		return out, err
	}
	// Build the KEEP set the two prune statements take, rather than a victim
	// list they have no parameter for. keep is every key the swap is not
	// dropping, so a bug that mis-classifies one row can only under-clear.
	keep := make([]string, 0, len(todos))
	victims := map[string]store.BookingTodo{}
	for _, t := range todos {
		if t.Auto && todoKeyNamesHub(t.TodoKey, hub) {
			victims[t.TodoKey] = t
			continue
		}
		keep = append(keep, t.TodoKey)
	}
	// No victims means no statement: `todo_key <> ALL('{}')` is TRUE for every
	// row, so calling the prune with an unfiltered keep set would be a
	// whole-checklist wipe. Guarding the dangerous direction explicitly beats
	// relying on the loop above never producing an empty list.
	if len(victims) == 0 {
		return out, nil
	}
	// Demote BEFORE delete, and via the same statements the checklist sync
	// uses: a stale row carrying a booked flag, a per-leg mode, a saved
	// shortlist or a linked expense is traveler state, not garbage. Dropping a
	// city must not throw away the three Airbnbs somebody compared for it
	// (00065). Demoted rows survive as manual rows under "Other bookings".
	if _, err := q.DemoteStaleAutoBookingTodos(ctx, store.DemoteStaleAutoBookingTodosParams{TripID: tripID, Keys: keep}); err != nil {
		return out, err
	}
	if _, err := q.DeleteStaleAutoBookingTodos(ctx, store.DeleteStaleAutoBookingTodosParams{TripID: tripID, Keys: keep}); err != nil {
		return out, err
	}
	// Re-read rather than predict: the demote/delete split is decided by SQL
	// this file does not own, and a result that states which rows survived has
	// to have looked. (docs/zen.md — a mutating tool's result states the
	// post-state its consumer will observe.)
	after, err := q.ListBookingTodosByTrip(ctx, tripID)
	if err != nil {
		return out, err
	}
	survived := make(map[string]bool, len(after))
	for _, t := range after {
		survived[t.TodoKey] = true
	}
	// Walk the PRE-clear list, not the victim map: ListBookingTodosByTrip is
	// ordered by position, and a result that names rows in a different order
	// each call is one the traveler cannot check against their own checklist.
	for _, t := range todos {
		v, ok := victims[t.TodoKey]
		if !ok {
			continue
		}
		if survived[v.TodoKey] {
			out.TodosDemoted = append(out.TodosDemoted, v.Title)
			continue
		}
		out.TodosDeleted = append(out.TodosDeleted, v.Title)
	}
	return out, nil
}

// clearedLegText is the sentence a swap's result carries about what it
// detached. Empty when nothing was attached — silence is the honest answer
// there, and a "nothing was removed" line on every swap is noise the model
// would eventually relay.
func clearedLegText(hub string, c clearedLeg) string {
	if c.empty() {
		return ""
	}
	var parts []string
	if names := rowLabels(c.Stays); len(names) > 0 {
		parts = append(parts, "the stay "+quoteList(names))
	}
	if names := rowLabels(c.Segments); len(names) > 0 {
		parts = append(parts, "the transport "+quoteList(names))
	}
	if len(c.TodosDeleted) > 0 {
		parts = append(parts, "the checklist row(s) "+quoteList(c.TodosDeleted))
	}
	var b strings.Builder
	if len(parts) > 0 {
		fmt.Fprintf(&b, " Removed with %s: %s.", hub, strings.Join(parts, ", "))
	}
	if len(c.TodosDemoted) > 0 {
		fmt.Fprintf(&b, " Kept, but no longer tracking the itinerary (they carry the traveler's own state — a booked flag, a chosen mode, saved options or a budget line): %s. They now sit under \"Other bookings\" and can be removed with remove_booking_todo.", quoteList(c.TodosDemoted))
	}
	if booked := c.booked(); len(booked) > 0 {
		fmt.Fprintf(&b, " IMPORTANT — %s was marked BOOKED, so a real reservation may still exist with the provider. Tell the traveler plainly which booking this was and that they need to cancel or change it themselves; the app only dropped its own record.", quoteList(booked))
	}
	if len(c.Stays) > 0 || len(c.Segments) > 0 {
		b.WriteString(" Say what was removed and offer to find replacements for the new city.")
	}
	return b.String()
}

func rowLabels(rows []clearedRow) []string {
	out := make([]string, 0, len(rows))
	for _, r := range rows {
		if l := strings.TrimSpace(r.Label); l != "" {
			out = append(out, l)
		}
	}
	return out
}

// quoteList renders names as a quoted, comma-joined list. Capped like
// describeStrays: a trip with twenty attached rows must not blow up a
// tool_result.
func quoteList(names []string) string {
	const maxNames = 6
	shown := names
	if len(shown) > maxNames {
		shown = shown[:maxNames]
	}
	quoted := make([]string, len(shown))
	for i, n := range shown {
		quoted[i] = fmt.Sprintf("%q", n)
	}
	s := strings.Join(quoted, ", ")
	if rest := len(names) - len(shown); rest > 0 {
		s += fmt.Sprintf(" and %d more", rest)
	}
	return s
}
