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
		// set_trip_dates, set_leg_dates, set_trip_origin and
		// set_leg_transport_mode are all authed-gated, so the anonymous tail
		// intentionally stays find_parking — the anonymous tools array is
		// byte-identical to before any of them existed, and anonymous sessions
		// keep their cache line.
		{"anonymous", &planSession{}, append(append([]string{}, base...), "create_itinerary", "set_travel_mode", "suggest_replies", "search_nearby", "find_parking")},
		{"authed", &planSession{authed: true},
			append(append([]string{}, base...), "create_itinerary", "save_preferences", "get_trip",
				"add_booking_todo", "update_booking_todo", "remove_booking_todo", "add_packing_item", "set_travel_mode", "suggest_replies", "search_nearby", "find_parking", "set_trip_dates", "set_leg_dates", "set_trip_origin", "set_leg_transport_mode")},
		{"authed trip-bound", &planSession{authed: true, boundTripID: &tid},
			append(append([]string{}, base...), "update_itinerary_section", "save_preferences", "get_trip",
				"add_booking_todo", "update_booking_todo", "remove_booking_todo", "add_packing_item", "review_trip",
				"add_accommodation", "add_transport_segment", "move_itinerary_item", "set_travel_mode", "suggest_replies", "search_nearby", "find_parking", "set_trip_dates", "set_leg_dates", "set_trip_origin", "set_leg_transport_mode")},
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
