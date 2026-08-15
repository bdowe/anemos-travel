package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// plan_trip_origin.go — set_trip_origin: where the traveler's saved trip
// DEPARTS from and RETURNS to.
//
// This exists because a traveler asked the chat to fly out of ALB instead of
// EWR and the agent had no tool for it: trips.origin was create-only, the
// in-app create_itinerary hardcoded an empty origin, and the derived
// "EWR → Amsterdam" row is an auto row the booking-todo tools refuse. The only
// lever left was add_booking_todo, so the model added a DUPLICATE and told the
// traveler to ignore the wrong one.
//
// Two airports, not one: this trip leaves from ALB and comes home into EWR.
// They are written together and never inferred from each other — 00064 has the
// reasoning.
//
// What makes changing them safe is migration 00064: a derived leg's identity no
// longer contains its airport, so this is a relabel, not a delete-and-recreate.

var setTripOriginTool = anthropic.ToolParam{
	Name: "set_trip_origin",
	Description: anthropic.String("Set or change where the traveler's saved trip DEPARTS from and RETURNS to. " +
		"Call it the moment they say where this trip starts, or change it — 'we're flying out of ALB instead of Newark', 'we leave from Albany but come home into Newark', 'we're driving up from Lake George'. " +
		"It rewrites the trip's existing departure and return legs IN PLACE: their booked state, per-leg travel mode and any linked expense survive, and the map's pins move with them. " +
		"NEVER add a second checklist item for a leg the trip already has, and never tell the traveler to ignore an existing one. " +
		"This changes ONE trip. It does NOT touch the traveler's saved home airport — that is save_preferences, and only when they say they have MOVED."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"airport": map[string]any{
				"type":        "string",
				"description": "The airport this trip departs from — an IATA code ('ALB') or a city to resolve ('Albany'). Omit only when the trip leaves from a place with no airport; then pass place.",
			},
			"return_airport": map[string]any{
				"type":        "string",
				"description": "The airport this trip flies home into, when it DIFFERS from the departure airport. Omit when they come back the same way — the trip then returns to `airport`.",
			},
			"place": map[string]any{
				"type":        "string",
				"description": "Where the traveler sets out from in their own words, when it is not an airport — 'Lake George, NY' for a drive. The booking legs are titled with it verbatim, and the map draws no pin (we hold no coordinates for a place name).",
			},
		},
	},
}

func runSetTripOriginTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		Airport       string `json:"airport"`
		ReturnAirport string `json:"return_airport"`
		Place         string `json:"place"`
	}
	json.Unmarshal(input, &in)

	airport, returnAirport, place := strings.TrimSpace(in.Airport), strings.TrimSpace(in.ReturnAirport), strings.TrimSpace(in.Place)
	if airport == "" && returnAirport == "" && place == "" {
		return "Pass airport (the airport this trip departs from) or place (where they set out from, for a trip with no flight). Nothing was changed.", true
	}
	if !s.authed {
		return "The traveler isn't signed in, so there's no saved trip to change. Say where the trip starts in your reply instead.", true
	}
	if dbPool == nil {
		return "Saved trips are unavailable right now (persistence offline).", true
	}

	// An airport origin on a stated ground trip is the "EWR → Montreal" bug
	// that migration 00062 was written for: nobody sets out for a drive from an
	// airport. Refuse and name the field that does fit, rather than writing a
	// leg that reads as nonsense.
	if airport != "" || returnAirport != "" {
		if mode := groundTravelModeName(s); mode != "" {
			return fmt.Sprintf("This is a %s trip, so an airport is the wrong kind of origin — a drive doesn't start at a terminal. Nothing was changed. Call set_trip_origin again with `place` set to where they actually set out from (e.g. 'Lake George, NY'), or call set_travel_mode first if the trip really does fly.", mode), true
		}
	}

	// Resolve BOTH endpoints before writing either, so a typo in the return
	// airport can't leave the trip half-changed.
	var depCode, arrCode string
	if airport != "" {
		depCode = resolveEndpointAirport(s.ctx, airport)
		if depCode == "" {
			return unresolvedAirportReply(airport), true
		}
	}
	if returnAirport != "" {
		arrCode = resolveEndpointAirport(s.ctx, returnAirport)
		if arrCode == "" {
			return unresolvedAirportReply(returnAirport), true
		}
	}
	// Stating one airport states both: a trip that leaves from ALB and says
	// nothing about coming back returns to ALB, written down rather than left
	// as a rule someone has to remember.
	if depCode == "" {
		depCode = arrCode
	}
	if arrCode == "" {
		arrCode = depCode
	}

	// A place-only call means "this trip doesn't fly": the airports are cleared
	// so a stale ALB pin can't outlive "actually we're driving".
	next := tripEndpoints{Origin: place, OriginAirport: depCode, ReturnAirport: arrCode}
	if place != "" && depCode == "" {
		next.OriginAirport, next.ReturnAirport = "", ""
	}

	// The resolver's own failure message is about the date tools, so it is
	// dropped: a trip that doesn't exist yet is not an error here.
	tid, _, failed := resolveDateShiftTrip(s)
	if failed {
		// Carry it on the session so create_itinerary persists it, exactly as
		// set_travel_mode does. Silently dropping it here is how the endpoints
		// would vanish at the next version save.
		s.endpoints = next
		return describeEndpoints(next) + " Nothing is saved yet, so it will be stored with the itinerary when you create it.", false
	}

	tx, err := dbPool.Begin(s.ctx)
	if err != nil {
		return "Could not update the trip's origin right now.", true
	}
	defer tx.Rollback(s.ctx)
	q := store.New(tx)

	// The same row lock the date tools take: serializes against a concurrent
	// booking-todo sync, so the relabel below can't land between that sync's
	// upsert and its prune.
	trip, err := q.GetTripForUpdate(s.ctx, tid)
	if err != nil {
		return "Could not load the trip to update its origin.", true
	}
	applied, err := applyTripEndpoints(s.ctx, q, trip, next, s.uid)
	var ground groundTripAirportError
	switch {
	// The ground check again, now against the SAVED mode. The session check
	// above sees only this conversation, which is empty on a later turn of a
	// fresh chat — and the whole point of refusing is that it must not depend
	// on whether the traveler happened to say "we're driving" in it.
	case errors.As(err, &ground):
		return fmt.Sprintf("This is a %s trip, so an airport is the wrong kind of origin — a drive doesn't start at a terminal. Nothing was changed. Call set_trip_origin again with `place` set to where they actually set out from (e.g. 'Lake George, NY'), or call set_travel_mode first if the trip really does fly.", ground.mode), true
	case errors.Is(err, errRelabelHomeLegs):
		return "Could not update the trip's departure and return legs.", true
	case err != nil:
		return "Could not save the trip's origin.", true
	}
	if err := tx.Commit(s.ctx); err != nil {
		return "Could not save the trip's origin.", true
	}

	next, relabelled := applied.endpoints, applied.relabelled
	s.endpoints = next
	sendSSE(s.w, "trip_updated", map[string]string{"trip_id": tid.String()})
	s.itineraryEmitted = true
	s.tripID = &tid
	ownerID := trip.UserID
	safeGo("recordEvent", func() {
		recordEvent(s.uid, "agent_trip_origin_set", &tid, map[string]any{
			"has_airport":     next.OriginAirport != "",
			"asymmetric":      next.OriginAirport != "" && next.OriginAirport != next.ReturnAirport,
			"legs_relabelled": len(relabelled),
			"is_collaborator": s.uid != ownerID,
		})
	})
	if s.uid != ownerID {
		safeGo("notifyCollabEdit", func() { notifyCollabEdit(tid, s.uid) })
	}

	return describeEndpoints(next) + " " + describeRelabelled(relabelled) + " The traveler's trip page and map have refreshed." +
		" The saved home airport is unchanged — this is a per-trip origin. Do NOT add a checklist item for either leg: those auto rows ARE the trip's flights, and they now read the new endpoints. If the checklist also has a manual item for one of these legs from an earlier turn, remove it with remove_booking_todo.", false
}

// --- the shared write ---------------------------------------------------------
//
// Everything below is called by BOTH the tool above and the trip page's
// PUT /trips/{id}/endpoints (trip_endpoints_handler.go). Changing where a trip
// departs from means one thing, so it is written in one place — the two
// surfaces differ only in how they are authorized and how they word the answer.

// errRelabelHomeLegs marks the failure that leaves the airports written but the
// legs still reading the old ones — worth its own message, because "nothing was
// saved" would be a lie.
var errRelabelHomeLegs = errors.New("could not relabel the trip's home legs")

// groundTripAirportError is the refusal for an airport on a stated ground trip:
// the "EWR → Montreal" incident migration 00062 was written for. Nobody sets
// out for a drive from a terminal. Typed rather than a message so the chat can
// point the model at `place` while the trip page points the traveler at the
// trip's travel mode.
type groundTripAirportError struct{ mode string }

func (e groundTripAirportError) Error() string {
	return "an airport is not a valid origin for a " + e.mode + " trip"
}

// appliedTripEndpoints is the post-state a caller will now observe: what the
// trip stores, and which derived rows moved because of it.
type appliedTripEndpoints struct {
	endpoints  tripEndpoints
	relabelled []relabelledLeg
}

// applyTripEndpoints writes a trip's origin and endpoint airports and repoints
// its derived departure/return legs to match, inside the caller's transaction.
//
// [trip] must already be locked (GetTripForUpdate): the relabel must not land
// between a concurrent booking-todo sync's upsert and its prune. The caller
// commits — nothing here is visible until it does, which is what makes the
// ground refusal and a failed relabel leave the trip exactly as it was.
func applyTripEndpoints(ctx context.Context, q *store.Queries, trip store.Trip, next tripEndpoints, actor uuid.UUID) (appliedTripEndpoints, error) {
	if next.OriginAirport != "" {
		if mode := strings.TrimSpace(strPtrVal(trip.TravelMode)); mode == "car" || mode == "train" || mode == "bus" {
			return appliedTripEndpoints{}, groundTripAirportError{mode: mode}
		}
	}
	// Origin is preserved when the caller says nothing about it — the trip page
	// never sends one, and a chat call that gives only airports must not read
	// as "and they no longer set out from anywhere".
	if next.Origin == "" {
		next.Origin = strPtrVal(trip.Origin)
	}
	originPtr, depPtr, arrPtr := next.columns()
	if _, err := q.SetTripEndpoints(ctx, store.SetTripEndpointsParams{
		ID: trip.ID, Origin: originPtr, OriginAirport: depPtr, ReturnAirport: arrPtr,
	}); err != nil {
		return appliedTripEndpoints{}, err
	}

	// Refresh the derived endpoint rows now rather than waiting for the next
	// client sync: both callers report what the traveler's checklist says, so
	// it has to be true by the time they say it.
	updated := trip
	updated.Origin, updated.OriginAirport, updated.ReturnAirport = originPtr, depPtr, arrPtr
	var ownerHome *string
	if originPtr == nil && depPtr == nil {
		if prefs, err := q.GetPreferences(ctx, trip.UserID); err == nil {
			ownerHome = prefs.HomeAirport
		}
	}
	departureLabel, arrivalLabel := tripEndpointLabels(updated, ownerHome)
	relabelled, err := relabelHomeLegs(ctx, q, trip.ID, departureLabel, arrivalLabel)
	if err != nil {
		return appliedTripEndpoints{}, fmt.Errorf("%w: %v", errRelabelHomeLegs, err)
	}

	if err := q.TouchTrip(ctx, store.TouchTripParams{
		ID: trip.ID, UpdatedBy: pgtype.UUID{Bytes: actor, Valid: true},
	}); err != nil {
		return appliedTripEndpoints{}, err
	}
	// next carries the resolved columns back, so a caller never has to re-derive
	// what it just stored.
	next.OriginAirport, next.ReturnAirport = strPtrVal(depPtr), strPtrVal(arrPtr)
	next.Origin = strPtrVal(originPtr)
	return appliedTripEndpoints{endpoints: next, relabelled: relabelled}, nil
}

// unresolvedAirportReply is the chat's wording for an airport that resolves to
// nothing — whether we could not guess a code at all or guessed one that turns
// out not to exist. Both leave the model with the same next move.
func unresolvedAirportReply(input string) string {
	return fmt.Sprintf("Could not confirm an airport for %q, so nothing was changed. Ask the traveler which airport they mean (a city name or an IATA code both work).", input)
}

// tripEndpointSummary is the get_trip line describing where a trip starts and
// ends — including, deliberately, the case where it says nothing, so the model
// can tell "explicitly EWR" apart from "defaulting to the saved home airport"
// instead of guessing.
func tripEndpointSummary(trip store.Trip) string {
	dep, arr := strings.TrimSpace(strPtrVal(trip.OriginAirport)), strings.TrimSpace(strPtrVal(trip.ReturnAirport))
	stated := strings.TrimSpace(strPtrVal(trip.Origin))
	switch {
	case dep != "" && arr != "" && dep != arr:
		return fmt.Sprintf("Departs from %s and returns to %s (set for this trip; change with set_trip_origin).", dep, arr)
	case dep != "":
		return fmt.Sprintf("Departs from and returns to %s (set for this trip; change with set_trip_origin).", dep)
	case stated != "":
		return fmt.Sprintf("Sets out from %q — stated in words, no airport, so no map pin (change with set_trip_origin).", stated)
	default:
		return "Departure origin: not stated for this trip, so the departure and return legs fall back to the traveler's saved home airport — call set_trip_origin to give this trip its own."
	}
}

// resolveEndpointAirport turns what the traveler said into a real IATA code, or
// returns "" when nothing matches. Unlike the flight-search path, an
// unrecognized 3-letter string is NOT taken on faith: resolveIATA passes any
// three letters straight through, and storing a code that resolves to nothing
// would title a leg with it and then silently never pin it on the map.
//
// Shared by the chat tool and the trip page's PUT, which word the refusal
// differently — one talks to the model, the other to the traveler — so this
// returns the verdict and lets each caller say it.
func resolveEndpointAirport(ctx context.Context, input string) string {
	code := resolveIATA(ctx, input)
	if code == "" {
		return ""
	}
	if duffelService == nil {
		return code
	}
	results, err := duffelService.SearchAirports(ctx, code)
	if err != nil {
		// The lookup is a confirmation, not the resolver. A provider outage
		// must not block a traveler from saying where they leave from.
		return code
	}
	for _, a := range results {
		if strings.EqualFold(a.IataCode, code) {
			return strings.ToUpper(code)
		}
	}
	return ""
}

// groundTravelModeName returns the trip's stated ground mode ("car"/"train"/
// "bus"), or "" when the trip flies or hasn't said. The session's own
// set_travel_mode value wins, because it may have been stated this very turn.
func groundTravelModeName(s *planSession) string {
	mode := strings.TrimSpace(s.travelMode)
	if mode == "" && s.boundTripID != nil && dbPool != nil {
		if trip, err := store.New(dbPool).GetEditableTripByID(s.ctx,
			store.GetEditableTripByIDParams{ID: *s.boundTripID, UserID: s.uid}); err == nil {
			mode = strings.TrimSpace(strPtrVal(trip.TravelMode))
		}
	}
	switch mode {
	case "car", "train", "bus":
		return mode
	}
	return ""
}

// relabelledLeg is one endpoint row after the change, for the tool result.
type relabelledLeg struct {
	before, after string
	booked        bool
}

// relabelHomeLegs repoints the trip's derived departure/return rows at the new
// endpoints, in place. Nothing is deleted and no key moves — the @home identity
// is exactly what makes that possible.
func relabelHomeLegs(ctx context.Context, q *store.Queries, tid uuid.UUID, departure, arrival string) ([]relabelledLeg, error) {
	rows, err := q.ListHomeBookingTodos(ctx, tid)
	if err != nil {
		return nil, err
	}
	out := make([]relabelledLeg, 0, len(rows))
	for _, row := range rows {
		origin, dest := strPtrVal(row.OriginLabel), strPtrVal(row.DestinationLabel)
		switch strPtrVal(row.Role) {
		case roleHomeOutbound:
			if departure == "" {
				continue
			}
			origin = departure
		case roleHomeReturn:
			if arrival == "" {
				continue
			}
			dest = arrival
		default:
			continue
		}
		if origin == "" || dest == "" {
			continue
		}
		title := origin + " → " + dest
		if title == row.Title {
			continue
		}
		departDate := dateToPtr(row.DepartDate)
		url, provider := "", strPtrVal(row.Provider)
		if mode := strings.TrimSpace(strPtrVal(row.Mode)); mode != "" && allowedLegModes[mode] {
			url, provider = transportModeLink(mode, dest, &origin, departDate, 1)
		} else {
			url, provider = bookingSearchURL("transport", dest, &origin, departDate, nil, 0, 1, row.Provider)
		}
		if _, err := q.RelabelHomeBookingTodo(ctx, store.RelabelHomeBookingTodoParams{
			ID: row.ID, TripID: row.TripID,
			OriginLabel: strPtrOrNil(origin), DestinationLabel: strPtrOrNil(dest),
			Title: title, SearchUrl: strPtrOrNil(url), Provider: strPtrOrNil(provider),
		}); err != nil {
			return nil, err
		}
		out = append(out, relabelledLeg{before: row.Title, after: title, booked: row.Booked})
	}
	return out, nil
}

// describeEndpoints states the post-state the traveler will see, naming BOTH
// directions — a result that says only "origin updated" is what let a wrong
// mental model survive a string of successful calls (docs/zen.md).
func describeEndpoints(e tripEndpoints) string {
	switch {
	case e.OriginAirport != "" && e.OriginAirport != e.ReturnAirport:
		return fmt.Sprintf("Trip origin updated. Departure: %s. Return: %s — this trip comes home into a different airport than it leaves from.", e.OriginAirport, e.ReturnAirport)
	case e.OriginAirport != "":
		return fmt.Sprintf("Trip origin updated. This trip departs from and returns to %s.", e.OriginAirport)
	case strings.TrimSpace(e.Origin) != "":
		return fmt.Sprintf("Trip origin set to %q. No airport, so the map draws no departure pin and flight searches keep using the traveler's saved home airport — say that plainly if they ask about the map.", strings.TrimSpace(e.Origin))
	default:
		return "Trip origin cleared. The departure and return legs fall back to the traveler's saved home airport."
	}
}

// describeRelabelled reports what actually moved on the checklist, including
// the honest nothing-moved case: a trip with no itinerary yet has no legs to
// rename, and claiming otherwise would teach the model it had done something.
func describeRelabelled(legs []relabelledLeg) string {
	if len(legs) == 0 {
		return "No derived departure or return leg was on the checklist yet, so nothing was renamed — the legs will appear with the new endpoints once the itinerary has cities."
	}
	parts := make([]string, 0, len(legs))
	for _, l := range legs {
		state := "not booked"
		if l.booked {
			state = "still marked booked"
		}
		parts = append(parts, fmt.Sprintf("%q is now %q (%s)", l.before, l.after, state))
	}
	return "Rewritten in place, keeping booked state, per-leg mode and any linked expense: " + strings.Join(parts, "; ") + "."
}
