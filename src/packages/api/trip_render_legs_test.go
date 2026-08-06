package main

// CROSS-LANGUAGE CONTRACT (specs/trip-dates-truth): these fixtures and
// expected values hand-mirror test/leg_ranges_test.dart in the Flutter suite
// (the calendar-parity convention) — same trips, same expected spans, city
// names and all. Change either side and you must change both. The two cases
// the Dart suite pins with "diverges:" markers appear here with the SERVER
// expected values (the reconciled post-cutover rules): an address-less
// confirmed stay DOES anchor (name fallback), and a spanless interior leg
// does NOT reset the arrival chain.

import (
	"testing"
	"time"

	"travel-route-planner/store"
)

func rlItem(pos int, name string, city *string, day int) store.ItineraryItem {
	it := store.ItineraryItem{Position: int32(pos), Name: name, City: city,
		Latitude: 1, Longitude: 1}
	if day > 0 {
		d := int32(day)
		it.Day = &d
	}
	return it
}

func rlCity(c string) *string { return &c }

func rlTrip(start, end string) store.Trip {
	t := store.Trip{}
	if start != "" {
		t.StartDate = validDate(start)
	}
	if end != "" {
		t.EndDate = validDate(end)
	}
	return t
}

func rlStay(name, address, checkIn, checkOut string) store.Accommodation {
	a := store.Accommodation{Name: name,
		CheckIn: validDate(checkIn), CheckOut: validDate(checkOut)}
	if address != "" {
		a.Address = &address
	}
	return a
}

func rlDate(iso string) time.Time { return civilDate(iso) }

func assertSpan(t *testing.T, leg RenderLeg, start, end string) {
	t.Helper()
	if leg.Start == nil || leg.End == nil {
		t.Fatalf("%s: span = %v/%v, want %s/%s", leg.Key, leg.Start, leg.End, start, end)
	}
	if !leg.Start.Equal(rlDate(start)) || !leg.End.Equal(rlDate(end)) {
		t.Fatalf("%s: span = %s/%s, want %s/%s", leg.Key,
			leg.Start.Format(dateLayout), leg.End.Format(dateLayout), start, end)
	}
}

func TestComputeTripLegsItemDayRanges(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-08-24", "2026-08-28"), []store.ItineraryItem{
		rlItem(0, "Feskekôrka", rlCity("Gothenburg"), 1),
		rlItem(1, "Liseberg", rlCity("Gothenburg"), 3),
		rlItem(2, "Prado", rlCity("Madrid"), 5),
	}, nil)
	if len(legs) != 2 {
		t.Fatalf("legs = %d, want 2", len(legs))
	}
	assertSpan(t, legs[0], "2026-08-24", "2026-08-26")
	// Madrid's own range collapses to its item day; the chain pulls its
	// visible start back to the arrival (Gothenburg's end).
	assertSpan(t, legs[1], "2026-08-26", "2026-08-28")
	if legs[0].Key != "Gothenburg" || legs[1].Key != "Madrid" {
		t.Fatalf("keys = %s/%s", legs[0].Key, legs[1].Key)
	}
	if legs[0].DateSource != "items" || legs[1].DateSource != "items" {
		t.Fatalf("date sources = %s/%s, want items/items", legs[0].DateSource, legs[1].DateSource)
	}
	if legs[0].FirstPos != 0 || legs[0].LastPos != 1 || legs[1].FirstPos != 2 {
		t.Fatalf("positions = %d-%d / %d-%d", legs[0].FirstPos, legs[0].LastPos, legs[1].FirstPos, legs[1].LastPos)
	}
}

func TestComputeTripLegsFirstLegAnchor(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-08-24", "2026-09-01"), []store.ItineraryItem{
		rlItem(0, "Prague", rlCity("Prague"), 4),
		rlItem(1, "Kraków", rlCity("Kraków"), 9),
	}, nil)
	assertSpan(t, legs[0], "2026-08-24", "2026-08-27")
	assertSpan(t, legs[1], "2026-08-27", "2026-09-01")
}

func TestComputeTripLegsConfirmedStayAnchors(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-09-01", "2026-09-07"), []store.ItineraryItem{
		rlItem(0, "Museo", rlCity("Medellín"), 1),
		rlItem(1, "Quito", rlCity("Quito"), 5),
	}, []store.Accommodation{
		rlStay("Hotel Quito", "Av. González Suárez, Quito, Ecuador", "2026-09-03", "2026-09-05"),
	})
	// The stay's dates are the leg's OWN span (source "stay", end Sep 5),
	// but the arrival rule still pulls the visible start back to Medellín's
	// end (Sep 1) — the Dart raw-pass fixture sees Sep 3; this module is the
	// visible/chained output, matching the client's rendered value.
	assertSpan(t, legs[1], "2026-09-01", "2026-09-05")
	if legs[1].DateSource != "stay" {
		t.Fatalf("date source = %s, want stay", legs[1].DateSource)
	}
}

// diverges (Dart pins the opposite pre-cutover): an address-LESS confirmed
// stay anchors via the NAME fallback — the reconciled server rule, so
// agent-added "Stay in Quito" rows anchor their leg.
func TestComputeTripLegsAddressLessStayAnchorsByName(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-09-01", "2026-09-05"), []store.ItineraryItem{
		rlItem(0, "Quito", rlCity("Quito"), 3),
	}, []store.Accommodation{
		rlStay("Stay in Quito", "", "2026-09-02", "2026-09-04"),
	})
	assertSpan(t, legs[0], "2026-09-02", "2026-09-04")
	if legs[0].DateSource != "stay" {
		t.Fatalf("date source = %s, want stay (name fallback)", legs[0].DateSource)
	}
}

func TestComputeTripLegsAutoAllocation(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-06-01", "2026-06-08"), []store.ItineraryItem{
		rlItem(0, "Louvre", rlCity("Paris"), 0),
		rlItem(1, "Orsay", rlCity("Paris"), 0),
		rlItem(2, "Marais walk", rlCity("Paris"), 0),
		rlItem(3, "Colosseum", rlCity("Rome"), 0),
	}, nil)
	assertSpan(t, legs[0], "2026-06-01", "2026-06-06")
	// Raw auto slices are [Jun 7, Jun 8]; the arrival rule renders Rome from
	// Paris's departure day (checkout-day semantics, like every other leg).
	assertSpan(t, legs[1], "2026-06-06", "2026-06-08")
	if legs[0].DateSource != "auto" || legs[1].DateSource != "auto" {
		t.Fatalf("date sources = %s/%s, want auto/auto", legs[0].DateSource, legs[1].DateSource)
	}
}

func TestComputeTripLegsMoreLocationsThanDays(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-06-01", "2026-06-02"), []store.ItineraryItem{
		rlItem(0, "A", rlCity("Alpha"), 0),
		rlItem(1, "B", rlCity("Beta"), 0),
		rlItem(2, "C", rlCity("Gamma"), 0),
	}, nil)
	assertSpan(t, legs[0], "2026-06-01", "2026-06-01")
	assertSpan(t, legs[1], "2026-06-01", "2026-06-01")
	// Raw slice is a bare Jun 2; the arrival rule renders it from Beta's end.
	assertSpan(t, legs[2], "2026-06-01", "2026-06-02")
}

func TestComputeTripLegsDatelessTrip(t *testing.T) {
	legs := computeTripLegs(rlTrip("", ""), []store.ItineraryItem{
		rlItem(0, "Louvre", rlCity("Paris"), 1),
	}, nil)
	if legs[0].Start != nil || legs[0].End != nil || legs[0].DateSource != "" {
		t.Fatalf("dateless legs = %+v, want nil span", legs[0])
	}
}

func TestComputeTripLegsZeroNightCollapseCascades(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-09-01", "2026-09-07"), []store.ItineraryItem{
		rlItem(0, "Museo", rlCity("Medellín"), 1),
		rlItem(1, "Comuna 13", rlCity("Medellín"), 6),
		rlItem(2, "Quito", rlCity("Quito"), 5),
		rlItem(3, "Mitad del Mundo", rlCity("Galápagos"), 6),
		rlItem(4, "Tortuga Bay", rlCity("Galápagos"), 7),
	}, nil)
	assertSpan(t, legs[1], "2026-09-06", "2026-09-06")
	if !legs[1].ZeroNight {
		t.Fatal("squeezed leg not marked zero_night")
	}
	assertSpan(t, legs[2], "2026-09-06", "2026-09-07")
	if legs[2].ZeroNight {
		t.Fatal("downstream leg wrongly marked zero_night")
	}
}

func TestComputeTripLegsConsecutiveSqueezesChain(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-09-01", "2026-09-07"), []store.ItineraryItem{
		rlItem(0, "Museo", rlCity("Medellín"), 1),
		rlItem(1, "Comuna 13", rlCity("Medellín"), 6),
		rlItem(2, "Quito", rlCity("Quito"), 4),
		rlItem(3, "Guayaquil", rlCity("Guayaquil"), 5),
	}, nil)
	assertSpan(t, legs[1], "2026-09-06", "2026-09-06")
	assertSpan(t, legs[2], "2026-09-06", "2026-09-06")
	if !legs[1].ZeroNight || !legs[2].ZeroNight {
		t.Fatal("chained squeezes not both zero_night")
	}
}

func TestComputeTripLegsStayNeverCollapses(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-09-01", "2026-09-07"), []store.ItineraryItem{
		rlItem(0, "Museo", rlCity("Medellín"), 1),
		rlItem(1, "Comuna 13", rlCity("Medellín"), 6),
		rlItem(2, "Quito", rlCity("Quito"), 5),
	}, []store.Accommodation{
		rlStay("Hotel Quito", "Av. González Suárez, Quito, Ecuador", "2026-09-03", "2026-09-05"),
	})
	assertSpan(t, legs[1], "2026-09-03", "2026-09-05")
	if legs[1].ZeroNight {
		t.Fatal("stay-anchored leg wrongly collapsed")
	}
}

// diverges (Dart pins the opposite pre-cutover): a spanless interior leg is
// SKIPPED by the arrival chain and never resets it — the reconciled server
// rule. Note the auto lattice needs no trip end here, so the hubless leg has
// no span at all.
func TestComputeTripLegsSpanlessLegDoesNotResetChain(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-06-01", ""), []store.ItineraryItem{
		rlItem(0, "A", rlCity("Alpha"), 1),
		rlItem(1, "mystery", nil, 0),
		rlItem(2, "C", rlCity("Gamma"), 5),
	}, nil)
	if len(legs) != 3 {
		t.Fatalf("legs = %d, want 3", len(legs))
	}
	if legs[1].Start != nil || legs[1].Label != otherPlacesLabel || legs[1].Hub != nil {
		t.Fatalf("hubless leg = %+v, want spanless Other places", legs[1])
	}
	// Gamma still chains off Alpha's end across the spanless leg.
	assertSpan(t, legs[2], "2026-06-01", "2026-06-05")
}

func TestComputeTripLegsRevisitKeysAndHubs(t *testing.T) {
	legs := computeTripLegs(rlTrip("2026-06-01", "2026-06-06"), []store.ItineraryItem{
		rlItem(0, "Acropolis", rlCity("Athens"), 1),
		rlItem(1, "Oia", rlCity("Santorini"), 3),
		rlItem(2, "Plaka dinner", rlCity("Athens"), 5),
	}, nil)
	if legs[0].Key != "Athens" || legs[1].Key != "Santorini" || legs[2].Key != "Athens#2" {
		t.Fatalf("keys = %s/%s/%s, want Athens/Santorini/Athens#2", legs[0].Key, legs[1].Key, legs[2].Key)
	}
	if legs[2].Label != "Athens" {
		t.Fatalf("revisit label = %s, want Athens", legs[2].Label)
	}
}

func TestAllocateLegDays(t *testing.T) {
	if got := allocateLegDays(8, []int{3, 1}); got[0] != 6 || got[1] != 2 {
		t.Fatalf("allocateLegDays(8, [3 1]) = %v, want [6 2]", got)
	}
	if got := allocateLegDays(10, []int{1, 1, 1}); got[0] != 4 || got[1] != 3 || got[2] != 3 {
		t.Fatalf("allocateLegDays(10, [1 1 1]) = %v, want [4 3 3]", got)
	}
	if got := allocateLegDays(2, []int{5, 5, 5}); got[0] != 1 || got[1] != 1 || got[2] != 1 {
		t.Fatalf("allocateLegDays(2, [5 5 5]) = %v, want [1 1 1]", got)
	}
}
