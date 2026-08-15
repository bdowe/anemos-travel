package main

// set_leg_transport_mode — the planner's correction for ONE leg.
//
// The app resolves every leg's mode itself (leg_transport_mode.go), and gets
// the common cases right from geography: a short hop inside a rail region is a
// train. What geography cannot know is whether a crossing has a ferry worth
// taking, whether the traveler is driving this one leg, or that the night train
// is the point. The planner does, and every itinerary write now echoes the
// app's answer back to it (legTransportSummary) — so this tool is the reply to
// a leg the model can see is wrong, not a thing it must remember to call.
//
// It writes booking_todos.mode: the SAME column the row's mode menu writes, so
// there is one place a chosen mode lives and one ladder that reads it. When
// the trip page has never synced the leg has no row yet, so the tool creates
// it from computeTripLegs — the same derivation the sync would have used, on
// the same canonical key, so the client's first sync lands on this row rather
// than a second one.

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

var setLegTransportModeTool = anthropic.ToolParam{
	Name: "set_leg_transport_mode",
	Description: anthropic.String("Set how the traveler crosses ONE leg of a saved trip — 'we'll take the train from Rome to Florence', 'the Naples to Capri hop is a ferry', 'they're driving that stretch'. " +
		"The app already derives each leg's mode and shows it to you after every itinerary write; call this only for a leg whose derived mode is wrong, and never to restate one that is already right. " +
		"It updates that leg's existing checklist row in place — its booking link changes to match the mode (flights, Rome2Rio for train/bus/car, Ferryhopper for a ferry) — so never add a second row for a leg the trip already has. " +
		"origin and destination are the two CITIES as they appear in the itinerary, not airports."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"origin":      map[string]any{"type": "string", "description": "The city the leg leaves, as it appears in the itinerary"},
			"destination": map[string]any{"type": "string", "description": "The city the leg arrives in, as it appears in the itinerary"},
			"mode":        map[string]any{"type": "string", "enum": []string{"flight", "car", "train", "bus", "ferry"}, "description": "How they cross this leg"},
		},
		Required: []string{"origin", "destination", "mode"},
	},
}

func runSetLegTransportModeTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		Origin      string `json:"origin"`
		Destination string `json:"destination"`
		Mode        string `json:"mode"`
	}
	json.Unmarshal(input, &in)

	if !s.authed {
		return "The traveler isn't signed in, so there's no saved trip to change. Say how they should travel in your reply instead.", true
	}
	if dbPool == nil {
		return "Saved trips are unavailable right now (persistence offline).", true
	}
	mode := strings.ToLower(strings.TrimSpace(in.Mode))
	if !allowedLegModes[mode] {
		return "mode must be one of: flight, car, train, bus, ferry.", true
	}
	tripID, msg, failed := resolveDateShiftTrip(s)
	if failed {
		return msg, true
	}

	q := store.New(dbPool)
	trip, err := q.GetEditableTripByID(s.ctx, store.GetEditableTripByIDParams{ID: tripID, UserID: s.uid})
	if err != nil {
		return "That trip can't be edited by this traveler.", true
	}
	items, err := q.GetItineraryItemsByTrip(s.ctx, tripID)
	if err != nil {
		return "Could not load that trip's itinerary.", true
	}
	stays, _ := q.ListAccommodationsByTrip(s.ctx, tripID)
	legs := computeTripLegs(trip, items, stays)

	// The leg has to be one the trip actually renders. Refusing with the real
	// list beats writing a row for a crossing that does not exist: an unmatched
	// key would survive as an orphan the next sync can only demote, and the
	// model would have been told "done" about a leg nobody can see.
	fromIdx, toIdx := legIndexOf(legs, in.Origin), legIndexOf(legs, in.Destination)
	if fromIdx < 0 || toIdx < 0 || toIdx != fromIdx+1 {
		return fmt.Sprintf("This trip has no %s → %s leg. Its cities, in order, are: %s. Use two cities that are next to each other in that list.",
			strings.TrimSpace(in.Origin), strings.TrimSpace(in.Destination), legLabelList(legs)), true
	}
	from, to := legs[fromIdx].Label, legs[toIdx].Label

	// The depart date is the city's last day — you leave a city on the day its
	// leg ends, the same rule the page's derivation uses.
	var departDate pgtype.Date
	var departStr *string
	if legs[fromIdx].End != nil {
		departDate = pgtype.Date{Time: *legs[fromIdx].End, Valid: true}
		d := legs[fromIdx].End.Format(dateLayout)
		departStr = &d
	}
	url, provider := transportModeLink(mode, to, &from, departStr, 1)
	key := transportTodoKey(from, to)

	todos, _ := q.ListBookingTodosByTrip(s.ctx, tripID)
	var existing *store.BookingTodo
	for i := range todos {
		if todos[i].TodoKey == key {
			existing = &todos[i]
			break
		}
	}
	if existing != nil {
		if _, err := q.SetBookingTodoMode(s.ctx, store.SetBookingTodoModeParams{
			ID: existing.ID, TripID: tripID, Mode: &mode,
			Provider: strPtrOrNil(provider), SearchUrl: strPtrOrNil(url),
		}); err != nil {
			return "Could not change that leg's transport mode.", true
		}
	} else {
		// No row yet — the trip page has never synced this trip. Create the one
		// the sync would have, auto and on the canonical key, then stamp the
		// mode through the same setter the row menu uses.
		created, err := q.UpsertBookingTodo(s.ctx, store.UpsertBookingTodoParams{
			TripID: tripID, Kind: "transport", TodoKey: key,
			Title:            from + " → " + to,
			Provider:         strPtrOrNil(provider),
			SearchUrl:        strPtrOrNil(url),
			DepartDate:       departDate,
			Position:         int32(len(todos)),
			Role:             strPtrOrNil(roleInterCity),
			OriginLabel:      &from,
			DestinationLabel: &to,
			DerivedMode:      strPtrOrNil(resolveLegMode(trip, legEndpointFrom(from, legCoordIndex(legs)), legEndpointFrom(to, legCoordIndex(legs)), nil)),
		})
		if err != nil {
			return "Could not add that leg to the trip's checklist.", true
		}
		if _, err := q.SetBookingTodoMode(s.ctx, store.SetBookingTodoModeParams{
			ID: created.ID, TripID: tripID, Mode: &mode,
			Provider: strPtrOrNil(provider), SearchUrl: strPtrOrNil(url),
		}); err != nil {
			return "Could not change that leg's transport mode.", true
		}
	}

	touchTripAs(s.ctx, tripID, s.uid)
	sendSSE(s.w, "trip_updated", map[string]string{"trip_id": tripID.String()})
	safeGo("recordEvent", func() {
		recordEvent(s.uid, "agent_leg_mode_set", &tripID, map[string]any{"mode": mode})
	})

	// State the post-state, not just success: every leg's mode as the traveler
	// will now see it, so a wrong mental model cannot survive a "successful"
	// call (docs/zen.md).
	overrides := legModeOverrides(todos)
	overrides[key] = mode
	summary := legTransportSummary(trip, items, stays, overrides)
	result := fmt.Sprintf("%s → %s is now a %s leg; its checklist row opens %s.", from, to, mode, providerDisplayName(provider))
	if summary != "" {
		result += " Every leg now reads:\n" + summary
	}
	return result, false
}

// legIndexOf finds a rendered leg by label, case- and space-insensitively.
// Only exact labels match: a fuzzy one would let "Rome" claim "Rome#2" or a
// substring claim a different city, and this write names a leg.
func legIndexOf(legs []RenderLeg, label string) int {
	want := strings.ToLower(strings.TrimSpace(label))
	if want == "" {
		return -1
	}
	for i, leg := range legs {
		if strings.ToLower(strings.TrimSpace(leg.Label)) == want {
			return i
		}
	}
	return -1
}

// legLabelList renders the trip's cities in order for a refusal message.
func legLabelList(legs []RenderLeg) string {
	labels := make([]string, 0, len(legs))
	for _, leg := range legs {
		labels = append(labels, leg.Label)
	}
	if len(labels) == 0 {
		return "(none yet)"
	}
	return strings.Join(labels, " → ")
}

// providerDisplayName names the site a row's link opens, for the tool result.
func providerDisplayName(provider string) string {
	switch provider {
	case "rome2rio":
		return "Rome2Rio (trains, buses and driving routes)"
	case "ferry":
		return "Ferryhopper"
	case "google_flights":
		return "Google Flights"
	case "kayak":
		return "Kayak"
	}
	return "its booking search"
}
