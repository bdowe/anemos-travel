package main

import (
	"testing"

	"travel-route-planner/store"
)

// TWIN of the 'isCityFiller parity with the Go server' group in
// flutter-app/test/trip_detail_derivation_test.dart. Same cases, same
// expectations, in the same order — docs/zen.md requires the parity contract
// because "city filler" now has two implementations: the client's, which HIDES
// these rows, and the server's, which must not count what the client hides.
// Change one table, change the other.
//
// The `dartOnly` column is the ONE documented divergence: Dart compares the
// name against cityOf(), which falls back to a regex over the address when the
// city column is empty. The server has no copy of that heuristic and is not
// growing one — see isCityFiller's comment.
func TestIsCityFillerParity(t *testing.T) {
	cases := []struct {
		desc     string
		name     string
		city     *string
		hub      *string // day_trip_from
		address  *string
		want     bool
		dartOnly bool
	}{
		{desc: "name equals city", name: "Prague", city: strp("Prague"), want: true},
		{desc: "real activity in a city", name: "Charles Bridge", city: strp("Prague"), want: false},
		{desc: "case and space insensitive", name: "  prague ", city: strp("Prague"), want: true},
		{desc: "name equals the day-trip hub", name: "Kyoto", hub: strp("Kyoto"), city: strp("Nara"), want: true},
		{desc: "hub set, name is a real place", name: "Fushimi Inari", hub: strp("Kyoto"), city: strp("Nara"), want: false},
		{desc: "no city and no hub", name: "Prague", want: false},
		{desc: "empty name is never a filler", name: "   ", city: strp("Prague"), want: false},
		{desc: "city empty, name matches the address city", name: "Prague",
			city: strp(""), address: strp("Old Town, Prague, Czechia"), want: false, dartOnly: true},
	}

	for _, c := range cases {
		t.Run(c.desc, func(t *testing.T) {
			got := isCityFiller(store.ItineraryItem{
				Name: c.name, City: c.city, DayTripFrom: c.hub, Address: c.address,
			})
			want := c.want
			if c.dartOnly {
				// Documented divergence: Dart says true here, Go says false.
				want = false
			}
			if got != want {
				t.Fatalf("isCityFiller(%q, city=%v, hub=%v) = %v, want %v",
					c.name, deref(c.city), deref(c.hub), got, want)
			}
		})
	}
}

func deref(s *string) string {
	if s == nil {
		return "<nil>"
	}
	return *s
}
