package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// Pure unit tests for the individual review checks — hand-built exportData, no
// DB. These exercise the deterministic rules in isolation.

func dateVal(t *testing.T, s string) pgtype.Date {
	t.Helper()
	tm, err := time.Parse("2006-01-02", s)
	if err != nil {
		t.Fatalf("parse date %q: %v", s, err)
	}
	return pgtype.Date{Time: tm, Valid: true}
}

func i32p(v int32) *int32 { return &v }

func TestCheckDates_Undated(t *testing.T) {
	d := exportData{Trip: store.Trip{ID: uuid.New()}}
	fs := checkDates("en", d)
	if len(fs) != 1 || fs[0].Category != "dates" || fs[0].Severity != "info" {
		t.Fatalf("undated trip = %+v", fs)
	}
}

func TestCheckDates_ItemPastSpan(t *testing.T) {
	trip := store.Trip{ID: uuid.New(),
		StartDate: dateVal(t, "2026-08-01"), EndDate: dateVal(t, "2026-08-03")} // 3-day span
	items := []store.ItineraryItem{
		{ID: uuid.New(), Name: "Louvre", Day: i32p(2)},
		{ID: uuid.New(), Name: "Way Out", Day: i32p(9)},
	}
	fs := checkDates("en", exportData{Trip: trip, Items: items})
	if len(fs) != 1 || fs[0].Severity != "warn" || fs[0].Day == nil || *fs[0].Day != 9 {
		t.Fatalf("past-span = %+v", fs)
	}
}

func TestCheckUnscheduled_Grouped(t *testing.T) {
	d := exportData{Trip: store.Trip{ID: uuid.New()}, Items: []store.ItineraryItem{
		{ID: uuid.New(), Name: "A"}, // day nil
		{ID: uuid.New(), Name: "B"}, // day nil
		{ID: uuid.New(), Name: "C", Day: i32p(1)},
	}}
	fs := checkUnscheduled("en", d)
	if len(fs) != 1 || fs[0].Category != "unscheduled" {
		t.Fatalf("unscheduled = %+v", fs)
	}
}

func TestCheckDensity_EmptyAndPacked(t *testing.T) {
	morning := strp("morning")
	items := []store.ItineraryItem{
		{ID: uuid.New(), Name: "A", Day: i32p(1), TimeOfDay: morning},
		{ID: uuid.New(), Name: "B", Day: i32p(1), TimeOfDay: morning},
		{ID: uuid.New(), Name: "C", Day: i32p(1), TimeOfDay: morning}, // three mornings on day 1
		// day 2 empty
		{ID: uuid.New(), Name: "D", Day: i32p(3)},
	}
	fs := checkDensity("en", exportData{Trip: store.Trip{ID: uuid.New()}, Items: items})
	// Everything checkDensity emits is a suggestion, never attention-tier.
	for _, f := range fs {
		if f.Severity != "info" {
			t.Fatalf("density findings must all be info, got %+v", f)
		}
	}
	msgs := map[string]bool{}
	for _, f := range fs {
		msgs[f.Message] = true
	}
	if len(fs) != 2 {
		t.Fatalf("expected exactly two findings (empty day + morning collision), got %+v", fs)
	}
	if !msgs["Day 2 has nothing planned."] {
		t.Fatalf("single empty day should keep the singular message, got %+v", fs)
	}
	if !msgs["Day 1 has 3 things scheduled for the morning."] {
		t.Fatalf("expected the 3-item morning collision, got %+v", fs)
	}
}

// Two things in one slot is a normal evening — dinner and a bar — not a
// scheduling defect. Flagging every pair is what made Trip Health unreadable,
// so the collision threshold is 3.
func TestCheckDensity_TwoInASlotIsFine(t *testing.T) {
	evening := strp("evening")
	items := []store.ItineraryItem{
		{ID: uuid.New(), Name: "Moeders", Day: i32p(1), TimeOfDay: evening},
		{ID: uuid.New(), Name: "Door 74", Day: i32p(1), TimeOfDay: evening},
	}
	fs := checkDensity("en", exportData{Trip: store.Trip{ID: uuid.New()}, Items: items})
	for _, f := range fs {
		if strings.Contains(f.Message, "scheduled for the") {
			t.Fatalf("two items in a slot must not be flagged, got %+v", f)
		}
	}
}

// A packed day says one thing once. Its slots are all crowded by construction,
// so emitting them too said the same thing four times over.
func TestCheckDensity_PackedDayEmitsOneFinding(t *testing.T) {
	var items []store.ItineraryItem
	for i, tod := range []string{
		"morning", "morning", "morning",
		"afternoon", "afternoon", "afternoon",
		"evening", "evening", "evening",
	} {
		items = append(items, store.ItineraryItem{
			ID: uuid.New(), Name: fmt.Sprintf("A%d", i), Day: i32p(1), TimeOfDay: strp(tod)})
	}
	// A second, lighter day so the packed finding still earns its move fix.
	items = append(items, store.ItineraryItem{ID: uuid.New(), Name: "B", Day: i32p(2)})
	fs := checkDensity("en", exportData{Trip: store.Trip{ID: uuid.New()}, Items: items})
	var forDay1 []Finding
	for _, f := range fs {
		if f.Day != nil && *f.Day == 1 {
			forDay1 = append(forDay1, f)
		}
	}
	if len(forDay1) != 1 {
		t.Fatalf("a packed day should emit exactly one finding, got %+v", forDay1)
	}
	if !strings.Contains(forDay1[0].Message, "too packed") {
		t.Fatalf("the one finding should be the packed-day one, got %q", forDay1[0].Message)
	}
}

func TestCheckDensity_EmptyDayRuns(t *testing.T) {
	items := []store.ItineraryItem{
		{ID: uuid.New(), Name: "A", Day: i32p(1)},
		// days 2-4 empty
		{ID: uuid.New(), Name: "B", Day: i32p(5)},
		// day 6 empty
		{ID: uuid.New(), Name: "C", Day: i32p(7)},
	}
	fs := checkDensity("en", exportData{Trip: store.Trip{ID: uuid.New()}, Items: items})
	if len(fs) != 2 {
		t.Fatalf("expected two empty-day findings (one per run), got %+v", fs)
	}
	if fs[0].Day == nil || *fs[0].Day != 2 || fs[0].Message != "Days 2–4 have nothing planned." {
		t.Fatalf("multi-day run = %+v", fs[0])
	}
	if fs[1].Day == nil || *fs[1].Day != 6 || fs[1].Message != "Day 6 has nothing planned." {
		t.Fatalf("single-day run = %+v", fs[1])
	}
}

// walkDayCoverage is the ONE definition of "a planned day" — Trip Health's
// empty-day findings, the ladder's rung 4 and that rung's tally all read it, so
// they cannot disagree about what counts.
func TestWalkDayCoverage(t *testing.T) {
	// 2026-09-01 → 09-05 is a 5-day span, so 4 plannable days (you fly home on
	// the 5th and there is nothing to plan on it).
	trip := store.Trip{ID: uuid.New(),
		StartDate: dateVal(t, "2026-09-01"), EndDate: dateVal(t, "2026-09-05")}

	t.Run("city fillers are not content", func(t *testing.T) {
		cov := walkDayCoverage(exportData{Trip: trip, Items: []store.ItineraryItem{
			{ID: uuid.New(), Name: "Prague", City: strp("Prague"), Day: i32p(1)},
			{ID: uuid.New(), Name: "Prague", City: strp("Prague"), Day: i32p(2)},
		}})
		if cov.Planned != 0 || cov.Total != 4 {
			t.Fatalf("coverage = %d of %d, want 0 of 4", cov.Planned, cov.Total)
		}
		if len(cov.Empty) != 1 || cov.Empty[0].first != 1 || cov.Empty[0].last != 4 {
			t.Fatalf("empty runs = %+v, want one run covering 1–4", cov.Empty)
		}
	})

	t.Run("the departure day is never empty", func(t *testing.T) {
		// Days 1–4 covered; day 5 (departure) is deliberately outside the span.
		var items []store.ItineraryItem
		for day := 1; day <= 4; day++ {
			items = append(items, store.ItineraryItem{
				ID: uuid.New(), Name: "Museum", City: strp("Prague"), Day: i32p(int32(day))})
		}
		cov := walkDayCoverage(exportData{Trip: trip, Items: items})
		if cov.Planned != 4 || cov.Total != 4 || len(cov.Empty) != 0 {
			t.Fatalf("coverage = %d of %d, empty %+v, want a clean 4 of 4",
				cov.Planned, cov.Total, cov.Empty)
		}
	})

	t.Run("real segments fill their travel days, drafts do not", func(t *testing.T) {
		d := exportData{Trip: trip, Items: []store.ItineraryItem{
			{ID: uuid.New(), Name: "Museum", City: strp("Prague"), Day: i32p(1)},
		}}
		d.Segments = []store.TripSegment{{ID: uuid.New(), Mode: "train",
			DepartDate: dateVal(t, "2026-09-02"), ArriveDate: dateVal(t, "2026-09-03")}}
		if cov := walkDayCoverage(d); cov.Planned != 3 {
			t.Fatalf("planned = %d, want 3 (day 1 + the two travel days)", cov.Planned)
		}
		d.Segments[0].Auto = true
		if cov := walkDayCoverage(d); cov.Planned != 1 {
			t.Fatalf("an itinerary-seeded draft must not fill a day: %+v", cov)
		}
		d.Segments[0].Auto, d.Segments[0].Dismissed = false, true
		if cov := walkDayCoverage(d); cov.Planned != 1 {
			t.Fatalf("a dismissed segment must not fill a day: %+v", cov)
		}
	})

	t.Run("undated trips keep the item window and report no denominator", func(t *testing.T) {
		cov := walkDayCoverage(exportData{
			Trip: store.Trip{ID: uuid.New()},
			Items: []store.ItineraryItem{
				{ID: uuid.New(), Name: "A", Day: i32p(1)},
				{ID: uuid.New(), Name: "C", Day: i32p(3)},
			}})
		if cov.Total != 0 {
			t.Fatalf("total = %d, want 0 — an undated trip has no honest span", cov.Total)
		}
		if len(cov.Empty) != 1 || cov.Empty[0].first != 2 || cov.Empty[0].last != 2 {
			t.Fatalf("empty runs = %+v, want just day 2", cov.Empty)
		}
	})
}

func TestCheckLodging_GateAndCoverage(t *testing.T) {
	trip := store.Trip{ID: uuid.New(),
		StartDate: dateVal(t, "2026-08-01"), EndDate: dateVal(t, "2026-08-04")} // 3 nights: 1,2,3

	// Dated trip, no accommodations → one finding covering the whole 3-night run.
	fs := checkLodging("en", exportData{Trip: trip})
	if len(fs) != 1 {
		t.Fatalf("planned no-lodging = %d findings, want 1 grouped run: %+v", len(fs), fs)
	}
	if fs[0].Day == nil || *fs[0].Day != 1 {
		t.Fatalf("grouped run should anchor on Day 1, got %+v", fs[0])
	}
	if !strings.Contains(fs[0].Message, "Sat, Aug 1 – Mon, Aug 3 (3 nights)") {
		t.Fatalf("grouped message = %q", fs[0].Message)
	}
	if fix := fs[0].Fix; fix == nil || *fix.CheckIn != "2026-08-01" || *fix.CheckOut != "2026-08-04" {
		t.Fatalf("grouped fix should span the run, got %+v", fs[0].Fix)
	}

	// One stay covering nights 1-2 (checkout 08-03, exclusive) → only night 3 flagged.
	acc := []store.Accommodation{{ID: uuid.New(), Name: "Hotel",
		CheckIn: dateVal(t, "2026-08-01"), CheckOut: dateVal(t, "2026-08-03")}}
	fs = checkLodging("en", exportData{Trip: trip, Accommodations: acc})
	if len(fs) != 1 || fs[0].Day == nil || *fs[0].Day != 3 {
		t.Fatalf("partial lodging = %+v", fs)
	}
	if !strings.Contains(fs[0].Message, "the night of") {
		t.Fatalf("single-night run should keep the singular message, got %q", fs[0].Message)
	}

	// An auto draft is a suggestion, not lodging — it must not mask the
	// uncovered-nights finding even when it "covers" every night.
	autoAcc := []store.Accommodation{{ID: uuid.New(), Name: "Suggested stay", Auto: true,
		CheckIn: dateVal(t, "2026-08-01"), CheckOut: dateVal(t, "2026-08-04")}}
	fs = checkLodging("en", exportData{Trip: trip, Accommodations: autoAcc})
	if len(fs) != 1 || fs[0].Day == nil || *fs[0].Day != 1 {
		t.Fatalf("auto draft masked the lodging gap: %+v", fs)
	}

	// An undated trip is silent — the dates guard is the only gate
	// (specs/retire-trip-status).
	if fs := checkLodging("en", exportData{Trip: store.Trip{ID: uuid.New()}}); len(fs) != 0 {
		t.Fatalf("undated trip should be silent, got %+v", fs)
	}
}

// A stay row the traveler TICKED is lodging, even with no accommodation row
// behind it — that is what "booked elsewhere, details not entered here" looks
// like, and answering "No lodging booked" to it contradicts the checklist on
// the same screen. Ticking the box is the assertion; the row's existence is
// not.
func TestCheckLodging_CheckedStayTodoCoversItsNights(t *testing.T) {
	trip := store.Trip{ID: uuid.New(),
		StartDate: dateVal(t, "2026-08-01"), EndDate: dateVal(t, "2026-08-04")} // nights 1,2,3

	stayTodo := func(booked bool, in, out string) store.BookingTodo {
		td := store.BookingTodo{ID: uuid.New(), Kind: "stay",
			TodoKey: "stay:amsterdam", Title: "Stay in Amsterdam", Booked: booked, Auto: true}
		if in != "" {
			td.DepartDate, td.ReturnDate = dateVal(t, in), dateVal(t, out)
		}
		return td
	}

	// Booked, spanning nights 1-2 (checkout 08-03, exclusive) → only night 3 left.
	fs := checkLodging("en", exportData{Trip: trip,
		BookingTodos: []store.BookingTodo{stayTodo(true, "2026-08-01", "2026-08-03")}})
	if len(fs) != 1 || fs[0].Day == nil || *fs[0].Day != 3 {
		t.Fatalf("checked stay should cover nights 1-2, got %+v", fs)
	}

	// Booked across the whole trip → silent.
	fs = checkLodging("en", exportData{Trip: trip,
		BookingTodos: []store.BookingTodo{stayTodo(true, "2026-08-01", "2026-08-04")}})
	if len(fs) != 0 {
		t.Fatalf("a checked stay spanning the trip should silence the check, got %+v", fs)
	}

	// UNCHECKED, same dates → every night still flagged. The row alone is the
	// app's own suggestion, not a booking.
	fs = checkLodging("en", exportData{Trip: trip,
		BookingTodos: []store.BookingTodo{stayTodo(false, "2026-08-01", "2026-08-04")}})
	if len(fs) != 1 || fs[0].Day == nil || *fs[0].Day != 1 {
		t.Fatalf("an unchecked stay row must not cover anything, got %+v", fs)
	}

	// Checked but DATELESS → covers nothing; we cannot know which nights.
	fs = checkLodging("en", exportData{Trip: trip,
		BookingTodos: []store.BookingTodo{stayTodo(true, "", "")}})
	if len(fs) != 1 || fs[0].Day == nil || *fs[0].Day != 1 {
		t.Fatalf("a dateless stay row covers no specific night, got %+v", fs)
	}

	// A transport row never counts as a bed, however it is dated or ticked.
	flight := store.BookingTodo{ID: uuid.New(), Kind: "transport",
		TodoKey: "transport:@home>>amsterdam", Title: "ALB → Amsterdam", Booked: true,
		DepartDate: dateVal(t, "2026-08-01"), ReturnDate: dateVal(t, "2026-08-04")}
	fs = checkLodging("en", exportData{Trip: trip, BookingTodos: []store.BookingTodo{flight}})
	if len(fs) != 1 || fs[0].Day == nil || *fs[0].Day != 1 {
		t.Fatalf("a transport row is not lodging, got %+v", fs)
	}

	// A CUSTOM row the traveler added by hand carries kind but no "stay:" key
	// (booking_todo_handler mints "custom:<uuid>"), which is why the filter is
	// kind and not the key prefix.
	custom := store.BookingTodo{ID: uuid.New(), Kind: "stay",
		TodoKey: "custom:" + uuid.NewString(), Title: "Hotel Ibis", Booked: true,
		DepartDate: dateVal(t, "2026-08-01"), ReturnDate: dateVal(t, "2026-08-04")}
	if fs := checkLodging("en", exportData{Trip: trip,
		BookingTodos: []store.BookingTodo{custom}}); len(fs) != 0 {
		t.Fatalf("a checked custom stay should cover its nights, got %+v", fs)
	}
}

func TestCheckLodging_GroupsRuns(t *testing.T) {
	// gap–covered–gap: 5 nights, a stay covers only night 3 → two range runs.
	trip := store.Trip{ID: uuid.New(),
		StartDate: dateVal(t, "2026-08-01"), EndDate: dateVal(t, "2026-08-06")} // nights 1-5
	acc := []store.Accommodation{{ID: uuid.New(), Name: "Hotel",
		CheckIn: dateVal(t, "2026-08-03"), CheckOut: dateVal(t, "2026-08-04")}} // covers night 3
	fs := checkLodging("en", exportData{Trip: trip, Accommodations: acc})
	if len(fs) != 2 {
		t.Fatalf("gap-covered-gap = %d findings, want 2: %+v", len(fs), fs)
	}
	if *fs[0].Day != 1 || *fs[0].Fix.CheckIn != "2026-08-01" || *fs[0].Fix.CheckOut != "2026-08-03" {
		t.Fatalf("first run = day %d fix %+v", *fs[0].Day, fs[0].Fix)
	}
	if *fs[1].Day != 4 || *fs[1].Fix.CheckIn != "2026-08-04" || *fs[1].Fix.CheckOut != "2026-08-06" {
		t.Fatalf("second run = day %d fix %+v", *fs[1].Day, fs[1].Fix)
	}

	// A city change splits the run so each fix prefills a single place.
	twoCity := store.Trip{ID: uuid.New(),
		StartDate: dateVal(t, "2026-08-01"), EndDate: dateVal(t, "2026-08-05")} // nights 1-4
	items := []store.ItineraryItem{
		{ID: uuid.New(), Name: "Colosseum", City: strp("Rome"), Day: i32p(1)},
		{ID: uuid.New(), Name: "Forum", City: strp("Rome"), Day: i32p(2)},
		{ID: uuid.New(), Name: "Duomo", City: strp("Florence"), Day: i32p(3)},
		{ID: uuid.New(), Name: "Uffizi", City: strp("Florence"), Day: i32p(4)},
	}
	fs = checkLodging("en", exportData{Trip: twoCity, Items: items})
	if len(fs) != 2 {
		t.Fatalf("city split = %d findings, want 2: %+v", len(fs), fs)
	}
	if *fs[0].Fix.City != "Rome" || *fs[0].Fix.CheckIn != "2026-08-01" || *fs[0].Fix.CheckOut != "2026-08-03" {
		t.Fatalf("Rome run fix = %+v", fs[0].Fix)
	}
	if *fs[1].Fix.City != "Florence" || *fs[1].Fix.CheckIn != "2026-08-03" || *fs[1].Fix.CheckOut != "2026-08-05" {
		t.Fatalf("Florence run fix = %+v", fs[1].Fix)
	}

	// Unknown-city nights never split a run; the run adopts the first known city.
	adopt := store.Trip{ID: uuid.New(),
		StartDate: dateVal(t, "2026-08-01"), EndDate: dateVal(t, "2026-08-04")} // nights 1-3
	fs = checkLodging("en", exportData{Trip: adopt, Items: []store.ItineraryItem{
		{ID: uuid.New(), Name: "Vatican", City: strp("Rome"), Day: i32p(2)}, // days 1 and 3 have no items
	}})
	if len(fs) != 1 || fs[0].Fix.City == nil || *fs[0].Fix.City != "Rome" {
		t.Fatalf("nil-city adoption = %+v", fs)
	}
}

func TestCheckLodging_RangeSpanish(t *testing.T) {
	trip := store.Trip{ID: uuid.New(),
		StartDate: dateVal(t, "2026-08-01"), EndDate: dateVal(t, "2026-08-04")} // 3 nights
	fs := checkLodging("es", exportData{Trip: trip})
	if len(fs) != 1 {
		t.Fatalf("es grouped run = %+v", fs)
	}
	if !strings.Contains(fs[0].Message, " al ") || !strings.Contains(fs[0].Message, "(3 noches)") {
		t.Fatalf("es range message = %q", fs[0].Message)
	}
}

func TestCheckTransit_MissingLeg(t *testing.T) {
	trip := store.Trip{ID: uuid.New()}
	items := []store.ItineraryItem{
		{ID: uuid.New(), Name: "Colosseum", City: strp("Rome"), Day: i32p(1)},
		{ID: uuid.New(), Name: "Duomo", City: strp("Florence"), Day: i32p(2)},
	}
	// No segments → missing Rome→Florence leg.
	fs := checkTransit("en", exportData{Trip: trip, Items: items})
	if len(fs) != 1 || fs[0].Category != "transit" {
		t.Fatalf("missing leg = %+v", fs)
	}
	// A connecting segment suppresses it.
	segs := []store.TripSegment{{ID: uuid.New(), Mode: "train",
		Origin: strp("Rome"), Destination: strp("Florence")}}
	if fs := checkTransit("en", exportData{Trip: trip, Items: items, Segments: segs}); len(fs) != 0 {
		t.Fatalf("connected legs should be silent, got %+v", fs)
	}
}

// Lodging's rule, applied to legs: a transport row the traveler ticked off is
// booked, whether or not they also entered the segment here.
func TestCheckTransit_CheckedTransportTodoCoversItsLeg(t *testing.T) {
	trip := store.Trip{ID: uuid.New()}
	items := []store.ItineraryItem{
		{ID: uuid.New(), Name: "Colosseum", City: strp("Rome"), Day: i32p(1)},
		{ID: uuid.New(), Name: "Duomo", City: strp("Florence"), Day: i32p(2)},
	}
	leg := func(booked bool, key, title string) store.BookingTodo {
		return store.BookingTodo{ID: uuid.New(), Kind: "transport",
			TodoKey: key, Title: title, Booked: booked, Auto: true}
	}

	if fs := checkTransit("en", exportData{Trip: trip, Items: items,
		BookingTodos: []store.BookingTodo{leg(true, "transport:rome>>florence", "Rome → Florence")},
	}); len(fs) != 0 {
		t.Fatalf("a checked leg should be silent, got %+v", fs)
	}

	// Unchecked → the row is the app's own suggestion, and the gap stands.
	if fs := checkTransit("en", exportData{Trip: trip, Items: items,
		BookingTodos: []store.BookingTodo{leg(false, "transport:rome>>florence", "Rome → Florence")},
	}); len(fs) != 1 {
		t.Fatalf("an unchecked leg must not cover anything, got %+v", fs)
	}

	// DIRECTIONAL, unlike segmentConnects: 00064 made a derived leg's direction
	// load-bearing, so a booked return must not silence the outbound.
	if fs := checkTransit("en", exportData{Trip: trip, Items: items,
		BookingTodos: []store.BookingTodo{leg(true, "transport:florence>>rome", "Florence → Rome")},
	}); len(fs) != 1 {
		t.Fatalf("the booked RETURN must not cover the outbound, got %+v", fs)
	}

	// A stay row is not transport, however it is titled.
	if fs := checkTransit("en", exportData{Trip: trip, Items: items,
		BookingTodos: []store.BookingTodo{{ID: uuid.New(), Kind: "stay",
			TodoKey: "stay:rome", Title: "Rome → Florence", Booked: true}},
	}); len(fs) != 1 {
		t.Fatalf("a stay row is not a leg, got %+v", fs)
	}
}

func TestCheckBudget_OverBudget(t *testing.T) {
	over := -50.0
	br := &BudgetResponse{Currency: "USD", Spent: 150, Remaining: &over}
	fs := checkBudget("en", exportData{Trip: store.Trip{ID: uuid.New()}}, br)
	if len(fs) != 1 || fs[0].Category != "budget" || fs[0].Severity != "warn" {
		t.Fatalf("over budget = %+v", fs)
	}
	within := 10.0
	if fs := checkBudget("en", exportData{Trip: store.Trip{ID: uuid.New()}}, &BudgetResponse{Remaining: &within}); len(fs) != 0 {
		t.Fatalf("within budget should be silent, got %+v", fs)
	}
	if fs := checkBudget("en", exportData{Trip: store.Trip{ID: uuid.New()}}, nil); len(fs) != 0 {
		t.Fatalf("no budget should be silent, got %+v", fs)
	}
}

func TestCheckBookings_Unbooked(t *testing.T) {
	d := exportData{
		Trip: store.Trip{ID: uuid.New()},
		Accommodations: []store.Accommodation{
			{ID: uuid.New(), Name: "Hotel", Booked: false},
			{ID: uuid.New(), Name: "Booked Inn", Booked: true},
			// Auto "Suggested" draft — a system suggestion, not a user booking.
			{ID: uuid.New(), Name: "Suggested Stay", Booked: false, Auto: true},
		},
		Segments: []store.TripSegment{
			{ID: uuid.New(), Mode: "flight", Origin: strp("JFK"), Destination: strp("CDG"), Booked: false},
			// Auto suggested segment — also skipped.
			{ID: uuid.New(), Mode: "train", Origin: strp("Rome"), Destination: strp("Florence"), Booked: false, Auto: true},
		},
	}
	fs := checkBookings("en", d)
	if len(fs) != 2 {
		t.Fatalf("expected 2 unbooked findings (auto drafts skipped), got %+v", fs)
	}
	for _, f := range fs {
		if f.Severity != "info" || f.Category != "bookings" || f.ItemID == nil {
			t.Fatalf("booking finding shape = %+v", f)
		}
		if strings.Contains(f.Message, "Suggested") {
			t.Fatalf("auto suggestion should not be flagged: %+v", f)
		}
	}
}

// weatherStub serves geocode + forecast/archive from one httptest server,
// echoing the requested date range with caller-chosen conditions.
func weatherStub(t *testing.T, rainy bool, tempMax, tempMin float64) *WeatherService {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/search"):
			fmt.Fprint(w, `{"results":[{"name":"Paris","country":"France","latitude":48.85,"longitude":2.35}]}`)
		case strings.HasPrefix(r.URL.Path, "/v1/forecast"), strings.HasPrefix(r.URL.Path, "/v1/archive"):
			q := r.URL.Query()
			start, _ := time.Parse(dateLayout, q.Get("start_date"))
			end, _ := time.Parse(dateLayout, q.Get("end_date"))
			forecast := strings.HasPrefix(r.URL.Path, "/v1/forecast")
			prob := 5
			psum := 0.0
			if rainy {
				prob, psum = 85, 9.0
			}
			var times, tmax, tmin, sum, pr []string
			for dt := start; !dt.After(end); dt = dt.AddDate(0, 0, 1) {
				times = append(times, `"`+dt.Format(dateLayout)+`"`)
				tmax = append(tmax, fmt.Sprintf("%f", tempMax))
				tmin = append(tmin, fmt.Sprintf("%f", tempMin))
				sum = append(sum, fmt.Sprintf("%f", psum))
				pr = append(pr, fmt.Sprintf("%d", prob))
			}
			out := fmt.Sprintf(`{"daily":{"time":[%s],"temperature_2m_max":[%s],"temperature_2m_min":[%s],"precipitation_sum":[%s]`,
				strings.Join(times, ","), strings.Join(tmax, ","), strings.Join(tmin, ","), strings.Join(sum, ","))
			if forecast {
				out += fmt.Sprintf(`,"precipitation_probability_mean":[%s]`, strings.Join(pr, ","))
			}
			out += "}}"
			fmt.Fprint(w, out)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	s := NewWeatherService()
	s.GeocodeBaseURL = srv.URL
	s.ForecastBaseURL = srv.URL
	s.ArchiveBaseURL = srv.URL
	return s
}

func TestCheckWeather_RainyOutdoorDay(t *testing.T) {
	// A dated future trip so the forecast path is used; day 1 has an outdoor
	// attraction in Paris.
	start := time.Now().AddDate(0, 0, 3)
	trip := store.Trip{ID: uuid.New(),
		StartDate: pgtype.Date{Time: start.Truncate(24 * time.Hour), Valid: true},
		EndDate:   pgtype.Date{Time: start.AddDate(0, 0, 1).Truncate(24 * time.Hour), Valid: true}}
	items := []store.ItineraryItem{
		{ID: uuid.New(), Name: "Eiffel Tower", City: strp("Paris"), Category: strp("attraction"), Day: i32p(1)},
	}
	d := exportData{Trip: trip, Items: items}

	weather := weatherStub(t, true, 22, 14) // rainy, mild
	fs := checkWeather(context.Background(), "en", d, weather)
	var gotRain bool
	for _, f := range fs {
		if f.Category != "weather" || f.Severity != "info" {
			t.Fatalf("weather finding shape = %+v", f)
		}
		if strings.Contains(f.Message, "umbrella") && f.Day != nil && *f.Day == 1 {
			gotRain = true
		}
	}
	if !gotRain {
		t.Fatalf("expected a Day 1 umbrella finding, got %+v", fs)
	}

	// Indoor-only day: same rain, but a museum → no umbrella nag.
	indoor := exportData{Trip: trip, Items: []store.ItineraryItem{
		{ID: uuid.New(), Name: "Louvre", City: strp("Paris"), Category: strp("museum"), Day: i32p(1)},
	}}
	for _, f := range checkWeather(context.Background(), "en", indoor, weather) {
		if strings.Contains(f.Message, "umbrella") {
			t.Fatalf("indoor day should not get an umbrella finding: %+v", f)
		}
	}

	// Nil service is a silent no-op.
	if fs := checkWeather(context.Background(), "en", d, nil); len(fs) != 0 {
		t.Fatalf("nil weather service should yield no findings, got %+v", fs)
	}
}

func TestCheckWeather_HotDay(t *testing.T) {
	start := time.Now().AddDate(0, 0, 3)
	trip := store.Trip{ID: uuid.New(),
		StartDate: pgtype.Date{Time: start.Truncate(24 * time.Hour), Valid: true},
		EndDate:   pgtype.Date{Time: start.Truncate(24 * time.Hour), Valid: true}}
	d := exportData{Trip: trip, Items: []store.ItineraryItem{
		{ID: uuid.New(), Name: "Louvre", City: strp("Paris"), Category: strp("museum"), Day: i32p(1)},
	}}
	weather := weatherStub(t, false, 37, 26) // hot, dry
	var gotHot bool
	for _, f := range checkWeather(context.Background(), "en", d, weather) {
		if strings.Contains(f.Message, "very hot") {
			gotHot = true
		}
	}
	if !gotHot {
		t.Fatal("expected a 'very hot' weather finding")
	}
}

// placesDouble builds a GooglePlacesService whose HTTP client answers every
// request from one canned body (via the shared countingTransport), counting
// billable calls so checkHours can be exercised without real Google.
func placesDouble(t *testing.T, body string) (*GooglePlacesService, *countingTransport) {
	t.Helper()
	rt := &countingTransport{body: body}
	svc := NewGooglePlacesService()
	svc.APIKey = "test-key"
	svc.Client = &http.Client{Transport: rt}
	return svc, rt
}

// closedMondayDetailsJSON: place open Tue–Sun, closed Monday.
const closedMondayDetailsJSON = `{"status":"OK","result":{"place_id":"p1","name":"Musée Rodin","formatted_address":"Paris","geometry":{"location":{"lat":48.85,"lng":2.31}},"types":["museum"],"opening_hours":{"open_now":false,"weekday_text":["Monday: Closed","Tuesday: 10:00 AM – 6:30 PM","Wednesday: 10:00 AM – 6:30 PM","Thursday: 10:00 AM – 6:30 PM","Friday: 10:00 AM – 6:30 PM","Saturday: 10:00 AM – 6:30 PM","Sunday: 10:00 AM – 6:30 PM"]}}}`

func TestCheckHours_ClosedOnScheduledWeekday(t *testing.T) {
	// 2026-08-03 is a Monday; the item scheduled to Day 1 lands on it.
	monday := dateVal(t, "2026-08-03")
	if monday.Time.Weekday() != time.Monday {
		t.Fatalf("fixture date is %s, expected Monday", monday.Time.Weekday())
	}
	trip := store.Trip{ID: uuid.New(),
		StartDate: monday, EndDate: dateVal(t, "2026-08-04")}
	items := []store.ItineraryItem{
		{ID: uuid.New(), Name: "Musée Rodin", PlaceID: strp("p1"), Day: i32p(1)},
		{ID: uuid.New(), Name: "No PlaceID", Day: i32p(1)}, // skipped (no place_id)
	}
	d := exportData{Trip: trip, Items: items}

	svc, rt := placesDouble(t, closedMondayDetailsJSON)
	fs := checkHours(context.Background(), "en", d, svc)
	if len(fs) != 1 || fs[0].Category != "hours" || fs[0].Severity != "warn" {
		t.Fatalf("expected one closed-weekday warn, got %+v", fs)
	}
	if !strings.Contains(fs[0].Message, "closed on Monday") {
		t.Fatalf("message = %q", fs[0].Message)
	}
	if rt.calls != 1 {
		t.Fatalf("expected exactly 1 place-details call (item without place_id skipped), got %d", rt.calls)
	}

	// Nil service is a silent no-op.
	if fs := checkHours(context.Background(), "en", d, nil); len(fs) != 0 {
		t.Fatalf("nil places service should yield no findings, got %+v", fs)
	}
}

func TestReviewTrip_CheckHoursGate(t *testing.T) {
	monday := dateVal(t, "2026-08-03")
	trip := store.Trip{ID: uuid.New(),
		StartDate: monday, EndDate: dateVal(t, "2026-08-04")}
	d := exportData{Trip: trip, Items: []store.ItineraryItem{
		{ID: uuid.New(), Name: "Musée Rodin", PlaceID: strp("p1"), Day: i32p(1)},
	}}
	svc, rt := placesDouble(t, closedMondayDetailsJSON)
	deps := reviewDeps{Places: svc}

	// CheckHours=false → the hours check never runs (no Google call, no hours finding).
	for _, f := range reviewTrip(context.Background(), "en", d, reviewOptions{CheckHours: false}, deps) {
		if f.Category == "hours" {
			t.Fatalf("hours finding leaked with CheckHours=false: %+v", f)
		}
	}
	if rt.calls != 0 {
		t.Fatalf("CheckHours=false must not call Google, got %d calls", rt.calls)
	}

	// CheckHours=true → the finding appears.
	var gotHours bool
	for _, f := range reviewTrip(context.Background(), "en", d, reviewOptions{CheckHours: true}, deps) {
		if f.Category == "hours" {
			gotHours = true
		}
	}
	if !gotHours {
		t.Fatal("expected an hours finding with CheckHours=true")
	}
}

// --- structured fix descriptors (Wave 19 PR1) --------------------------------

func TestFix_Lodging(t *testing.T) {
	trip := store.Trip{ID: uuid.New(),
		StartDate: dateVal(t, "2026-08-01"), EndDate: dateVal(t, "2026-08-04")} // nights 1,2,3
	// One stay covering nights 1-2 → only night 3 (Day 3 = 2026-08-03) flagged.
	acc := []store.Accommodation{{ID: uuid.New(), Name: "Hotel",
		CheckIn: dateVal(t, "2026-08-01"), CheckOut: dateVal(t, "2026-08-03")}}
	items := []store.ItineraryItem{
		{ID: uuid.New(), Name: "Beach", City: strp("Nice"), Day: i32p(3)},
	}
	fs := checkLodging("en", exportData{Trip: trip, Accommodations: acc, Items: items})
	if len(fs) != 1 || fs[0].Fix == nil {
		t.Fatalf("expected one lodging finding with a fix, got %+v", fs)
	}
	fix := fs[0].Fix
	if fix.Action != "add_lodging" || fix.CheckIn == nil || fix.CheckOut == nil {
		t.Fatalf("lodging fix = %+v", fix)
	}
	if *fix.CheckIn != "2026-08-03" || *fix.CheckOut != "2026-08-04" {
		t.Fatalf("check_in/out = %q/%q, want 2026-08-03/2026-08-04", *fix.CheckIn, *fix.CheckOut)
	}
	// check_out is exactly check_in + 1 day.
	ci, _ := time.Parse(dateLayout, *fix.CheckIn)
	co, _ := time.Parse(dateLayout, *fix.CheckOut)
	if co.Sub(ci) != 24*time.Hour {
		t.Fatalf("check_out is not check_in + 1 day: %v", co.Sub(ci))
	}
	if fix.City == nil || *fix.City != "Nice" {
		t.Fatalf("expected city Nice from the night's items, got %v", fix.City)
	}
}

func TestFix_LodgingRange(t *testing.T) {
	trip := store.Trip{ID: uuid.New(),
		StartDate: dateVal(t, "2026-08-01"), EndDate: dateVal(t, "2026-08-05")} // nights 1-4
	fs := checkLodging("en", exportData{Trip: trip})
	if len(fs) != 1 || fs[0].Fix == nil {
		t.Fatalf("expected one grouped lodging finding with a fix, got %+v", fs)
	}
	fix := fs[0].Fix
	// The fix spans the whole run: check_out = check_in + (nights × 24h).
	ci, _ := time.Parse(dateLayout, *fix.CheckIn)
	co, _ := time.Parse(dateLayout, *fix.CheckOut)
	if co.Sub(ci) != 4*24*time.Hour {
		t.Fatalf("fix span = %v, want 4 nights", co.Sub(ci))
	}
}

func TestFix_TransitGreekFerry(t *testing.T) {
	trip := store.Trip{ID: uuid.New(),
		StartDate: dateVal(t, "2026-08-01"), EndDate: dateVal(t, "2026-08-03")}
	items := []store.ItineraryItem{
		{ID: uuid.New(), Name: "Acropolis", City: strp("Athens"), Day: i32p(1)},
		{ID: uuid.New(), Name: "Portara", City: strp("Naxos"), Day: i32p(2)},
	}
	fs := checkTransit("en", exportData{Trip: trip, Items: items})
	if len(fs) != 1 || fs[0].Fix == nil {
		t.Fatalf("expected one transit finding with a fix, got %+v", fs)
	}
	fix := fs[0].Fix
	if fix.Action != "add_transport" || fix.Label != "Add ferry" {
		t.Fatalf("greek transit fix = %+v", fix)
	}
	if fix.Origin == nil || *fix.Origin != "Athens" || fix.Destination == nil || *fix.Destination != "Naxos" {
		t.Fatalf("origin/destination = %v/%v", fix.Origin, fix.Destination)
	}
	if fix.Mode == nil || *fix.Mode != "ferry" {
		t.Fatalf("expected ferry mode, got %v", fix.Mode)
	}
	// Destination hub's first day (Day 2 = start + 1) drives the leg date.
	if fix.Date == nil || *fix.Date != "2026-08-02" {
		t.Fatalf("transit date = %v, want 2026-08-02", fix.Date)
	}

	// Non-Greek pair → generic transport + flight, no forced ferry label.
	nonGreek := []store.ItineraryItem{
		{ID: uuid.New(), Name: "Colosseum", City: strp("Rome"), Day: i32p(1)},
		{ID: uuid.New(), Name: "Duomo", City: strp("Florence"), Day: i32p(2)},
	}
	gf := checkTransit("en", exportData{Trip: trip, Items: nonGreek})
	if len(gf) != 1 || gf[0].Fix == nil || gf[0].Fix.Label != "Add transport" ||
		gf[0].Fix.Mode == nil || *gf[0].Fix.Mode != "flight" {
		t.Fatalf("non-greek transit fix = %+v", gf)
	}
}

// A trip-level travel_mode steers the missing-transport fix away from the
// flight default; Greek island legs keep ferry and 'mixed' falls through.
func TestFix_TransitRespectsTravelMode(t *testing.T) {
	items := []store.ItineraryItem{
		{ID: uuid.New(), Name: "Whaling Museum", City: strp("Nantucket"), Day: i32p(1)},
		{ID: uuid.New(), Name: "Freedom Trail", City: strp("Boston"), Day: i32p(2)},
	}
	tripWith := func(mode *string) store.Trip {
		return store.Trip{ID: uuid.New(),
			StartDate: dateVal(t, "2026-08-01"), EndDate: dateVal(t, "2026-08-03"),
			TravelMode: mode}
	}

	fs := checkTransit("en", exportData{Trip: tripWith(strp("car")), Items: items})
	if len(fs) != 1 || fs[0].Fix == nil || fs[0].Fix.Label != "Add drive" ||
		fs[0].Fix.Mode == nil || *fs[0].Fix.Mode != "car" {
		t.Fatalf("car-trip transit fix = %+v", fs)
	}

	// mixed is not a segment mode → keeps the flight default.
	fs = checkTransit("en", exportData{Trip: tripWith(strp("mixed")), Items: items})
	if len(fs) != 1 || fs[0].Fix == nil || *fs[0].Fix.Mode != "flight" {
		t.Fatalf("mixed-trip transit fix = %+v", fs)
	}

	// Greek island pair stays ferry even on a car trip.
	greek := []store.ItineraryItem{
		{ID: uuid.New(), Name: "Acropolis", City: strp("Athens"), Day: i32p(1)},
		{ID: uuid.New(), Name: "Portara", City: strp("Naxos"), Day: i32p(2)},
	}
	fs = checkTransit("en", exportData{Trip: tripWith(strp("car")), Items: greek})
	if len(fs) != 1 || fs[0].Fix == nil || *fs[0].Fix.Mode != "ferry" {
		t.Fatalf("greek car-trip transit fix = %+v", fs)
	}
}

func TestFix_BookingsEntityType(t *testing.T) {
	d := exportData{
		Trip: store.Trip{ID: uuid.New()},
		Accommodations: []store.Accommodation{
			{ID: uuid.New(), Name: "Hotel", Booked: false},
		},
		Segments: []store.TripSegment{
			{ID: uuid.New(), Mode: "flight", Origin: strp("JFK"), Destination: strp("CDG"), Booked: false},
		},
	}
	fs := checkBookings("en", d)
	if len(fs) != 2 {
		t.Fatalf("expected 2 booking findings, got %+v", fs)
	}
	byEntity := map[string]*FindingFix{}
	for _, f := range fs {
		if f.Fix == nil || f.Fix.Action != "mark_booked" || f.Fix.EntityType == nil {
			t.Fatalf("booking fix shape = %+v", f.Fix)
		}
		if f.Fix.ItemID == nil || *f.Fix.ItemID != *f.ItemID {
			t.Fatalf("booking fix item_id should mirror the finding's: %+v", f)
		}
		byEntity[*f.Fix.EntityType] = f.Fix
	}
	if byEntity["accommodation"] == nil || byEntity["segment"] == nil {
		t.Fatalf("expected one accommodation and one segment fix, got %v", byEntity)
	}
}

func TestFix_DatesBeyondSpan(t *testing.T) {
	trip := store.Trip{ID: uuid.New(),
		StartDate: dateVal(t, "2026-08-01"), EndDate: dateVal(t, "2026-08-03")} // 3-day span
	id := uuid.New()
	items := []store.ItineraryItem{{ID: id, Name: "Way Out", Day: i32p(9)}}
	fs := checkDates("en", exportData{Trip: trip, Items: items})
	if len(fs) != 1 || fs[0].Fix == nil {
		t.Fatalf("expected one beyond-span finding with a fix, got %+v", fs)
	}
	fix := fs[0].Fix
	if fix.Action != "move_item" || fix.ItemID == nil || *fix.ItemID != id.String() {
		t.Fatalf("beyond-span fix = %+v", fix)
	}
	if fix.TargetDay == nil || *fix.TargetDay != 3 || *fix.TargetDay > 3 {
		t.Fatalf("target_day = %v, want 3 (within span)", fix.TargetDay)
	}
}

func TestFix_OverPacked_LighterDayAndNone(t *testing.T) {
	tripID := uuid.New()
	// Day 1 over-packed (7 items); Day 2 light (1 item) → the over-packed fix
	// moves the last Day-1 item to Day 2.
	var items []store.ItineraryItem
	var lastDay1 uuid.UUID
	for i := 0; i < 7; i++ {
		id := uuid.New()
		lastDay1 = id
		items = append(items, store.ItineraryItem{ID: id, Name: fmt.Sprintf("A%d", i), Day: i32p(1)})
	}
	items = append(items, store.ItineraryItem{ID: uuid.New(), Name: "B", Day: i32p(2)})
	fs := checkDensity("en", exportData{Trip: store.Trip{ID: tripID}, Items: items})
	var packed *Finding
	for i := range fs {
		if fs[i].Severity == "info" && strings.Contains(fs[i].Message, "too packed") {
			packed = &fs[i]
		}
	}
	if packed == nil || packed.Fix == nil {
		t.Fatalf("expected an over-packed info with a fix, got %+v", fs)
	}
	if packed.Fix.Action != "move_item" || packed.Fix.TargetDay == nil || *packed.Fix.TargetDay != 2 {
		t.Fatalf("over-packed fix = %+v", packed.Fix)
	}
	if packed.Fix.ItemID == nil || *packed.Fix.ItemID != lastDay1.String() {
		t.Fatalf("expected the last Day-1 item to move, got %v", packed.Fix.ItemID)
	}

	// No lighter day: Day 1 is the ONLY scheduled day (7 items) → fix stays nil.
	var solo []store.ItineraryItem
	for i := 0; i < 7; i++ {
		solo = append(solo, store.ItineraryItem{ID: uuid.New(), Name: fmt.Sprintf("C%d", i), Day: i32p(1)})
	}
	sf := checkDensity("en", exportData{Trip: store.Trip{ID: tripID}, Items: solo})
	for _, f := range sf {
		if strings.Contains(f.Message, "too packed") && f.Fix != nil {
			t.Fatalf("no lighter day exists — over-packed fix should be nil, got %+v", f.Fix)
		}
	}
}

func TestFix_WeatherRainAddPacking(t *testing.T) {
	start := time.Now().AddDate(0, 0, 3)
	trip := store.Trip{ID: uuid.New(),
		StartDate: pgtype.Date{Time: start.Truncate(24 * time.Hour), Valid: true},
		EndDate:   pgtype.Date{Time: start.AddDate(0, 0, 1).Truncate(24 * time.Hour), Valid: true}}
	d := exportData{Trip: trip, Items: []store.ItineraryItem{
		{ID: uuid.New(), Name: "Eiffel Tower", City: strp("Paris"), Category: strp("attraction"), Day: i32p(1)},
	}}
	weather := weatherStub(t, true, 22, 14)
	var gotFix bool
	for _, f := range checkWeather(context.Background(), "en", d, weather) {
		if strings.Contains(f.Message, "umbrella") {
			if f.Fix == nil || f.Fix.Action != "add_packing" ||
				f.Fix.PackingItem == nil || *f.Fix.PackingItem != "Umbrella" {
				t.Fatalf("rain fix = %+v", f.Fix)
			}
			gotFix = true
		}
	}
	if !gotFix {
		t.Fatal("expected a rain finding carrying an add_packing fix")
	}
}

func TestReviewTrip_CleanTripNoFindings(t *testing.T) {
	// A fully-covered, transport-connected, single-city dated trip with a booked
	// stay and no over-packing → zero findings (and a JSON "[]", not null).
	trip := store.Trip{ID: uuid.New(),
		StartDate: dateVal(t, "2026-08-01"), EndDate: dateVal(t, "2026-08-02")} // 1 night
	d := exportData{
		Trip: trip,
		Items: []store.ItineraryItem{
			{ID: uuid.New(), Name: "Louvre", City: strp("Paris"), Day: i32p(1)},
		},
		Accommodations: []store.Accommodation{{ID: uuid.New(), Name: "Hotel", Booked: true,
			CheckIn: dateVal(t, "2026-08-01"), CheckOut: dateVal(t, "2026-08-02")}},
	}
	fs := reviewTrip(context.Background(), "en", d, reviewOptions{}, reviewDeps{})
	if len(fs) != 0 {
		t.Fatalf("clean trip should have no findings, got %+v", fs)
	}
	if b, _ := json.Marshal(fs); string(b) != "[]" {
		t.Fatalf("expected JSON [], got %s", b)
	}
}

func TestReviewTrip_DeterministicOrder(t *testing.T) {
	trip := store.Trip{ID: uuid.New(),
		StartDate: dateVal(t, "2026-08-01"), EndDate: dateVal(t, "2026-08-03")}
	d := exportData{Trip: trip, Items: []store.ItineraryItem{
		{ID: uuid.New(), Name: "A"}, // unscheduled
	}}
	ja, _ := json.Marshal(reviewTrip(context.Background(), "en", d, reviewOptions{}, reviewDeps{}))
	jb, _ := json.Marshal(reviewTrip(context.Background(), "en", d, reviewOptions{}, reviewDeps{}))
	if string(ja) != string(jb) {
		t.Fatalf("nondeterministic order:\n%s\n%s", ja, jb)
	}
}

// spineTrip is the worked example from specs/shape-before-schedule: Sep 1-8,
// Lisbon / Porto / Madrid, one place on each city's arrival day and one on the
// day the traveler moves on — except Madrid, whose move-on day is the journey
// home. Days 2-3, 5 and 7 carry nothing; day 8 is the flight back.
func spineTrip(t *testing.T) exportData {
	t.Helper()
	return exportData{
		Trip: store.Trip{ID: uuid.New(),
			StartDate: dateVal(t, "2026-09-01"), EndDate: dateVal(t, "2026-09-08")},
		Items: []store.ItineraryItem{
			rlItem(0, "Time Out Market", rlCity("Lisbon"), 1),
			rlItem(1, "Pastéis de Belém", rlCity("Lisbon"), 4),
			rlItem(2, "Livraria Lello", rlCity("Porto"), 4),
			rlItem(3, "Cais da Ribeira", rlCity("Porto"), 6),
			rlItem(4, "Museo del Prado", rlCity("Madrid"), 6),
		},
	}
}

// The post-state half a spine makes load-bearing: which days are open, and in
// which city. The journey-home day must never appear — walkDayCoverage drops
// it, and that reuse is the only reason this can't offer to fill the day the
// traveler flies back.
func TestOpenDaysSummary(t *testing.T) {
	got := openDaysSummary(spineTrip(t))
	for _, want := range []string{
		"Days with nothing planned yet:",
		"days 2-3 in Lisbon",
		"day 5 in Porto",
		"day 7 in Madrid",
		"do NOT fill them in this turn",
	} {
		if !strings.Contains(got, want) {
			t.Fatalf("open-days summary missing %q:\n%s", want, got)
		}
	}
	// Day 8 is the journey home. It is not a plannable day and must not be
	// offered — the 2026-08-15 bug, reopened from the other side.
	if strings.Contains(got, "day 8") {
		t.Fatalf("the journey-home day was offered as open:\n%s", got)
	}
}

// A trip with every plannable day covered says nothing — so the note never
// becomes boilerplate on an ordinary dense itinerary.
func TestOpenDaysSummaryQuietWhenCovered(t *testing.T) {
	d := exportData{
		Trip: store.Trip{ID: uuid.New(),
			StartDate: dateVal(t, "2026-09-01"), EndDate: dateVal(t, "2026-09-03")},
		Items: []store.ItineraryItem{
			rlItem(0, "Time Out Market", rlCity("Lisbon"), 1),
			rlItem(1, "Pastéis de Belém", rlCity("Lisbon"), 2),
		},
	}
	if got := openDaysSummary(d); got != "" {
		t.Fatalf("a fully covered trip named open days:\n%s", got)
	}
}

// A travel day covered by a real transport segment is planned, so it is not an
// open day — the same rule walkDayCoverage applies to Trip Health.
func TestOpenDaysSummarySkipsSegmentDays(t *testing.T) {
	d := spineTrip(t)
	d.Segments = []store.TripSegment{
		{ID: uuid.New(), DepartDate: dateVal(t, "2026-09-05")},
	}
	if got := openDaysSummary(d); strings.Contains(got, "day 5") {
		t.Fatalf("a day carrying a real segment was called open:\n%s", got)
	}
}

// checkLegShape is the HUMAN channel for the failure the spine rests on not
// happening. Both cases are invisible everywhere else: the page draws no nights
// label below one night, and RenderLeg.ZeroNight has never had a consumer.
func TestCheckLegShape(t *testing.T) {
	// Arrival anchors only — Lisbon renders zero nights, Porto absorbs them.
	collapsed := exportData{
		Trip: store.Trip{ID: uuid.New(),
			StartDate: dateVal(t, "2026-09-01"), EndDate: dateVal(t, "2026-09-08")},
		Items: []store.ItineraryItem{
			rlItem(0, "Time Out Market", rlCity("Lisbon"), 1),
			rlItem(1, "Livraria Lello", rlCity("Porto"), 4),
		},
	}
	fs := checkLegShape("en", collapsed)
	if len(fs) != 1 {
		t.Fatalf("findings = %+v, want one", fs)
	}
	if fs[0].Severity != "warn" {
		t.Fatalf("severity = %q, want warn — this one has to reach the badge", fs[0].Severity)
	}
	if fs[0].Message != "Lisbon shows no nights — you arrive and leave on the same day." {
		t.Fatalf("message = %q", fs[0].Message)
	}

	// Undated places: the split was computed, not chosen.
	guessed := exportData{
		Trip: store.Trip{ID: uuid.New(),
			StartDate: dateVal(t, "2026-06-01"), EndDate: dateVal(t, "2026-06-08")},
		Items: []store.ItineraryItem{
			rlItem(0, "Louvre", rlCity("Paris"), 0),
			rlItem(1, "Colosseum", rlCity("Rome"), 0),
		},
	}
	if fs := checkLegShape("en", guessed); len(fs) != 2 {
		t.Fatalf("guessed-date findings = %+v, want one per leg", fs)
	}

	// A well-formed spine is silent, including its final leg — which ends on
	// the day the traveler flies home and is exempt by design.
	if fs := checkLegShape("en", spineTrip(t)); len(fs) != 0 {
		t.Fatalf("a well-formed spine raised findings: %+v", fs)
	}
}

// --- checkStaleTransport: the booking the route left behind ------------------
//
// The trigger shape: Naples inserted between Gothenburg and Sorrento. The legs
// below are exactly that sequence — the confirmed Gothenburg → Sorrento flight
// is the orphan.

// staleTransportFixture builds the post-edit leg sequence: Gothenburg (day 1,
// Sep 10) → Naples (day 4, Sep 13) → Sorrento (day 6, Sep 15) → Rome (day 8,
// Sep 17).
func staleTransportFixture(t *testing.T) exportData {
	return exportData{
		Trip: store.Trip{ID: uuid.New(),
			StartDate: dateVal(t, "2026-09-10"), EndDate: dateVal(t, "2026-09-18")},
		Items: []store.ItineraryItem{
			rlItem(1, "Gothenburg pin", rlCity("Gothenburg"), 1),
			rlItem(2, "Naples pin", rlCity("Naples"), 4),
			rlItem(3, "Sorrento pin", rlCity("Sorrento"), 6),
			rlItem(4, "Rome pin", rlCity("Rome"), 8),
		},
	}
}

func TestCheckStaleTransport_OrphanedConfirmedSegment(t *testing.T) {
	d := staleTransportFixture(t)
	seg := store.TripSegment{
		ID: uuid.New(), Mode: "flight", Booked: true,
		Origin: strp("Gothenburg"), Destination: strp("Sorrento"),
		DepartDate: dateVal(t, "2026-09-11"),
	}
	d.Segments = []store.TripSegment{seg}

	fs := checkStaleTransport("en", d)
	if len(fs) != 1 {
		t.Fatalf("findings = %+v, want the one orphan", fs)
	}
	f := fs[0]
	if f.Severity != "warn" || f.Category != "transit" {
		t.Fatalf("severity/category = %q/%q", f.Severity, f.Category)
	}
	if f.ItemID == nil || *f.ItemID != seg.ID.String() {
		t.Fatalf("finding must carry the row's id, got %+v", f.ItemID)
	}
	if !strings.Contains(f.Message, "Gothenburg → Sorrento") {
		t.Fatalf("finding must name the row, got %q", f.Message)
	}
	// The optional date signal: Sep 11 is outside both named legs' rendered
	// spans, so it rides along as evidence.
	if !strings.Contains(f.Message, "outside the current dates") {
		t.Fatalf("expected the date evidence in the message, got %q", f.Message)
	}
	if f.Fix == nil || f.Fix.Action != "fix_segment" {
		t.Fatalf("fix = %+v, want action fix_segment", f.Fix)
	}
	fix := f.Fix
	if fix.ItemID == nil || *fix.ItemID != seg.ID.String() ||
		fix.EntityType == nil || *fix.EntityType != "segment" {
		t.Fatalf("fix must identify the segment row, got %+v", fix)
	}
	if fix.Origin == nil || *fix.Origin != "Gothenburg" ||
		fix.Destination == nil || *fix.Destination != "Sorrento" ||
		fix.Date == nil || *fix.Date != "2026-09-11" ||
		fix.Mode == nil || *fix.Mode != "flight" {
		t.Fatalf("fix must carry the row's endpoints/date/mode, got %+v", fix)
	}
}

func TestCheckStaleTransport_ConnectedPairsSilent(t *testing.T) {
	d := staleTransportFixture(t)
	d.Segments = []store.TripSegment{
		{ID: uuid.New(), Mode: "flight", Origin: strp("Gothenburg"), Destination: strp("Naples")},
		{ID: uuid.New(), Mode: "train", Origin: strp("Naples"), Destination: strp("Sorrento")},
		// Either direction counts — a hand-entered segment may read backwards.
		{ID: uuid.New(), Mode: "train", Origin: strp("Rome"), Destination: strp("Sorrento")},
	}
	if fs := checkStaleTransport("en", d); len(fs) != 0 {
		t.Fatalf("connected segments flagged: %+v", fs)
	}
}

func TestCheckStaleTransport_DraftOrphanNotFlagged(t *testing.T) {
	d := staleTransportFixture(t)
	d.Segments = []store.TripSegment{{
		ID: uuid.New(), Mode: "flight", Auto: true,
		Origin: strp("Gothenburg"), Destination: strp("Sorrento"),
	}}
	if fs := checkStaleTransport("en", d); len(fs) != 0 {
		t.Fatalf("drafts are the resync's to prune — flagging double-reports: %+v", fs)
	}
}

func TestCheckStaleTransport_DismissedNotFlagged(t *testing.T) {
	d := staleTransportFixture(t)
	d.Segments = []store.TripSegment{{
		ID: uuid.New(), Mode: "flight", Dismissed: true,
		Origin: strp("Gothenburg"), Destination: strp("Sorrento"),
	}}
	if fs := checkStaleTransport("en", d); len(fs) != 0 {
		t.Fatalf("a dismissed row is already dealt with: %+v", fs)
	}
}

func TestCheckStaleTransport_NonLegPlaceNotFlagged(t *testing.T) {
	d := staleTransportFixture(t)
	d.Segments = []store.TripSegment{
		// The flight out from the home airport: ALB is no leg of this trip, so
		// this segment is none of the route's business.
		{ID: uuid.New(), Mode: "flight", Origin: strp("ALB"), Destination: strp("Gothenburg")},
		// Same for the flight home.
		{ID: uuid.New(), Mode: "flight", Origin: strp("Rome"), Destination: strp("EWR")},
		// A connection city.
		{ID: uuid.New(), Mode: "flight", Origin: strp("Frankfurt"), Destination: strp("Naples")},
	}
	if fs := checkStaleTransport("en", d); len(fs) != 0 {
		t.Fatalf("segments naming non-leg places must stay silent: %+v", fs)
	}
}

func TestCheckStaleTransport_OneOrNoLegs(t *testing.T) {
	seg := store.TripSegment{ID: uuid.New(), Mode: "flight",
		Origin: strp("Gothenburg"), Destination: strp("Sorrento")}

	noLegs := exportData{Trip: store.Trip{ID: uuid.New(),
		StartDate: dateVal(t, "2026-09-10"), EndDate: dateVal(t, "2026-09-18")},
		Segments: []store.TripSegment{seg}}
	if fs := checkStaleTransport("en", noLegs); len(fs) != 0 {
		t.Fatalf("no legs, no flags: %+v", fs)
	}

	oneLeg := exportData{Trip: store.Trip{ID: uuid.New(),
		StartDate: dateVal(t, "2026-09-10"), EndDate: dateVal(t, "2026-09-18")},
		Items:    []store.ItineraryItem{rlItem(1, "Rome pin", rlCity("Rome"), 1)},
		Segments: []store.TripSegment{seg}}
	if fs := checkStaleTransport("en", oneLeg); len(fs) != 0 {
		t.Fatalf("one leg, no flags (and no panic): %+v", fs)
	}
}

// The date signal is evidence, never a trigger: a confirmed segment can
// legitimately depart a day early, so a still-adjacent pair with an out-of-leg
// date stays silent.
func TestCheckStaleTransport_DateAloneNeverFires(t *testing.T) {
	d := staleTransportFixture(t)
	d.Segments = []store.TripSegment{{
		ID: uuid.New(), Mode: "flight",
		Origin: strp("Gothenburg"), Destination: strp("Naples"),
		// Sep 12 is outside both legs' one-day spans (Sep 10, Sep 13) — but the
		// pair is still adjacent, so there is nothing to flag.
		DepartDate: dateVal(t, "2026-09-12"),
	}}
	if fs := checkStaleTransport("en", d); len(fs) != 0 {
		t.Fatalf("an early departure on a connected pair must not flag: %+v", fs)
	}
}

func TestCheckStaleTransport_Spanish(t *testing.T) {
	d := staleTransportFixture(t)
	d.Segments = []store.TripSegment{{
		ID: uuid.New(), Mode: "flight",
		Origin: strp("Gothenburg"), Destination: strp("Sorrento"),
	}}
	fs := checkStaleTransport("es", d)
	if len(fs) != 1 || !strings.Contains(fs[0].Message, "ya no coincide con la ruta") {
		t.Fatalf("es finding = %+v", fs)
	}
}

// The check rides reviewTrip like every other — one call, both surfaces.
func TestReviewTrip_IncludesStaleTransport(t *testing.T) {
	d := staleTransportFixture(t)
	d.Segments = []store.TripSegment{{
		ID: uuid.New(), Mode: "flight",
		Origin: strp("Gothenburg"), Destination: strp("Sorrento"),
	}}
	fs := reviewTrip(context.Background(), "en", d, reviewOptions{}, reviewDeps{})
	found := false
	for _, f := range fs {
		if f.Fix != nil && f.Fix.Action == "fix_segment" {
			found = true
		}
	}
	if !found {
		t.Fatalf("reviewTrip lost the orphan finding: %+v", fs)
	}
}
