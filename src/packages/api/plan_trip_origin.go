package main

import (
	"encoding/json"
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
		code, msg := resolveEndpointAirport(s, airport)
		if code == "" {
			return msg, true
		}
		depCode = code
	}
	if returnAirport != "" {
		code, msg := resolveEndpointAirport(s, returnAirport)
		if code == "" {
			return msg, true
		}
		arrCode = code
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
	// The ground check again, now against the SAVED mode. The one above sees
	// only the session, which is empty on a later turn of a fresh chat — and
	// the whole point of refusing is that it must not depend on whether the
	// traveler happened to say "we're driving" in this conversation.
	if depCode != "" {
		if mode := strings.TrimSpace(strPtrVal(trip.TravelMode)); mode == "car" || mode == "train" || mode == "bus" {
			return fmt.Sprintf("This is a %s trip, so an airport is the wrong kind of origin — a drive doesn't start at a terminal. Nothing was changed. Call set_trip_origin again with `place` set to where they actually set out from (e.g. 'Lake George, NY'), or call set_travel_mode first if the trip really does fly.", mode), true
		}
	}
	// A place-only call keeps whatever the trip already said about airports
	// only if it said nothing new — otherwise the free text alone would look
	// like a clear. Origin is likewise preserved when only airports are given.
	if place == "" {
		next.Origin = strPtrVal(trip.Origin)
	}
	originPtr, depPtr, arrPtr := next.columns()
	if _, err := q.SetTripEndpoints(s.ctx, store.SetTripEndpointsParams{
		ID: tid, Origin: originPtr, OriginAirport: depPtr, ReturnAirport: arrPtr,
	}); err != nil {
		return "Could not save the trip's origin.", true
	}

	// Refresh the derived endpoint rows now rather than waiting for the next
	// client sync: this tool's result tells the traveler what their checklist
	// says, so it has to be true by the time it says it.
	updated := trip
	updated.Origin, updated.OriginAirport, updated.ReturnAirport = originPtr, depPtr, arrPtr
	var ownerHome *string
	if originPtr == nil && depPtr == nil {
		if prefs, err := q.GetPreferences(s.ctx, trip.UserID); err == nil {
			ownerHome = prefs.HomeAirport
		}
	}
	departureLabel, arrivalLabel := tripEndpointLabels(updated, ownerHome)
	relabelled, err := relabelHomeLegs(s, q, tid, departureLabel, arrivalLabel)
	if err != nil {
		return "Could not update the trip's departure and return legs.", true
	}

	if err := q.TouchTrip(s.ctx, store.TouchTripParams{
		ID: tid, UpdatedBy: pgtype.UUID{Bytes: s.uid, Valid: true},
	}); err != nil {
		return "Could not save the trip's origin.", true
	}
	if err := tx.Commit(s.ctx); err != nil {
		return "Could not save the trip's origin.", true
	}

	s.endpoints = next
	sendSSE(s.w, "trip_updated", map[string]string{"trip_id": tid.String()})
	s.itineraryEmitted = true
	s.tripID = &tid
	ownerID := trip.UserID
	safeGo("recordEvent", func() {
		recordEvent(s.uid, "agent_trip_origin_set", &tid, map[string]any{
			"has_airport":     depPtr != nil,
			"asymmetric":      depPtr != nil && arrPtr != nil && *depPtr != *arrPtr,
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
// returns ("", message). Unlike the flight-search path, an unrecognized
// 3-letter string is NOT taken on faith: resolveIATA passes any three letters
// straight through, and storing a code that resolves to nothing would title a
// leg with it and then silently never pin it on the map.
func resolveEndpointAirport(s *planSession, input string) (string, string) {
	code := resolveIATA(s.ctx, input)
	if code == "" {
		return "", fmt.Sprintf("Could not find an airport for %q, so nothing was changed. Ask the traveler which airport they mean (a city name or an IATA code both work).", input)
	}
	if duffelService == nil {
		return code, ""
	}
	results, err := duffelService.SearchAirports(s.ctx, code)
	if err != nil {
		// The lookup is a confirmation, not the resolver. A provider outage
		// must not block a traveler from saying where they leave from.
		return code, ""
	}
	for _, a := range results {
		if strings.EqualFold(a.IataCode, code) {
			return strings.ToUpper(code), ""
		}
	}
	return "", fmt.Sprintf("%q doesn't match a real airport, so nothing was changed. Ask the traveler which airport they mean.", input)
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
func relabelHomeLegs(s *planSession, q *store.Queries, tid uuid.UUID, departure, arrival string) ([]relabelledLeg, error) {
	rows, err := q.ListHomeBookingTodos(s.ctx, tid)
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
		if _, err := q.RelabelHomeBookingTodo(s.ctx, store.RelabelHomeBookingTodoParams{
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
