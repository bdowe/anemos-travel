package main

// print_view_test.go — DB-free unit tests for the day-by-day print packet
// builders (specs/print-travel-packet). Template escaping follows the
// share_preview_test.go pattern; weather uses the weatherStub seam from
// trip_review_test.go.

import (
	"bytes"
	"context"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

func printFixtureTrip(t *testing.T) store.Trip {
	t.Helper()
	return store.Trip{
		ID:        uuid.New(),
		Title:     "Greece",
		StartDate: dateVal(t, "2026-08-01"),
		EndDate:   dateVal(t, "2026-08-05"),
	}
}

func TestPrintDayCount(t *testing.T) {
	trip := printFixtureTrip(t)

	n, dated := printDayCount(exportData{Trip: trip})
	if n != 5 || !dated {
		t.Fatalf("5-day trip: got n=%d dated=%v", n, dated)
	}

	// An item day beyond the range extends the count.
	n, _ = printDayCount(exportData{Trip: trip, Items: []store.ItineraryItem{{Day: i32p(7)}}})
	if n != 7 {
		t.Fatalf("day-7 item should extend to 7, got %d", n)
	}

	// A runaway day number must not drag hollow sections with it — the range
	// stays at the trip's own length (the item lands in Unscheduled).
	n, _ = printDayCount(exportData{Trip: trip, Items: []store.ItineraryItem{{Day: i32p(5000)}}})
	if n != 5 {
		t.Fatalf("runaway day should not extend the range, got %d", n)
	}

	// An absurd trip date range still clamps.
	longTrip := store.Trip{StartDate: dateVal(t, "2026-08-01"), EndDate: dateVal(t, "2027-08-01")}
	n, _ = printDayCount(exportData{Trip: longTrip})
	if n != maxPrintDays {
		t.Fatalf("expected clamp to %d, got %d", maxPrintDays, n)
	}

	// Start date only ⇒ a single day.
	n, dated = printDayCount(exportData{Trip: store.Trip{StartDate: dateVal(t, "2026-08-01")}})
	if n != 1 || !dated {
		t.Fatalf("start-only trip: got n=%d dated=%v", n, dated)
	}

	// Undated: day count comes from item days alone.
	n, dated = printDayCount(exportData{Trip: store.Trip{}})
	if n != 0 || dated {
		t.Fatalf("undated empty trip: got n=%d dated=%v", n, dated)
	}
	n, dated = printDayCount(exportData{Trip: store.Trip{}, Items: []store.ItineraryItem{{Day: i32p(3)}}})
	if n != 3 || dated {
		t.Fatalf("undated with day-3 item: got n=%d dated=%v", n, dated)
	}
}

func TestBuildPrintDays_StayNights(t *testing.T) {
	d := exportData{
		Trip: printFixtureTrip(t),
		Accommodations: []store.Accommodation{{
			Name:    "Hotel Grande",
			CheckIn: dateVal(t, "2026-08-01"), CheckOut: dateVal(t, "2026-08-05"),
		}},
	}
	days, _, otherStays, _ := buildPrintDays("en", d, nil)
	if len(days) != 5 {
		t.Fatalf("expected 5 day sections, got %d", len(days))
	}
	if len(otherStays) != 0 {
		t.Fatalf("stay should attach to days, got otherStays=%+v", otherStays)
	}
	for i := 0; i < 4; i++ {
		if len(days[i].Stays) != 1 {
			t.Fatalf("day %d should have the stay, got %+v", i+1, days[i].Stays)
		}
	}
	if len(days[4].Stays) != 0 {
		t.Fatalf("stay must not appear on its check-out day, got %+v", days[4].Stays)
	}
	if !strings.Contains(days[0].Stays[0].Meta, "Check in today") {
		t.Fatalf("first night should note check-in, got %q", days[0].Stays[0].Meta)
	}
	wantCheckout := "Check out " + time.Date(2026, 8, 5, 0, 0, 0, 0, time.UTC).Format("Mon, Jan 2")
	if !strings.Contains(days[3].Stays[0].Meta, wantCheckout) {
		t.Fatalf("last night should note %q, got %q", wantCheckout, days[3].Stays[0].Meta)
	}
	if strings.Contains(days[1].Stays[0].Meta, "Check") {
		t.Fatalf("middle night should have no check note, got %q", days[1].Stays[0].Meta)
	}
}

func TestBuildPrintDays_StayEdgeCases(t *testing.T) {
	trip := printFixtureTrip(t)

	// Single-night stay: both notes on the one night.
	d := exportData{Trip: trip, Accommodations: []store.Accommodation{{
		Name: "One Night Inn", CheckIn: dateVal(t, "2026-08-02"), CheckOut: dateVal(t, "2026-08-03"),
	}}}
	days, _, _, _ := buildPrintDays("en", d, nil)
	if len(days[1].Stays) != 1 || len(days[0].Stays) != 0 || len(days[2].Stays) != 0 {
		t.Fatalf("single-night stay placement wrong: %+v", days)
	}
	meta := days[1].Stays[0].Meta
	if !strings.Contains(meta, "Check in today") || !strings.Contains(meta, "Check out") {
		t.Fatalf("single-night stay should carry both notes, got %q", meta)
	}

	// Check-in only ⇒ that night only.
	d = exportData{Trip: trip, Accommodations: []store.Accommodation{{
		Name: "Open Ended", CheckIn: dateVal(t, "2026-08-03"),
	}}}
	days, _, otherStays, _ := buildPrintDays("en", d, nil)
	if len(days[2].Stays) != 1 || len(otherStays) != 0 {
		t.Fatalf("check-in-only stay should land on its night: days=%+v other=%+v", days, otherStays)
	}

	// Entirely outside the trip range ⇒ reference list, with its date range.
	d = exportData{Trip: trip, Accommodations: []store.Accommodation{{
		Name: "Elsewhere", CheckIn: dateVal(t, "2026-09-01"), CheckOut: dateVal(t, "2026-09-03"),
	}}}
	days, _, otherStays, _ = buildPrintDays("en", d, nil)
	for i, day := range days {
		if len(day.Stays) != 0 {
			t.Fatalf("out-of-range stay leaked onto day %d", i+1)
		}
	}
	if len(otherStays) != 1 || !strings.Contains(otherStays[0].Meta, "Check-in") {
		t.Fatalf("out-of-range stay should be a reference entry, got %+v", otherStays)
	}

	// No dates at all ⇒ reference list.
	d = exportData{Trip: trip, Accommodations: []store.Accommodation{{Name: "Dateless"}}}
	_, _, otherStays, _ = buildPrintDays("en", d, nil)
	if len(otherStays) != 1 {
		t.Fatalf("dateless stay should be a reference entry, got %+v", otherStays)
	}
}

func TestBuildPrintDays_Segments(t *testing.T) {
	d := exportData{
		Trip: printFixtureTrip(t),
		Segments: []store.TripSegment{
			// Departs day 2, arrives day 3 ⇒ single entry on day 2.
			{Mode: "train", Origin: strp("Athens"), Destination: strp("Nafplio"),
				DepartDate: dateVal(t, "2026-08-02"), ArriveDate: dateVal(t, "2026-08-03"),
				Provider: strp("Hellenic Train"), PriceNote: strp("€25"), Booked: true},
			// Arrive-only ⇒ attaches to the arrival day.
			{Mode: "flight", Origin: strp("JFK"), Destination: strp("ATH"),
				ArriveDate: dateVal(t, "2026-08-01")},
			// No dates ⇒ reference list.
			{Mode: "ferry", Origin: strp("Piraeus"), Destination: strp("Hydra")},
			// Departs before the trip, arrives day 1 ⇒ arrival-day fallback.
			{Mode: "bus", Origin: strp("Sofia"), Destination: strp("Athens"),
				DepartDate: dateVal(t, "2026-07-31"), ArriveDate: dateVal(t, "2026-08-01")},
		},
	}
	days, _, _, otherSegs := buildPrintDays("en", d, nil)

	if len(days[1].Segments) != 1 {
		t.Fatalf("train should attach to day 2, got %+v", days[1].Segments)
	}
	seg := days[1].Segments[0]
	if !seg.Booked || !strings.Contains(seg.Meta, "Arrives") ||
		!strings.Contains(seg.Meta, "Hellenic Train") || !strings.Contains(seg.Meta, "€25") {
		t.Fatalf("train meta incomplete: %+v", seg)
	}
	if len(days[2].Segments) != 0 {
		t.Fatalf("train must not duplicate onto its arrival day")
	}
	if len(days[0].Segments) != 2 {
		t.Fatalf("day 1 should have the arrive-only flight and the fallback bus, got %+v", days[0].Segments)
	}
	if len(otherSegs) != 1 || otherSegs[0].Mode != "Ferry" {
		t.Fatalf("dateless ferry should be a reference entry, got %+v", otherSegs)
	}
}

func TestBuildPrintDays_ItemsAndDayTrips(t *testing.T) {
	d := exportData{
		Trip: printFixtureTrip(t),
		Items: []store.ItineraryItem{
			{Name: "Acropolis", City: strp("Athens"), Day: i32p(1), TimeOfDay: strp("morning")},
			// Day 2 is entirely a day trip: Delphi from Athens.
			{Name: "Temple of Apollo", City: strp("Delphi"), DayTripFrom: strp("Athens"), Day: i32p(2)},
			{Name: "Delphi Museum", City: strp("Delphi"), DayTripFrom: strp("Athens"), Day: i32p(2)},
			// Day 4 mixes a day-trip item with a local one ⇒ no day-trip label.
			{Name: "Cape Sounion", City: strp("Sounion"), DayTripFrom: strp("Athens"), Day: i32p(4)},
			{Name: "Plaka dinner", City: strp("Athens"), Day: i32p(4)},
			// No day ⇒ Unscheduled.
			{Name: "Someday Taverna", City: strp("Athens")},
			// Beyond the clamp ⇒ Unscheduled.
			{Name: "Runaway", City: strp("Athens"), Day: i32p(5000)},
		},
	}
	days, unscheduled, _, _ := buildPrintDays("en", d, nil)

	if len(days) != 5 {
		t.Fatalf("expected 5 days, got %d", len(days))
	}
	if days[0].Hub != "Athens" || days[0].DayTrip != "" {
		t.Fatalf("day 1 header wrong: %+v", days[0])
	}
	if days[1].Hub != "Delphi" || days[1].DayTrip != "Day trip from Athens" {
		t.Fatalf("day-trip day header wrong: hub=%q daytrip=%q", days[1].Hub, days[1].DayTrip)
	}
	// Items on a day-trip day share the hub, so no per-item city repeats.
	if days[1].Items[0].City != "" {
		t.Fatalf("day-trip item should not repeat the hub city, got %q", days[1].Items[0].City)
	}
	if days[3].DayTrip != "" {
		t.Fatalf("mixed day must not get a day-trip label, got %q", days[3].DayTrip)
	}
	// Mixed day: hub comes from the first item's city; the item in a
	// different city carries its own city label.
	if days[3].Hub != "Sounion" {
		t.Fatalf("mixed-day hub should come from the first item, got %q", days[3].Hub)
	}
	var plaka *printItem
	for i := range days[3].Items {
		if days[3].Items[i].Name == "Plaka dinner" {
			plaka = &days[3].Items[i]
		}
	}
	if plaka == nil || plaka.City != "Athens" {
		t.Fatalf("off-hub item should carry its city, got %+v", plaka)
	}
	// Day 3 has no items but still renders (weather/stay/transport slot).
	if len(days[2].Items) != 0 {
		t.Fatalf("day 3 should be empty, got %+v", days[2].Items)
	}
	// Gap day inherits the previous day's city.
	if days[2].Hub != "Delphi" && days[2].Hub != "Athens" {
		t.Fatalf("gap day should inherit a known city, got %q", days[2].Hub)
	}
	if len(unscheduled) != 2 {
		t.Fatalf("expected 2 unscheduled items (no-day + clamped), got %+v", unscheduled)
	}
}

func TestBuildPrintDays_UndatedTrip(t *testing.T) {
	d := exportData{
		Trip: store.Trip{Title: "Sometime"},
		Items: []store.ItineraryItem{
			{Name: "Louvre", City: strp("Paris"), Day: i32p(1)},
			{Name: "Orsay", City: strp("Paris"), Day: i32p(3)},
		},
		Accommodations: []store.Accommodation{{Name: "Hôtel", CheckIn: dateVal(t, "2026-08-01")}},
		Segments:       []store.TripSegment{{Mode: "train", DepartDate: dateVal(t, "2026-08-01")}},
	}
	days, unscheduled, otherStays, otherSegs := buildPrintDays("en", d, nil)

	// Item-less relative days are dropped; the rest have no calendar date.
	if len(days) != 2 || days[0].Label != "Day 1" || days[1].Label != "Day 3" {
		t.Fatalf("undated days wrong: %+v", days)
	}
	for _, day := range days {
		if day.Date != "" || len(day.Stays) != 0 || len(day.Segments) != 0 {
			t.Fatalf("undated day must have no date/stays/segments: %+v", day)
		}
	}
	if len(unscheduled) != 0 {
		t.Fatalf("unexpected unscheduled items: %+v", unscheduled)
	}
	// Stays and transport fall back to the flat reference lists.
	if len(otherStays) != 1 || len(otherSegs) != 1 {
		t.Fatalf("undated trip should list stays/segments flat, got %+v / %+v", otherStays, otherSegs)
	}
}

func TestBuildPrintBudget(t *testing.T) {
	if pb := buildPrintBudget(nil, nil); pb != nil {
		t.Fatalf("no budget, no expenses ⇒ nil, got %+v", pb)
	}
	// A budget row without a target and no expenses is nothing worth printing.
	if pb := buildPrintBudget(&store.TripBudget{Currency: "EUR"}, nil); pb != nil {
		t.Fatalf("target-less budget with no expenses ⇒ nil, got %+v", pb)
	}

	target := 2000.0
	b := &store.TripBudget{TargetAmount: &target, Currency: "EUR"}
	// One line planned and paid at a different price, one paid with no plan,
	// one still only planned — the three shapes 00067 allows, which is also the
	// fixture the Budget tab and the list-row parity test use.
	expenses := []store.TripExpense{
		{Category: "lodging", Label: "Hotel Grande", PlannedAmount: ptrTo(550.0), ActualAmount: ptrTo(600.0)},
		{Category: "food", Label: "Tavernas", ActualAmount: ptrTo(250.5)},
		{Category: "lodging", Label: "Airbnb Delphi", PlannedAmount: ptrTo(150.0)},
	}
	pb := buildPrintBudget(b, expenses)
	if pb == nil {
		t.Fatal("expected a budget")
	}
	// Spent counts only what was paid; Remaining is target − spent, unchanged
	// since before 00067. Planned is the plan and does not shrink.
	if pb.Currency != "EUR" || pb.Target != "2000.00" || pb.Spent != "850.50" ||
		pb.Remaining != "1149.50" || pb.Planned != "700.00" {
		t.Fatalf("budget math wrong: %+v", pb)
	}
	// Rows: lodging subtotal, its 2 expenses, food subtotal, its expense —
	// grouped in first-appearance order. A blank cell means "no such number",
	// never 0.00.
	wantRows := []printBudgetRow{
		{Label: "Lodging", Planned: "700.00", Amount: "600.00", Subtotal: true},
		{Label: "Hotel Grande", Planned: "550.00", Amount: "600.00"},
		{Label: "Airbnb Delphi", Planned: "150.00", Amount: ""},
		{Label: "Food", Planned: "", Amount: "250.50", Subtotal: true},
		{Label: "Tavernas", Planned: "", Amount: "250.50"},
	}
	if len(pb.Rows) != len(wantRows) {
		t.Fatalf("rows = %+v", pb.Rows)
	}
	for i, want := range wantRows {
		if pb.Rows[i] != want {
			t.Fatalf("row %d = %+v, want %+v", i, pb.Rows[i], want)
		}
	}

	// Expenses without a budget row: USD default, no target/remaining.
	pb = buildPrintBudget(nil, expenses[1:2])
	if pb == nil || pb.Currency != "USD" || pb.Target != "" || pb.Remaining != "" ||
		pb.Spent != "250.50" || pb.Planned != "" {
		t.Fatalf("expenses-only budget wrong: %+v", pb)
	}

	// A trip that has only PLANNED money still prints: spent is honestly 0.00
	// and the plan carries the page.
	pb = buildPrintBudget(nil, expenses[2:])
	if pb == nil || pb.Spent != "0.00" || pb.Planned != "150.00" {
		t.Fatalf("planned-only budget wrong: %+v", pb)
	}
}

func TestDisplayURL(t *testing.T) {
	cases := []struct{ in, want string }{
		{"", ""},
		{"https://www.booking.com/hotel/gr/grande.html?aid=123&label=x", "booking.com/hotel/gr/grande.html"},
		{"http://example.com/", "example.com"},
		{"not a url", "not a url"},
	}
	for _, c := range cases {
		if got := displayURL(c.in); got != c.want {
			t.Fatalf("displayURL(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	long := "https://example.com/" + strings.Repeat("very-long-path/", 10)
	got := displayURL(long)
	if len([]rune(got)) > 48 || !strings.HasSuffix(got, "…") {
		t.Fatalf("long URL should truncate with ellipsis, got %q (%d runes)", got, len([]rune(got)))
	}
}

func TestFormatWeatherLine(t *testing.T) {
	pct := 20
	if got := formatWeatherLine("en", WeatherDay{TempMinC: 15.4, TempMaxC: 24.6, PrecipPct: &pct}, false); got != "15–25°C, 20% chance of rain" {
		t.Fatalf("forecast line = %q", got)
	}
	if got := formatWeatherLine("en", WeatherDay{TempMinC: 18, TempMaxC: 27, PrecipMM: 6}, true); got != "Typical: 18–27°C, 6mm rain" {
		t.Fatalf("historical line = %q", got)
	}
	if got := formatWeatherLine("en", WeatherDay{TempMinC: 18, TempMaxC: 27, PrecipMM: 0.2}, false); got != "18–27°C" {
		t.Fatalf("dry line = %q", got)
	}
}

func TestLoadPrintWeather_ForecastAndHistorical(t *testing.T) {
	ws := weatherStub(t, true, 22, 14)

	// Near-future trip ⇒ forecast path with rain probability.
	start := time.Now().UTC().AddDate(0, 0, 3).Truncate(24 * time.Hour)
	trip := store.Trip{
		StartDate: pgtype.Date{Time: start, Valid: true},
		EndDate:   pgtype.Date{Time: start.AddDate(0, 0, 1), Valid: true},
	}
	d := exportData{Trip: trip, Items: []store.ItineraryItem{{Name: "Eiffel", City: strp("Paris"), Day: i32p(1)}}}
	lines := loadPrintWeather(context.Background(), ws, d, 2)
	if len(lines) != 2 {
		t.Fatalf("expected 2 lines, got %+v", lines)
	}
	for i, line := range lines {
		if !strings.Contains(line, "°C") || !strings.Contains(line, "chance of rain") {
			t.Fatalf("forecast line %d = %q", i, line)
		}
	}

	// Far-future trip ⇒ archive path, "Typical:" prefix (stub echoes last
	// year's dates; MM-DD matching aligns them with the trip days).
	farStart := time.Now().UTC().AddDate(0, 0, 60).Truncate(24 * time.Hour)
	d.Trip.StartDate = pgtype.Date{Time: farStart, Valid: true}
	d.Trip.EndDate = pgtype.Date{Time: farStart.AddDate(0, 0, 1), Valid: true}
	lines = loadPrintWeather(context.Background(), ws, d, 2)
	if len(lines) != 2 || !strings.HasPrefix(lines[0], "Typical: ") {
		t.Fatalf("historical lines = %+v", lines)
	}
}

func TestLoadPrintWeather_Resilient(t *testing.T) {
	// Dead upstream ⇒ empty lines, no error, no panic.
	ws := NewWeatherService()
	ws.GeocodeBaseURL = "http://127.0.0.1:1"
	ws.ForecastBaseURL = "http://127.0.0.1:1"
	ws.ArchiveBaseURL = "http://127.0.0.1:1"

	d := exportData{
		Trip:  printFixtureTrip(t),
		Items: []store.ItineraryItem{{Name: "Acropolis", City: strp("Athens"), Day: i32p(1)}},
	}
	lines := loadPrintWeather(context.Background(), ws, d, 5)
	if len(lines) != 5 {
		t.Fatalf("expected 5 slots, got %+v", lines)
	}
	for i, line := range lines {
		if line != "" {
			t.Fatalf("line %d should be empty on failure, got %q", i, line)
		}
	}

	// Undated / nil-service guards.
	if got := loadPrintWeather(context.Background(), nil, d, 5); got != nil {
		t.Fatalf("nil service should return nil, got %+v", got)
	}
	if got := loadPrintWeather(context.Background(), ws, exportData{Trip: store.Trip{}}, 5); got != nil {
		t.Fatalf("undated trip should return nil, got %+v", got)
	}
}

func TestBuildPrintView_HasContent(t *testing.T) {
	// A dated but empty trip renders the empty state, not 5 hollow days.
	view := buildPrintView("en", exportData{Trip: printFixtureTrip(t)}, nil, nil)
	if view.HasContent || len(view.Days) != 0 {
		t.Fatalf("empty trip should have no content, got %+v", view)
	}
	// A budget alone counts as content.
	target := 100.0
	view = buildPrintView("en", exportData{Trip: printFixtureTrip(t)},
		buildPrintBudget(&store.TripBudget{TargetAmount: &target, Currency: "USD"}, nil), nil)
	if !view.HasContent || view.Budget == nil {
		t.Fatalf("budget-only trip should have content, got %+v", view)
	}
}

func TestPrintViewTemplate_Escapes(t *testing.T) {
	evil := `<script>alert(1)</script>`
	view := printViewData{
		T:       newPrintLabels("en"),
		Title:   evil,
		Summary: evil,
		Days: []printDaySection{{
			Label: "Day 1", Hub: evil, Weather: evil,
			Items:    []printItem{{Name: evil, Address: evil, RecommendedBy: evil}},
			Stays:    []printStay{{Name: evil, Meta: evil, URL: "javascript:alert(1)", URLText: evil}},
			Segments: []printSegment{{Route: evil, Mode: evil, Meta: evil, Notes: evil}},
		}},
		Budget:     &printBudget{Currency: evil, Spent: evil, Rows: []printBudgetRow{{Label: evil, Amount: evil}}},
		HasContent: true,
	}
	var buf bytes.Buffer
	if err := printViewTmpl.Execute(&buf, view); err != nil {
		t.Fatalf("execute: %v", err)
	}
	html := buf.String()
	if strings.Contains(html, "<script>alert") {
		t.Fatal("unescaped script tag leaked into print view")
	}
	if !strings.Contains(html, "&lt;script&gt;") {
		t.Fatal("expected escaped script tag in output")
	}
	// html/template neutralizes unsafe URL schemes in href.
	if strings.Contains(html, `href="javascript:`) {
		t.Fatal("unsafe URL scheme survived in href")
	}
}

func TestPrintViewTemplate_DaySections(t *testing.T) {
	view := printViewData{
		// The template renders its static chrome from T (specs/i18n-spanish),
		// so a literal built in a test needs the English label set.
		T:     newPrintLabels("en"),
		Title: "Greece",
		Days: []printDaySection{
			{Label: "Day 1", Date: "Sat, Aug 1", Hub: "Athens", Weather: "18–27°C",
				Items: []printItem{{Name: "Acropolis", TimeOfDay: "Morning"}},
				Stays: []printStay{{Name: "Hotel Grande", Meta: "Check in today"}}},
			{Label: "Day 2", Date: "Sun, Aug 2", Hub: "Delphi", DayTrip: "Day trip from Athens"},
		},
		HasContent: true,
	}
	var buf bytes.Buffer
	if err := printViewTmpl.Execute(&buf, view); err != nil {
		t.Fatalf("execute: %v", err)
	}
	html := buf.String()
	for _, want := range []string{
		"Day 1 · Sat, Aug 1 — Athens",
		"Weather: 18–27°C",
		"Tonight: Hotel Grande",
		"Day trip from Athens",
		"No plans yet for this day.",
	} {
		if !strings.Contains(html, want) {
			t.Fatalf("print view missing %q", want)
		}
	}
}
