package main

import (
	"testing"

	"github.com/google/uuid"
)

// The tools slice is part of the prompt-cache prefix: its order must be
// byte-stable per session shape, and must match the pre-refactor hardcoded
// order exactly (a reorder silently invalidates the system-prompt cache
// breakpoint on every request). These sequences are the pre-dispatch-table
// behavior, pinned.
func TestPlanSessionToolsOrderStable(t *testing.T) {
	base := []string{
		"search_places", "suggest_stays", "suggest_transport", "suggest_ferries",
		"search_flights", "check_flight_connectivity", "search_events", "search_local_recommendations", "get_weather",
	}
	tid := uuid.New()

	cases := []struct {
		name    string
		session *planSession
		want    []string
	}{
		// set_trip_dates, set_leg_dates, set_trip_origin,
		// set_leg_transport_mode and set_trip_description are all authed-gated,
		// so they appear only in the authed shapes.
		//
		// search_hotels is NOT gated, so unlike them it lands at the tail of
		// ALL three shapes — including anonymous, which until then had stayed
		// byte-identical across every tool added since find_parking. That was a
		// deliberate one-time cache re-warm on every session shape, taken
		// because "where should I stay" is a question anonymous sessions ask
		// constantly, and gating it would trade a permanent capability hole for
		// a one-off cache cost.
		//
		// set_trip_description sits after it, gated, so the anonymous tail is
		// back to being untouched by a tool append — an anonymous session has no
		// saved trip whose description could be changed.
		//
		// replace_leg is last and gated on a BOUND trip (like
		// update_itinerary_section), so it lands in the trip-bound shape only:
		// the anonymous and unbound-authed tools arrays stay byte-identical and
		// take no cache re-warm at all.
		{"anonymous", &planSession{}, append(append([]string{}, base...), "create_itinerary", "set_travel_mode", "suggest_replies", "search_nearby", "find_parking", "search_hotels")},
		{"authed", &planSession{authed: true},
			append(append([]string{}, base...), "create_itinerary", "save_preferences", "get_trip",
				"add_booking_todo", "update_booking_todo", "remove_booking_todo", "add_packing_item", "set_travel_mode", "suggest_replies", "search_nearby", "find_parking", "set_trip_dates", "set_leg_dates", "set_trip_origin", "set_leg_transport_mode", "search_hotels", "set_trip_description")},
		{"authed trip-bound", &planSession{authed: true, boundTripID: &tid},
			append(append([]string{}, base...), "update_itinerary_section", "save_preferences", "get_trip",
				"add_booking_todo", "update_booking_todo", "remove_booking_todo", "add_packing_item", "review_trip",
				"add_accommodation", "add_transport_segment", "move_itinerary_item", "set_travel_mode", "suggest_replies", "search_nearby", "find_parking", "set_trip_dates", "set_leg_dates", "set_trip_origin", "set_leg_transport_mode", "search_hotels", "set_trip_description", "replace_leg")},
	}
	for _, tc := range cases {
		tools := planSessionTools(tc.session)
		var got []string
		for _, tool := range tools {
			got = append(got, tool.OfTool.Name)
		}
		if len(got) != len(tc.want) {
			t.Fatalf("%s: tools = %v, want %v", tc.name, got, tc.want)
		}
		for i := range got {
			if got[i] != tc.want[i] {
				t.Fatalf("%s: tools[%d] = %s, want %s (full: %v)", tc.name, i, got[i], tc.want[i], got)
			}
		}
	}
}

// Every registry entry must be dispatchable and unambiguous.
func TestPlanToolRegistryNamesUniqueAndDispatchable(t *testing.T) {
	if len(planToolByName) != len(planToolRegistry) {
		t.Fatalf("planToolByName has %d entries for %d registry entries — duplicate tool name",
			len(planToolByName), len(planToolRegistry))
	}
	for i := range planToolRegistry {
		pt := &planToolRegistry[i]
		if pt.def.Name == "" {
			t.Fatalf("registry entry %d has no name", i)
		}
		if pt.run == nil {
			t.Fatalf("tool %s has no dispatcher", pt.def.Name)
		}
		if planToolByName[pt.def.Name] != pt {
			t.Fatalf("planToolByName[%s] does not point at its registry entry", pt.def.Name)
		}
	}
}
