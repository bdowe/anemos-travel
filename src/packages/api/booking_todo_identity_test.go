package main

import (
	"testing"

	"travel-route-planner/store"
)

// booking_todo_identity_test.go — the canonicalization table (migration 00064).
//
// These cases are the contract the Dart derivation is held to: _deriveTodos
// builds the outbound before the city loop and the return after it, and every
// city it emits a leg for also gets a stay row. Everything here is a pure
// function of one posted payload, so a divergence shows up as a table row
// rather than as a deleted booking flag in production.

func leg(key, origin, dest string) DerivedBookingTodo {
	o := origin
	return DerivedBookingTodo{Kind: "transport", TodoKey: key, Title: origin + " → " + dest, Origin: &o, Destination: dest}
}

func stay(city string) DerivedBookingTodo {
	return DerivedBookingTodo{Kind: "stay", TodoKey: "stay:" + city, Title: "Stay in " + city, Destination: city}
}

func TestClassifyDerivedTodos(t *testing.T) {
	cases := []struct {
		name  string
		in    []DerivedBookingTodo
		roles []string
		keys  []string
	}{
		{
			name: "round trip through two cities",
			in: []DerivedBookingTodo{
				leg("transport:ewr>>amsterdam", "EWR", "Amsterdam"),
				stay("Amsterdam"),
				leg("transport:amsterdam>>rome", "Amsterdam", "Rome"),
				stay("Rome"),
				leg("transport:rome>>ewr", "Rome", "EWR"),
			},
			roles: []string{roleHomeOutbound, roleStay, roleInterCity, roleStay, roleHomeReturn},
			keys: []string{"transport:@home>>amsterdam", "stay:Amsterdam", "transport:amsterdam>>rome",
				"stay:Rome", "transport:rome>>@home"},
		},
		{
			// The user's trip: out of ALB, home into EWR. The two endpoints
			// differ, and the two keys must stay distinct so changing one can
			// never disturb the other.
			name: "asymmetric endpoints keep distinct keys",
			in: []DerivedBookingTodo{
				leg("transport:alb>>amsterdam", "ALB", "Amsterdam"),
				stay("Amsterdam"),
				leg("transport:amsterdam>>ewr", "Amsterdam", "EWR"),
			},
			roles: []string{roleHomeOutbound, roleStay, roleHomeReturn},
			keys:  []string{"transport:@home>>amsterdam", "stay:Amsterdam", "transport:amsterdam>>@home"},
		},
		{
			name: "single city round trip",
			in: []DerivedBookingTodo{
				leg("transport:ewr>>amsterdam", "EWR", "Amsterdam"),
				stay("Amsterdam"),
				leg("transport:amsterdam>>ewr", "Amsterdam", "EWR"),
			},
			roles: []string{roleHomeOutbound, roleStay, roleHomeReturn},
			keys:  []string{"transport:@home>>amsterdam", "stay:Amsterdam", "transport:amsterdam>>@home"},
		},
		{
			// Only one leg, and both its endpoints sit outside the itinerary.
			// Outbound is checked first, so it reads as the departure.
			name: "lone leg outside the itinerary reads as departure",
			in: []DerivedBookingTodo{
				leg("transport:ewr>>alb", "EWR", "ALB"),
				stay("Amsterdam"),
			},
			roles: []string{roleHomeOutbound, roleStay},
			keys:  []string{"transport:@home>>alb", "stay:Amsterdam"},
		},
		{
			name: "one way out keeps the return unclaimed",
			in: []DerivedBookingTodo{
				leg("transport:ewr>>amsterdam", "EWR", "Amsterdam"),
				stay("Amsterdam"),
			},
			roles: []string{roleHomeOutbound, roleStay},
			keys:  []string{"transport:@home>>amsterdam", "stay:Amsterdam"},
		},
		{
			// No stays means no itinerary to be outside of. Guessing here is
			// how an inter-city leg would get promoted to "the flight home".
			name: "empty stay set never reads as home",
			in: []DerivedBookingTodo{
				leg("transport:ewr>>amsterdam", "EWR", "Amsterdam"),
				leg("transport:amsterdam>>rome", "Amsterdam", "Rome"),
			},
			roles: []string{roleInterCity, roleInterCity},
			keys:  []string{"transport:ewr>>amsterdam", "transport:amsterdam>>rome"},
		},
		{
			name: "revisited city stays inter-city",
			in: []DerivedBookingTodo{
				leg("transport:ewr>>athens", "EWR", "Athens"),
				stay("Athens"),
				leg("transport:athens>>fira", "Athens", "Fira"),
				stay("Fira"),
				leg("transport:fira>>athens", "Fira", "Athens"),
				leg("transport:athens>>ewr", "Athens", "EWR"),
			},
			roles: []string{roleHomeOutbound, roleStay, roleInterCity, roleStay, roleInterCity, roleHomeReturn},
			keys: []string{"transport:@home>>athens", "stay:Athens", "transport:athens>>fira",
				"stay:Fira", "transport:fira>>athens", "transport:athens>>@home"},
		},
		{
			// A hubless first group. The label survives verbatim into the key,
			// spaces and all; namesAPlace rejects it downstream.
			name: "other places label survives",
			in: []DerivedBookingTodo{
				leg("transport:ewr>>other places", "EWR", "Other places"),
				stay("Other places"),
			},
			roles: []string{roleHomeOutbound, roleStay},
			keys:  []string{"transport:@home>>other places", "stay:Other places"},
		},
		{
			// A non-derived key (agent-added, custom, or an older client's
			// private shape) is never renamed and never counts as first/last.
			name: "foreign transport key is left alone",
			in: []DerivedBookingTodo{
				leg("leg:paris-lyon", "Paris", "Lyon"),
				stay("Paris"),
			},
			roles: []string{roleInterCity, roleStay},
			keys:  []string{"leg:paris-lyon", "stay:Paris"},
		},
		{
			// Canonicalizing must never collide two rows onto one key: the
			// batch upsert collapses duplicates last-wins, which would silently
			// drop a leg. The loser keeps its literal key and its inter_city
			// role — never a home role with a non-canonical key, which the
			// CHECK constraints reject.
			name: "collision falls back to the literal key",
			in: []DerivedBookingTodo{
				leg("transport:ewr>>amsterdam", "EWR", "Amsterdam"),
				leg("transport:@home>>amsterdam", "@home", "Amsterdam"),
				stay("Amsterdam"),
			},
			roles: []string{roleHomeOutbound, roleInterCity, roleStay},
			keys:  []string{"transport:@home>>amsterdam", "transport:@home>>amsterdam", "stay:Amsterdam"},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := classifyDerivedTodos(tc.in)
			if len(got) != len(tc.in) {
				t.Fatalf("got %d identities, want %d", len(got), len(tc.in))
			}
			for i := range got {
				if got[i].role != tc.roles[i] {
					t.Errorf("row %d role = %q, want %q", i, got[i].role, tc.roles[i])
				}
				if got[i].key != tc.keys[i] {
					t.Errorf("row %d key = %q, want %q", i, got[i].key, tc.keys[i])
				}
			}
		})
	}
}

// The collision loser must never end up as a home role with a literal key —
// that pairing is rejected by the 00064 CHECK constraints, so an inference bug
// here would surface as a 500 on sync rather than a wrong row.
func TestClassifyDerivedTodosNeverPairsHomeRoleWithLiteralKey(t *testing.T) {
	for _, id := range classifyDerivedTodos([]DerivedBookingTodo{
		leg("transport:ewr>>amsterdam", "EWR", "Amsterdam"),
		leg("transport:@home>>amsterdam", "@home", "Amsterdam"),
		stay("Amsterdam"),
	}) {
		if id.role == roleHomeOutbound && !isDerivedTransportKey(id.key) {
			t.Fatalf("home_outbound with unparseable key %q", id.key)
		}
		if id.role == roleHomeOutbound && id.key != "transport:@home>>amsterdam" {
			t.Fatalf("home_outbound key = %q, want the canonical form", id.key)
		}
		if id.role == roleHomeReturn && !hasSuffix(id.key, ">>"+homeEndpointToken) {
			t.Fatalf("home_return key = %q, want the @home suffix", id.key)
		}
	}
}

func hasSuffix(s, suffix string) bool {
	return len(s) >= len(suffix) && s[len(s)-len(suffix):] == suffix
}

// The wire keeps the endpoint-labelled key the client derives and matches on,
// so a storage rename is invisible to it. Round-trip: what we hand back must be
// what a fresh client would post.
func TestDisplayBookingTodoKeyRoundTrips(t *testing.T) {
	ptr := func(s string) *string { return &s }
	cases := []struct {
		name string
		row  store.BookingTodo
		want string
	}{
		{"home outbound renders its labels",
			store.BookingTodo{TodoKey: "transport:@home>>amsterdam", Role: ptr(roleHomeOutbound),
				OriginLabel: ptr("ALB"), DestinationLabel: ptr("Amsterdam")},
			"transport:alb>>amsterdam"},
		{"home return renders its labels",
			store.BookingTodo{TodoKey: "transport:rome>>@home", Role: ptr(roleHomeReturn),
				OriginLabel: ptr("Rome"), DestinationLabel: ptr("EWR")},
			"transport:rome>>ewr"},
		{"inter city passes through",
			store.BookingTodo{TodoKey: "transport:amsterdam>>rome", Role: ptr(roleInterCity),
				OriginLabel: ptr("Amsterdam"), DestinationLabel: ptr("Rome")},
			"transport:amsterdam>>rome"},
		{"stay passes through",
			store.BookingTodo{TodoKey: "stay:rome", Role: ptr(roleStay), DestinationLabel: ptr("Rome")},
			"stay:rome"},
		{"a home row with no labels keeps its storage key rather than inventing one",
			store.BookingTodo{TodoKey: "transport:@home>>amsterdam", Role: ptr(roleHomeOutbound)},
			"transport:@home>>amsterdam"},
		{"a pre-00064 row has no role and is untouched",
			store.BookingTodo{TodoKey: "transport:ewr>>amsterdam"},
			"transport:ewr>>amsterdam"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := displayBookingTodoKey(tc.row); got != tc.want {
				t.Fatalf("display key = %q, want %q", got, tc.want)
			}
		})
	}
}

// One ladder per direction, and the airport columns are written together, so
// "return_airport is NULL" never has to be read as "same as departure".
func TestTripEndpointLabels(t *testing.T) {
	ptr := func(s string) *string { return &s }
	cases := []struct {
		name             string
		trip             store.Trip
		ownerHome        *string
		wantDep, wantArr string
	}{
		{"trip airports win and may differ",
			store.Trip{OriginAirport: ptr("ALB"), ReturnAirport: ptr("EWR"), Origin: ptr("Lake George, NY")},
			ptr("BOS"), "ALB", "EWR"},
		{"a stated origin beats the saved airport",
			store.Trip{Origin: ptr("Lake George, NY")}, ptr("EWR"),
			"Lake George, NY", "Lake George, NY"},
		{"the owner's saved airport is the last rung",
			store.Trip{}, ptr("EWR"), "EWR", "EWR"},
		{"nothing stated anywhere says nothing",
			store.Trip{}, nil, "", ""},
		{"a lowercase stored code is normalized",
			store.Trip{OriginAirport: ptr("alb"), ReturnAirport: ptr("alb")}, nil, "ALB", "ALB"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dep, arr := tripEndpointLabels(tc.trip, tc.ownerHome)
			if dep != tc.wantDep || arr != tc.wantArr {
				t.Fatalf("labels = (%q, %q), want (%q, %q)", dep, arr, tc.wantDep, tc.wantArr)
			}
		})
	}
}

// A three-letter endpoint must not substring-claim a longer place name: "alb"
// vs "Albufeira" would silently mark the flight out as already booked. Short
// city names must still work.
//
// The deliberate cost: a code no longer claims the spelled-out airport it
// stands for ("alb" vs "Albany International Airport"), because nothing here
// knows IATA. That direction is the safe one to lose — a missed claim offers to
// book something already booked, while a false claim hides an unbooked flight.
func TestFuzzyMatchShortTokens(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"albufeira", "alb", false},
		{"alb", "alb", true},
		{"albany international airport", "alb", false},
		{"rio de janeiro", "rio", true},
		{"new york, ny", "ny", true},
		{"amsterdam", "rome", false},
		{"amsterdam schiphol", "amsterdam", true},
	}
	for _, tc := range cases {
		if got := fuzzyMatch(tc.a, tc.b); got != tc.want {
			t.Errorf("fuzzyMatch(%q, %q) = %v, want %v", tc.a, tc.b, got, tc.want)
		}
	}
}

// @home must never reach a traveler: it would ride into Next Step copy, a
// finding's fix, and the canonical-English agent seed.
func TestNamesAPlaceRejectsReservedTokens(t *testing.T) {
	for _, s := range []string{"@home", "@anything", "", "Itinerary", "Other places"} {
		if namesAPlace(s) {
			t.Errorf("namesAPlace(%q) = true, want false", s)
		}
	}
	for _, s := range []string{"Amsterdam", "ALB", "Lake George, NY"} {
		if !namesAPlace(s) {
			t.Errorf("namesAPlace(%q) = false, want true", s)
		}
	}
}
