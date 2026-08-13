package main

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// Pure unit tests for the Next Step ladder — hand-built exportData, fixed
// `now`, findings from the real reviewTrip (nil deps → no live checks), so
// every assertion is deterministic.

// nextStepNow is "well before" the fixture trip: the packing gate is open and
// the trip is not past.
var nextStepNow = time.Date(2026, 8, 20, 12, 0, 0, 0, time.UTC)

// nextStepFixture builds a COMPLETE 4-day Paris→Lyon trip (every ladder phase
// satisfied): items on every day in two cities, both cities' nights covered by
// booked confirmed stays, a booked connecting segment, no open todos, and a
// started packing checklist. Tests knock out one phase at a time.
func nextStepFixture(t *testing.T) exportData {
	t.Helper()
	trip := store.Trip{ID: uuid.New(), Title: "France",
		StartDate: dateVal(t, "2026-09-01"), EndDate: dateVal(t, "2026-09-04")}
	paris, lyon := strp("Paris"), strp("Lyon")
	return exportData{
		Trip: trip,
		Items: []store.ItineraryItem{
			{ID: uuid.New(), Name: "Louvre", City: paris, Day: i32p(1), Position: 1},
			{ID: uuid.New(), Name: "Musée d'Orsay", City: paris, Day: i32p(2), Position: 2},
			{ID: uuid.New(), Name: "Vieux Lyon", City: lyon, Day: i32p(3), Position: 3},
			{ID: uuid.New(), Name: "Parc de la Tête d'Or", City: lyon, Day: i32p(4), Position: 4},
		},
		Accommodations: []store.Accommodation{
			{ID: uuid.New(), Name: "Hotel Le Marais, Paris", Booked: true,
				CheckIn: dateVal(t, "2026-09-01"), CheckOut: dateVal(t, "2026-09-03")},
			{ID: uuid.New(), Name: "Lyon Riverside Hotel", Booked: true,
				CheckIn: dateVal(t, "2026-09-03"), CheckOut: dateVal(t, "2026-09-04")},
		},
		Segments: []store.TripSegment{
			{ID: uuid.New(), Mode: "train", Origin: strp("Paris"), Destination: strp("Lyon"),
				Booked: true},
		},
		Checklist: []store.TripChecklistItem{
			{ID: uuid.New(), Title: "Passport", Category: "documents"},
		},
	}
}

// derive runs the real review pipeline (no live deps) then the ladder.
func derive(locale string, now time.Time, d exportData) (*NextStep, *PlanProgress) {
	findings := reviewTrip(context.Background(), locale, d, reviewOptions{}, reviewDeps{})
	return deriveNextStep(locale, now, d, findings)
}

func mustStep(t *testing.T, step *NextStep, progress *PlanProgress, kind string, done int) {
	t.Helper()
	if step == nil || progress == nil {
		t.Fatalf("step=%+v progress=%+v, want kind=%s", step, progress, kind)
	}
	if step.Kind != kind {
		t.Fatalf("kind = %s (title %q), want %s", step.Kind, step.Title, kind)
	}
	if progress.Done != done || progress.Total != planLadderTotal {
		t.Fatalf("progress = %d/%d, want %d/%d", progress.Done, progress.Total, done, planLadderTotal)
	}
}

func TestNextStep_Undated(t *testing.T) {
	d := nextStepFixture(t)
	d.Trip.StartDate = pgtype.Date{}
	d.Trip.EndDate = pgtype.Date{}
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "set_dates", 0)
	if step.Fix == nil || step.Fix.Action != "set_dates" {
		t.Fatalf("fix = %+v, want set_dates", step.Fix)
	}
	if !strings.Contains(step.SeedPrompt, "set_trip_dates") {
		t.Fatalf("seed should name set_trip_dates:\n%s", step.SeedPrompt)
	}
}

func TestNextStep_NoItems(t *testing.T) {
	d := nextStepFixture(t)
	d.Items = nil
	// No items also means the transit/lodging city walks have nothing to work
	// with; the ladder must still stop at plan_itinerary, not fall through.
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "plan_itinerary", 1)
	if !strings.Contains(step.SeedPrompt, "update_itinerary_section") ||
		!strings.Contains(step.SeedPrompt, "no places yet") {
		t.Fatalf("empty-trip seed off:\n%s", step.SeedPrompt)
	}
}

func TestNextStep_NoneScheduled(t *testing.T) {
	d := nextStepFixture(t)
	for i := range d.Items {
		d.Items[i].Day = nil
	}
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "plan_itinerary", 1)
	if step.Count == nil || *step.Count != len(d.Items) {
		t.Fatalf("count = %v, want %d", step.Count, len(d.Items))
	}
	if !strings.Contains(step.SeedPrompt, "none are scheduled") {
		t.Fatalf("none-scheduled seed off:\n%s", step.SeedPrompt)
	}
}

func TestNextStep_LodgingWinsOverTransitAndBookings(t *testing.T) {
	d := nextStepFixture(t)
	d.Accommodations = nil                // lodging gap (both cities)
	d.Segments = nil                      // transit gap too
	d.BookingTodos = []store.BookingTodo{ // and an open todo
		{ID: uuid.New(), Kind: "stay", TodoKey: "stay:paris", Title: "Stay in Paris"},
	}
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "add_lodging", 2)
	// Fix passthrough: the first (earliest-day) lodging finding's prefills.
	if step.Fix == nil || step.Fix.Action != "add_lodging" ||
		step.Fix.City == nil || *step.Fix.City != "Paris" ||
		step.Fix.CheckIn == nil || *step.Fix.CheckIn != "2026-09-01" ||
		step.Fix.CheckOut == nil || *step.Fix.CheckOut != "2026-09-03" {
		t.Fatalf("fix passthrough = %+v", step.Fix)
	}
	if step.Day == nil || *step.Day != 1 {
		t.Fatalf("day anchor = %v, want 1", step.Day)
	}
	if step.Detail == "" || !strings.Contains(step.Detail, "No lodging booked") {
		t.Fatalf("detail should reuse the finding message, got %q", step.Detail)
	}
	if !strings.Contains(step.SeedPrompt, "in Paris") ||
		!strings.Contains(step.SeedPrompt, "add_accommodation") {
		t.Fatalf("lodging seed off:\n%s", step.SeedPrompt)
	}
}

func TestNextStep_TransitAfterLodgingCovered(t *testing.T) {
	d := nextStepFixture(t)
	d.Segments = nil
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "add_transport", 3)
	if step.Fix == nil || step.Fix.Origin == nil || *step.Fix.Origin != "Paris" ||
		step.Fix.Destination == nil || *step.Fix.Destination != "Lyon" {
		t.Fatalf("fix passthrough = %+v", step.Fix)
	}
	if !strings.Contains(step.SeedPrompt, "from Paris to Lyon") ||
		!strings.Contains(step.SeedPrompt, "add_transport_segment") {
		t.Fatalf("transport seed off:\n%s", step.SeedPrompt)
	}
}

func TestNextStep_ScheduleCleanup_Unscheduled(t *testing.T) {
	d := nextStepFixture(t)
	d.Items = append(d.Items, store.ItineraryItem{
		ID: uuid.New(), Name: "Bouchon dinner", City: strp("Lyon"), Position: 5}) // day nil
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "schedule_items", 4)
	if step.Count == nil || *step.Count != 1 {
		t.Fatalf("count = %v, want 1", step.Count)
	}
	if !strings.Contains(step.SeedPrompt, "1 place(s) have no day assigned") {
		t.Fatalf("schedule seed off:\n%s", step.SeedPrompt)
	}
}

func TestNextStep_ScheduleCleanup_EmptyDayAnchor(t *testing.T) {
	d := nextStepFixture(t)
	// Empty day 2: move the Orsay to day 3's city day — day 2 has nothing.
	d.Items[1].Day = i32p(3)
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "schedule_items", 4)
	if step.Day == nil || *step.Day != 2 {
		t.Fatalf("day anchor = %v, want 2 (first empty day)", step.Day)
	}
	if step.Count != nil {
		t.Fatalf("count should be nil when nothing is unscheduled, got %v", step.Count)
	}
	if !strings.Contains(step.SeedPrompt, "day 2 is empty") {
		t.Fatalf("empty-day seed off:\n%s", step.SeedPrompt)
	}
}

func TestNextStep_BookAggregateDedupe(t *testing.T) {
	d := nextStepFixture(t)
	d.Accommodations[0].Booked = false // open Paris stay (server-truth row)
	d.BookingTodos = []store.BookingTodo{
		// Claimed by the Paris stay above (same city) — must NOT double count.
		{ID: uuid.New(), Kind: "stay", TodoKey: "stay:paris", Title: "Stay in Paris"},
		// No confirmed segment covers Lyon→Nice — counts.
		{ID: uuid.New(), Kind: "transport", TodoKey: "transport:lyon>>nice", Title: "Lyon → Nice"},
		// Already booked — never counts.
		{ID: uuid.New(), Kind: "stay", TodoKey: "stay:lyon", Title: "Stay in Lyon", Booked: true},
	}
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "book_trip", 5)
	if step.Count == nil || *step.Count != 2 {
		t.Fatalf("count = %v, want 2 (stay row + unclaimed transport todo)", step.Count)
	}
	if !strings.Contains(step.SeedPrompt, "Hotel Le Marais, Paris") ||
		!strings.Contains(step.SeedPrompt, "Lyon → Nice") ||
		strings.Contains(step.SeedPrompt, "Stay in Paris") {
		t.Fatalf("book seed lines off:\n%s", step.SeedPrompt)
	}
	if !strings.Contains(step.SeedPrompt, "update_booking_todo") {
		t.Fatalf("book seed should name update_booking_todo:\n%s", step.SeedPrompt)
	}
}

func TestNextStep_PackingGates(t *testing.T) {
	d := nextStepFixture(t)
	d.Checklist = nil
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "add_packing", 6)
	if !strings.Contains(step.SeedPrompt, "add_packing_item") ||
		!strings.Contains(step.SeedPrompt, "Paris, Lyon") {
		t.Fatalf("packing seed off:\n%s", step.SeedPrompt)
	}

	// Mid-trip (started, not ended): the packing nag is skipped → all set.
	midTrip := time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC)
	step, progress = derive("en", midTrip, d)
	mustStep(t, step, progress, "all_set", planLadderTotal)
}

func TestNextStep_AllSet(t *testing.T) {
	step, progress := derive("en", nextStepNow, nextStepFixture(t))
	mustStep(t, step, progress, "all_set", planLadderTotal)
	if step.SeedPrompt != "" {
		t.Fatalf("all_set carries no seed, got %q", step.SeedPrompt)
	}
}

func TestNextStep_PastTripNil(t *testing.T) {
	after := time.Date(2026, 9, 10, 12, 0, 0, 0, time.UTC)
	step, progress := derive("en", after, nextStepFixture(t))
	if step != nil || progress != nil {
		t.Fatalf("past trip = %+v / %+v, want nil/nil", step, progress)
	}
}

func TestNextStep_SeedStaysCanonicalEnglish(t *testing.T) {
	d := nextStepFixture(t)
	d.Accommodations = nil
	step, _ := derive("es", nextStepNow, d)
	if step == nil || step.Title != "Reserva un alojamiento" {
		t.Fatalf("es title = %+v", step)
	}
	if !strings.Contains(step.SeedPrompt, "I still need a place to stay") {
		t.Fatalf("seed must stay canonical English:\n%s", step.SeedPrompt)
	}
}

// The step must ignore the live-enrichment findings entirely: the same data
// with injected weather/hours findings yields the same step, which is what
// keeps the check_hours=true and =false cache variants in agreement.
func TestNextStep_IgnoresWeatherAndHoursFindings(t *testing.T) {
	d := nextStepFixture(t)
	d.Accommodations[0].Booked = false // → book_trip
	findings := reviewTrip(context.Background(), "en", d, reviewOptions{}, reviewDeps{})
	day1 := 1
	noisy := append([]Finding{
		{Severity: "info", Category: "weather", Message: "Rain likely on Day 1.", Day: &day1},
		{Severity: "warn", Category: "hours", Message: "Louvre may be closed.", Day: &day1},
	}, findings...)

	base, baseProg := deriveNextStep("en", nextStepNow, d, findings)
	withNoise, noiseProg := deriveNextStep("en", nextStepNow, d, noisy)
	if base == nil || withNoise == nil || base.Kind != withNoise.Kind || base.Kind != "book_trip" {
		t.Fatalf("kinds diverge: %+v vs %+v", base, withNoise)
	}
	if baseProg.Done != noiseProg.Done {
		t.Fatalf("progress diverges: %d vs %d", baseProg.Done, noiseProg.Done)
	}
}
