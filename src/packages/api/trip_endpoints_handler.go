package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"travel-route-planner/store"
)

// trip_endpoints_handler.go — PUT /trips/{id}/endpoints: the trip page's way to
// say which airport THIS trip leaves from and comes home into.
//
// specs/trip-endpoint-airports shipped the columns, the safe-to-relabel leg
// identity (migration 00064) and the chat tool, and deliberately left the page
// control for later — so the only affordance on a derived "EWR → Amsterdam" row
// was "Add details…", which posts a *segment*. A traveler correcting the
// airport there got a second row contradicting the first. This is that
// deferred control.
//
// It is NOT a PATCH /trips/{id} field: the spec rules that out and
// TestPatchTripCannotSetOrigin pins it. The write itself is
// applyTripEndpoints (plan_trip_origin.go) — the same one set_trip_origin
// calls, so the page and the chat cannot drift about what changing an airport
// means.

// maxAirportInputLen bounds what we will hand the airport resolver. A code is 3
// characters and the longest city name a traveler might type is nowhere near
// this; the cap exists so a junk payload can't ride into a provider call.
const maxAirportInputLen = 100

type TripEndpointsRequest struct {
	// Both are stated together or not at all, mirroring
	// CHECK trips_endpoint_airport_pair. A missing key reads the same as null:
	// "this trip states no airport for that direction". Accepts an IATA code or
	// a city name — the resolver takes either.
	OriginAirport *string `json:"origin_airport"`
	ReturnAirport *string `json:"return_airport"`
}

// RelabelledLegResponse is one derived row that moved because the endpoints
// did, including whether it is still booked — the traveler's question after
// "did it rename?" is "did I lose the tick?".
type RelabelledLegResponse struct {
	Before string `json:"before"`
	After  string `json:"after"`
	Booked bool   `json:"booked"`
}

// TripEndpointsResponse states the post-state the caller will now observe
// rather than echoing the request: which airports the trip stores, the free-text
// origin that still stands behind them, and exactly which rows changed. An
// empty legs_renamed is the honest "there was no derived leg yet" case.
type TripEndpointsResponse struct {
	Origin        *string                 `json:"origin"`
	OriginAirport *string                 `json:"origin_airport"`
	ReturnAirport *string                 `json:"return_airport"`
	LegsRenamed   []RelabelledLegResponse `json:"legs_renamed"`
}

func putTripEndpointsHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	var req TripEndpointsRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	depIn, arrIn := trimAirportInput(req.OriginAirport), trimAirportInput(req.ReturnAirport)
	// The paired rule, on the wire. Enforcing it here rather than letting
	// columns() quietly copy one onto the other is what stops a client shipping
	// "change the outbound" and silently rewriting the return leg too.
	if (depIn == "") != (arrIn == "") {
		writeJSONError(w, http.StatusBadRequest,
			"origin_airport and return_airport are set together or cleared together — send both, or send both as null")
		return
	}
	if len(depIn) > maxAirportInputLen || len(arrIn) > maxAirportInputLen {
		writeJSONError(w, http.StatusBadRequest, "airport must be an IATA code or a city name")
		return
	}

	// Both resolve before either is written, so a typo in the return airport
	// can't leave the trip half-changed.
	var depCode, arrCode string
	if depIn != "" {
		if depCode = resolveEndpointAirport(r.Context(), depIn); depCode == "" {
			writeJSONError(w, http.StatusUnprocessableEntity, unresolvedAirportMessage(depIn))
			return
		}
		if arrCode = resolveEndpointAirport(r.Context(), arrIn); arrCode == "" {
			writeJSONError(w, http.StatusUnprocessableEntity, unresolvedAirportMessage(arrIn))
			return
		}
	}

	tx, err := dbPool.Begin(r.Context())
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not save the trip's airports")
		return
	}
	defer tx.Rollback(r.Context())
	q := store.New(tx)

	// Re-read under the row lock the write needs: editableTrip's copy answered
	// "may this caller edit it", not "what does it say right now".
	locked, err := q.GetTripForUpdate(r.Context(), trip.ID)
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "trip not found")
		return
	}
	user, _ := userFromContext(r.Context())
	applied, err := applyTripEndpoints(r.Context(), q, locked,
		tripEndpoints{OriginAirport: depCode, ReturnAirport: arrCode}, user.ID)
	var ground groundTripAirportError
	switch {
	case errors.As(err, &ground):
		writeJSONError(w, http.StatusUnprocessableEntity,
			"this trip travels by "+ground.mode+", so it doesn't leave from an airport — change the trip's travel mode first")
		return
	case err != nil:
		writeJSONError(w, http.StatusInternalServerError, "could not save the trip's airports")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not save the trip's airports")
		return
	}

	if user.ID != locked.UserID {
		safeGo("notifyCollabEdit", func() { notifyCollabEdit(trip.ID, user.ID) })
	}
	tripID := trip.ID
	end := applied.endpoints
	safeGo("recordEvent", func() {
		recordEvent(user.ID, "trip_endpoints_set", &tripID, map[string]any{
			"has_airport":     end.OriginAirport != "",
			"asymmetric":      end.OriginAirport != "" && end.OriginAirport != end.ReturnAirport,
			"legs_relabelled": len(applied.relabelled),
			"is_collaborator": user.ID != locked.UserID,
		})
	})

	legs := make([]RelabelledLegResponse, 0, len(applied.relabelled))
	for _, l := range applied.relabelled {
		legs = append(legs, RelabelledLegResponse{Before: l.before, After: l.after, Booked: l.booked})
	}
	writeJSON(w, http.StatusOK, TripEndpointsResponse{
		Origin:        strPtrOrNil(end.Origin),
		OriginAirport: strPtrOrNil(end.OriginAirport),
		ReturnAirport: strPtrOrNil(end.ReturnAirport),
		LegsRenamed:   legs,
	})
}

func trimAirportInput(v *string) string {
	if v == nil {
		return ""
	}
	return strings.TrimSpace(*v)
}

// unresolvedAirportMessage is the traveler-facing twin of
// unresolvedAirportReply: same verdict, said to a person rather than to the
// model. Shown verbatim by the trip page, which is why it names the input.
func unresolvedAirportMessage(input string) string {
	return "we couldn't find an airport for \"" + input + "\" — nothing was changed"
}
