package main

import (
	"context"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// trip_summary.go — a trip's description: the prose overview shown under its
// title (trips.summary, 00013). specs/trip-description.
//
// It used to be write-once. CreateTrip was its only writer, UpdateTrip left it
// out of the COALESCE set, and once a trip was bound to a refine session
// create_itinerary was gated off — so the sentence describing a three-city trip
// survived it growing to five, in prose the traveler could not correct and the
// planner could not even read.
//
// Everything below is called by BOTH the trip page's PATCH /trips/{id}
// (trip_handler.go) and the chat's set_trip_description
// (plan_trip_description.go). A description means one thing, so it is written in
// one place — the two surfaces differ only in how they are authorized and how
// they word the answer.

// Who a description's words belong to (trips.summary_source, 00071). The planner
// may refresh prose it wrote; it may never overwrite the traveler's.
const (
	summarySourceAgent    = "agent"
	summarySourceTraveler = "traveler"
)

// appliedTripSummary is the post-state a caller will now observe rather than an
// echo of what it asked for: the stored text (empty when there is none) and
// whose words the trip now records them as.
type appliedTripSummary struct {
	summary string
	source  string
	// cleared distinguishes "saved a description" from "removed the one that
	// was there" — the same write, but not the same thing to report.
	cleared bool
}

// applyTripSummary writes a trip's description inside the caller's transaction.
//
// [trip] must already be locked (GetTripForUpdate), like applyTripEndpoints: the
// traveler-authored check below reads the row, and a concurrent write between
// that read and this one would decide against a stale author. The caller commits.
//
// An empty [next] CLEARS the description. Clearing still stamps a source, and
// that pairing is the whole point: summary NULL with source 'traveler' is the
// traveler having removed the blurb on purpose, a state the planner must respect
// and one a single column could not express (see 00071).
func applyTripSummary(ctx context.Context, q *store.Queries, trip store.Trip, next, source string, actor uuid.UUID) (appliedTripSummary, error) {
	text := strings.TrimSpace(next)
	if utf8.RuneCountInString(text) > maxSummaryLen {
		return appliedTripSummary{}, errSummaryTooLong
	}
	if source != summarySourceAgent && source != summarySourceTraveler {
		// Not reachable from either surface — both pass a constant. It is an
		// error rather than a default because the CHECK would reject it anyway,
		// and a caller that guessed wrong should hear so here.
		return appliedTripSummary{}, fmt.Errorf("summary_source must be %q or %q, got %q", summarySourceAgent, summarySourceTraveler, source)
	}

	// "" is stored as NULL so "no description" keeps exactly one representation,
	// matching what persistTrip has always done on the create path.
	var textPtr *string
	if text != "" {
		textPtr = &text
	}
	sourceCopy := source
	if err := q.SetTripSummary(ctx, store.SetTripSummaryParams{
		ID: trip.ID, Summary: textPtr, SummarySource: &sourceCopy,
	}); err != nil {
		return appliedTripSummary{}, err
	}
	if err := q.TouchTrip(ctx, store.TouchTripParams{
		ID: trip.ID, UpdatedBy: pgtype.UUID{Bytes: actor, Valid: true},
	}); err != nil {
		return appliedTripSummary{}, err
	}
	return appliedTripSummary{
		summary: text,
		source:  source,
		cleared: text == "" && strings.TrimSpace(strPtrVal(trip.Summary)) != "",
	}, nil
}

// travelerWroteSummary reports whether the trip's description is the traveler's
// own — including the case where they REMOVED it, which is equally their
// decision. NULL source is provably not theirs: until 00071 no human writer
// existed, so the planner may refresh it.
func travelerWroteSummary(trip store.Trip) bool {
	return strPtrVal(trip.SummarySource) == summarySourceTraveler
}

// tripDescriptionSummary is the get_trip line describing a trip's description —
// including, deliberately, both ways it can be absent, so the planner can tell
// "nobody has written one" from "the traveler deleted theirs" instead of
// guessing. A field the model cannot read is a field it improvises about, which
// is what set_trip_origin was built to stop.
func tripDescriptionSummary(trip store.Trip) string {
	text := strings.TrimSpace(strPtrVal(trip.Summary))
	traveler := travelerWroteSummary(trip)
	switch {
	case text != "" && traveler:
		return fmt.Sprintf("Description (the traveler wrote this themselves — do NOT rewrite it on your own initiative, only if they ask): %q", text)
	case text != "":
		return fmt.Sprintf("Description (written by the assistant; refresh it with set_trip_description if the trip no longer matches it): %q", text)
	case traveler:
		return "Description: none — the traveler REMOVED it on purpose. Leave it that way unless they ask for one."
	default:
		return "Description: none yet. Add one with set_trip_description if the traveler would want a short overview."
	}
}

// errSummaryTooLong is shared so the two surfaces can word one verdict two ways
// — to the model and to the person — like unresolvedAirportReply and
// unresolvedAirportMessage.
var errSummaryTooLong = fmt.Errorf("description too long (max %d characters)", maxSummaryLen)

// summaryTooLongReply is the chat's wording; summaryTooLongMessage below is the
// trip page's.
func summaryTooLongReply(n int) string {
	return fmt.Sprintf("That description is %d characters and the limit is %d, so nothing was changed. Write a shorter one — a sentence or two is what the trip page shows.", n, maxSummaryLen)
}

func summaryTooLongMessage() string {
	return fmt.Sprintf("description too long (max %d characters)", maxSummaryLen)
}

// travelerAuthoredReply is the refusal the planner gets when it tries to refresh
// a description on its own initiative and finds the traveler's own words there.
// It quotes what is stored so the model can offer the change instead of making
// it — a refusal that doesn't say what it found leaves the model guessing again.
func travelerAuthoredReply(trip store.Trip) string {
	if text := strings.TrimSpace(strPtrVal(trip.Summary)); text != "" {
		return fmt.Sprintf("Nothing was changed: the traveler wrote this trip's description themselves — %q. Don't replace their words on your own initiative. If you think it no longer fits the trip, say so and offer to rewrite it; call this again with reason \"traveler_asked\" only once they agree.", text)
	}
	return "Nothing was changed: the traveler removed this trip's description on purpose, so it is meant to be empty. Don't add one back on your own initiative — offer, and call this again with reason \"traveler_asked\" only if they say yes."
}
