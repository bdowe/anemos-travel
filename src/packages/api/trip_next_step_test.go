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

// walkTodos is the fixture trip's derived booking checklist EXACTLY as the
// client's _deriveTodos would sync it: home→first city, then per city a stay
// followed by the leg out, then the leg home — in position order, which is
// the order the phase-3 walk consumes. Every row is auto (client-derived) and
// carries the title/key conventions the walk parses.
func walkTodos(t *testing.T) []store.BookingTodo {
	t.Helper()
	flights := strp("google_flights")
	return []store.BookingTodo{
		{ID: uuid.New(), Kind: "transport", TodoKey: "transport:ewr>>paris",
			Title: "EWR → Paris", Provider: flights, Auto: true, Position: 0,
			DepartDate: dateVal(t, "2026-09-01")},
		{ID: uuid.New(), Kind: "stay", TodoKey: "stay:paris",
			Title: "Stay in Paris", Provider: strp("airbnb"), Auto: true, Position: 1,
			DepartDate: dateVal(t, "2026-09-01"), ReturnDate: dateVal(t, "2026-09-03")},
		{ID: uuid.New(), Kind: "transport", TodoKey: "transport:paris>>lyon",
			Title: "Paris → Lyon", Provider: flights, Auto: true, Position: 2,
			DepartDate: dateVal(t, "2026-09-03")},
		{ID: uuid.New(), Kind: "stay", TodoKey: "stay:lyon",
			Title: "Stay in Lyon", Provider: strp("airbnb"), Auto: true, Position: 3,
			DepartDate: dateVal(t, "2026-09-03"), ReturnDate: dateVal(t, "2026-09-04")},
		{ID: uuid.New(), Kind: "transport", TodoKey: "transport:lyon>>ewr",
			Title: "Lyon → EWR", Provider: flights, Auto: true, Position: 4,
			DepartDate: dateVal(t, "2026-09-04")},
	}
}

// bookSlots marks the named todo keys booked — the checkbox the traveler taps.
func bookSlots(todos []store.BookingTodo, keys ...string) []store.BookingTodo {
	for i := range todos {
		for _, k := range keys {
			if todos[i].TodoKey == k {
				todos[i].Booked = true
			}
		}
	}
	return todos
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
	// The ladder rides on EVERY step: the card's "N of 6" is unreadable
	// without it, and the client renders whatever order arrives here.
	mustLadder(t, progress)
}

// mustLadder asserts the wire ladder matches planLadder — same length as
// Total, ids in order, every label filled.
func mustLadder(t *testing.T, progress *PlanProgress) {
	t.Helper()
	if len(progress.Phases) != progress.Total {
		t.Fatalf("phases = %d, want %d (Total)", len(progress.Phases), progress.Total)
	}
	for i, p := range progress.Phases {
		if p.ID != planLadder[i].ID {
			t.Fatalf("phase %d id = %q, want %q", i, p.ID, planLadder[i].ID)
		}
		if p.Label == "" {
			t.Fatalf("phase %d (%s) has no label", i, p.ID)
		}
		// Only the bookings (derived slots) and schedule (plannable days) rungs
		// have an exact denominator; every other rung stays silent rather than
		// inventing one.
		if p.Progress != nil && p.ID != planPhaseBookings && p.ID != planPhaseSchedule {
			t.Fatalf("phase %s must not carry a tally: %+v", p.ID, p.Progress)
		}
		if p.Progress != nil && (p.Progress.Total <= 0 || p.Progress.Done > p.Progress.Total) {
			t.Fatalf("phase %s tally = %d/%d, want 0 <= done <= total, total > 0",
				p.ID, p.Progress.Done, p.Progress.Total)
		}
	}
}

// bookingsTally returns the bookings rung's tally (nil when it has none).
func bookingsTally(t *testing.T, progress *PlanProgress) *PhaseProgress {
	t.Helper()
	return rungTally(t, progress, planPhaseBookings)
}

// rungTally returns one rung's tally (nil when it has none).
func rungTally(t *testing.T, progress *PlanProgress, id string) *PhaseProgress {
	t.Helper()
	for _, p := range progress.Phases {
		if p.ID == id {
			return p.Progress
		}
	}
	t.Fatalf("no %q rung in %+v", id, progress.Phases)
	return nil
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

// Dates gate the walk too: a trip with synced slots but no dates still stops
// at phase 1 (every later phase, the slot copy included, is date-bound).
func TestNextStep_UndatedBeatsWalk(t *testing.T) {
	d := nextStepFixture(t)
	d.Trip.StartDate = pgtype.Date{}
	d.Trip.EndDate = pgtype.Date{}
	d.BookingTodos = walkTodos(t)
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "set_dates", 0)
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

// --- phase 3 fallback (no synced slots) ---------------------------------------

// A trip with NO derived booking slots — imported, MCP- or agent-created, never
// opened in the app — keeps the pre-walk behavior verbatim: the earliest-day
// lodging finding first, its fix and message passed straight through.
func TestNextStep_FallbackLodgingFirst(t *testing.T) {
	d := nextStepFixture(t)
	d.Accommodations = nil // lodging gap (both cities)
	d.Segments = nil       // transit gap too
	d.BookingTodos = nil   // …and nothing synced, so the walk stands down
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "add_lodging", 2)
	if step.Title != "Book a place to stay" {
		t.Fatalf("fallback keeps the generic title, got %q", step.Title)
	}
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

// Same fallback, transit half: with lodging covered the transit finding takes
// phase 3's slot (it used to be phase 4 of 7).
func TestNextStep_TransitAfterLodgingCovered(t *testing.T) {
	d := nextStepFixture(t)
	d.Segments = nil
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "add_transport", 2)
	if step.Fix == nil || step.Fix.Origin == nil || *step.Fix.Origin != "Paris" ||
		step.Fix.Destination == nil || *step.Fix.Destination != "Lyon" {
		t.Fatalf("fix passthrough = %+v", step.Fix)
	}
	if !strings.Contains(step.SeedPrompt, "from Paris to Lyon") ||
		!strings.Contains(step.SeedPrompt, "add_transport_segment") {
		t.Fatalf("transport seed off:\n%s", step.SeedPrompt)
	}
}

// Custom rows are not slots: a checklist of nothing but custom todos still
// counts as "never synced" and uses the findings fallback.
func TestNextStep_FallbackWhenOnlyCustomTodos(t *testing.T) {
	d := nextStepFixture(t)
	d.Accommodations = nil
	d.Segments = nil
	d.BookingTodos = []store.BookingTodo{
		{ID: uuid.New(), Kind: "other", TodoKey: "custom:abc", Title: "Rent a car"},
	}
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "add_lodging", 2)
	if step.Title != "Book a place to stay" {
		t.Fatalf("custom-only checklist must use the fallback title, got %q", step.Title)
	}
}

// --- phase 3 walk --------------------------------------------------------------

// The headline of specs/next-step-cta v2: with the whole checklist open, the
// step is the OUTBOUND FLIGHT — not the first stay, which the old ladder chose
// because lodging findings outranked transit ones.
func TestNextStep_WalkFlightBeforeStay(t *testing.T) {
	d := nextStepFixture(t)
	d.BookingTodos = walkTodos(t)
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "add_transport", 2)
	if step.Title != "Book your flight to Paris" {
		t.Fatalf("title = %q, want the mode-aware flight title", step.Title)
	}
	if !strings.Contains(step.Detail, "EWR → Paris") || !strings.Contains(step.Detail, "Sep 1") {
		t.Fatalf("detail = %q, want the route label and the departure date", step.Detail)
	}
	// Endpoint casing survives ONLY on the todo title ("EWR → Paris"); the key
	// is lowercase. Pins the convention the client writes and re-parses.
	if step.Fix == nil || step.Fix.Origin == nil || *step.Fix.Origin != "EWR" ||
		step.Fix.Destination == nil || *step.Fix.Destination != "Paris" ||
		step.Fix.Mode == nil || *step.Fix.Mode != "flight" ||
		step.Fix.Date == nil || *step.Fix.Date != "2026-09-01" {
		t.Fatalf("fix = %+v", step.Fix)
	}
	if step.Day == nil || *step.Day != 1 {
		t.Fatalf("day anchor = %v, want 1", step.Day)
	}
	if !strings.Contains(step.SeedPrompt, "from EWR to Paris") ||
		!strings.Contains(step.SeedPrompt, "add_transport_segment") {
		t.Fatalf("transport seed off:\n%s", step.SeedPrompt)
	}
}

// The checkbox alone advances the walk: no accommodation or segment row is
// created when the traveler books elsewhere and just ticks the row.
func TestNextStep_WalkCheckboxAdvances(t *testing.T) {
	d := nextStepFixture(t)
	d.Accommodations = nil // nothing backing any stay
	d.BookingTodos = bookSlots(walkTodos(t), "transport:ewr>>paris")
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "add_lodging", 2)
	if step.Title != "Book your stay in Paris" {
		t.Fatalf("title = %q, want the per-city stay title", step.Title)
	}
	if !strings.Contains(step.Detail, "No lodging booked for the nights of") {
		t.Fatalf("detail = %q, want the shared lodging copy", step.Detail)
	}
	if step.Fix == nil || step.Fix.City == nil || *step.Fix.City != "Paris" ||
		step.Fix.CheckIn == nil || *step.Fix.CheckIn != "2026-09-01" ||
		step.Fix.CheckOut == nil || *step.Fix.CheckOut != "2026-09-03" {
		t.Fatalf("fix = %+v", step.Fix)
	}
	if step.Day == nil || *step.Day != 1 {
		t.Fatalf("day anchor = %v, want 1", step.Day)
	}
}

// A stay slot is claimed only when EVERY night it covers has a real stay —
// the date-aware upgrade over todoClaimed's fuzzy city match, which would have
// called a one-night hotel "Paris: done".
func TestNextStep_WalkDateAwareStayClaim(t *testing.T) {
	d := nextStepFixture(t)
	d.BookingTodos = bookSlots(walkTodos(t), "transport:ewr>>paris", "transport:lyon>>ewr")

	// Paris hotel covers 09-01 only; the slot spans 09-01 and 09-02.
	d.Accommodations[0].CheckOut = dateVal(t, "2026-09-02")
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "add_lodging", 2)
	if step.Title != "Book your stay in Paris" {
		t.Fatalf("partial coverage must keep the slot open, got %q", step.Title)
	}

	// Extend it over both nights and the whole checklist is satisfied.
	d.Accommodations[0].CheckOut = dateVal(t, "2026-09-03")
	step, progress = derive("en", nextStepNow, d)
	mustStep(t, step, progress, "all_set", planLadderTotal)
}

// Transport slots are claimed by CONFIRMED segments only: an auto draft is a
// suggestion, not a commitment (deliberately stricter than checkTransit, which
// suppresses its finding on drafts too).
func TestNextStep_WalkTransportClaims(t *testing.T) {
	base := func(t *testing.T) exportData {
		d := nextStepFixture(t)
		d.BookingTodos = bookSlots(walkTodos(t), "transport:ewr>>paris", "transport:lyon>>ewr")
		return d
	}

	d := base(t)
	d.Segments[0].Auto = true // draft only
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "add_transport", 2)
	if step.Title != "Book your flight to Lyon" {
		t.Fatalf("a draft segment must not claim the leg, got %q", step.Title)
	}

	d = base(t) // confirmed segment (Auto false) claims it
	step, progress = derive("en", nextStepNow, d)
	mustStep(t, step, progress, "all_set", planLadderTotal)
}

// The return leg is last in the walk and has no stay to name — it gets the
// "home" copy variant.
func TestNextStep_WalkReturnHomeLast(t *testing.T) {
	d := nextStepFixture(t)
	d.BookingTodos = bookSlots(walkTodos(t), "transport:ewr>>paris")
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "add_transport", 2)
	if step.Title != "Book your flight home" {
		t.Fatalf("title = %q, want the home variant", step.Title)
	}
	if step.Fix == nil || step.Fix.Origin == nil || *step.Fix.Origin != "Lyon" ||
		step.Fix.Destination == nil || *step.Fix.Destination != "EWR" {
		t.Fatalf("fix = %+v", step.Fix)
	}
	if step.Day == nil || *step.Day != 4 {
		t.Fatalf("day anchor = %v, want 4", step.Day)
	}
}

// A satisfied walk NEVER falls through to the findings: every slot checked off
// with zero accommodation rows still means "booked elsewhere", so the ladder
// moves on (the health sheet keeps flagging the same gap — that's its job).
func TestNextStep_WalkNeverFallsThroughToFindings(t *testing.T) {
	d := nextStepFixture(t)
	d.Accommodations = nil // checkLodging WILL emit findings for every night
	d.BookingTodos = bookSlots(walkTodos(t),
		"transport:ewr>>paris", "stay:paris", "transport:paris>>lyon",
		"stay:lyon", "transport:lyon>>ewr")
	// …plus one open custom row, which is not a slot: it belongs to book_trip.
	d.BookingTodos = append(d.BookingTodos, store.BookingTodo{
		ID: uuid.New(), Kind: "other", TodoKey: "custom:abc", Title: "Rent a car"})

	findings := reviewTrip(context.Background(), "en", d, reviewOptions{}, reviewDeps{})
	if firstFindingIn(findings, "lodging") == nil {
		t.Fatal("fixture precondition: expected lodging findings to exist")
	}
	step, progress := deriveNextStep("en", nextStepNow, d, findings)
	mustStep(t, step, progress, "book_trip", 4)
	if step.Count == nil || *step.Count != 1 {
		t.Fatalf("count = %v, want 1 (the custom row)", step.Count)
	}
	if !strings.Contains(step.SeedPrompt, "Rent a car") {
		t.Fatalf("book seed should carry the custom row:\n%s", step.SeedPrompt)
	}
}

// The walk only speaks for nights a slot actually spans. A trip whose leg
// ranges stop short (the client ends a range at its last scheduled item)
// leaves trailing nights in NO slot — nobody asked about them, so the card
// must not claim the trip is all set while Trip Health says three nights have
// no lodging.
func TestNextStep_WalkUnslottedNightsStillSurface(t *testing.T) {
	d := nextStepFixture(t)
	// Stretch the trip two nights past the last slot's checkout. The stretched
	// days need something planned on them too, or phase 4 (which now walks the
	// whole trip) would answer before the lodging gap this test is about.
	d.Trip.EndDate = dateVal(t, "2026-09-06")
	d.Items = append(d.Items, store.ItineraryItem{
		ID: uuid.New(), Name: "Presqu'île stroll", City: strp("Lyon"), Day: i32p(5), Position: 5})
	d.BookingTodos = bookSlots(walkTodos(t),
		"transport:ewr>>paris", "stay:paris", "transport:paris>>lyon",
		"stay:lyon", "transport:lyon>>ewr")

	findings := reviewTrip(context.Background(), "en", d, reviewOptions{}, reviewDeps{})
	if firstFindingIn(findings, "lodging") == nil {
		t.Fatal("fixture precondition: the trailing nights should be flagged")
	}
	step, progress := deriveNextStep("en", nextStepNow, d, findings)
	mustStep(t, step, progress, "add_lodging", 2)
	if step.Fix == nil || step.Fix.CheckIn == nil || *step.Fix.CheckIn != "2026-09-04" {
		t.Fatalf("fix should prefill the UNSLOTTED nights, got %+v", step.Fix)
	}

	// Cover them for real and the walk is genuinely satisfied.
	d.Accommodations = append(d.Accommodations, store.Accommodation{
		ID: uuid.New(), Name: "Lyon Riverside Hotel", Booked: true,
		CheckIn: dateVal(t, "2026-09-04"), CheckOut: dateVal(t, "2026-09-06")})
	step, progress = derive("en", nextStepNow, d)
	mustStep(t, step, progress, "all_set", planLadderTotal)
}

// The grouping placeholders are not places: a slot named for one keeps the
// generic copy and an endpoint-less fix, so neither the card nor the
// canonical-English seed ever tells anyone to book a hotel in "Other places".
func TestNextStep_WalkPlaceholderLabelsAreNotCities(t *testing.T) {
	t.Run("stay", func(t *testing.T) {
		d := nextStepFixture(t)
		d.Accommodations = nil
		d.BookingTodos = []store.BookingTodo{
			{ID: uuid.New(), Kind: "stay", TodoKey: "stay:other places",
				Title: "Stay in Other places", Auto: true,
				DepartDate: dateVal(t, "2026-09-01"), ReturnDate: dateVal(t, "2026-09-03")},
		}
		step, progress := derive("en", nextStepNow, d)
		mustStep(t, step, progress, "add_lodging", 2)
		if step.Title != "Book a place to stay" {
			t.Fatalf("title = %q, want the city-less fallback", step.Title)
		}
		if step.Fix.City != nil {
			t.Fatalf("fix city = %q, want none", *step.Fix.City)
		}
		if strings.Contains(step.SeedPrompt, "Other places") {
			t.Fatalf("seed must not name the placeholder:\n%s", step.SeedPrompt)
		}
	})

	t.Run("transport", func(t *testing.T) {
		d := nextStepFixture(t)
		d.BookingTodos = []store.BookingTodo{
			{ID: uuid.New(), Kind: "transport", TodoKey: "transport:paris>>other places",
				Title: "Paris → Other places", Provider: strp("google_flights"), Auto: true,
				DepartDate: dateVal(t, "2026-09-03")},
		}
		step, progress := derive("en", nextStepNow, d)
		mustStep(t, step, progress, "add_transport", 2)
		if step.Title != "Add transport between cities" {
			t.Fatalf("title = %q, want the generic fallback", step.Title)
		}
		if step.Fix.Origin != nil || step.Fix.Destination != nil {
			t.Fatalf("fix should carry no endpoints, got %+v", step.Fix)
		}
		if strings.Contains(step.SeedPrompt, "Other places") {
			t.Fatalf("seed must not name the placeholder:\n%s", step.SeedPrompt)
		}
	})
}

// Copy and fix follow the slot's mode: the per-leg override wins, else the
// provider the sync stored implies it.
func TestNextStep_WalkModeVariants(t *testing.T) {
	// One open leg into a city that has a (booked) stay slot, so the title is
	// the "to <city>" variant rather than the home one.
	trip := func(t *testing.T, city string, provider, mode *string, travelMode *string) exportData {
		d := nextStepFixture(t)
		d.Trip.TravelMode = travelMode
		d.Segments = nil // nothing confirmed, so the leg below stays open

		d.BookingTodos = []store.BookingTodo{
			{ID: uuid.New(), Kind: "stay", TodoKey: "stay:" + strings.ToLower(city),
				Title: "Stay in " + city, Auto: true, Booked: true, Position: 0},
			{ID: uuid.New(), Kind: "transport", TodoKey: "transport:paris>>" + strings.ToLower(city),
				Title: "Paris → " + city, Provider: provider, Mode: mode, Auto: true, Position: 1},
		}
		return d
	}

	cases := []struct {
		name           string
		city           string
		provider, mode *string
		travelMode     *string
		wantTitle      string
		wantMode       string // "" = fix carries no mode
		wantLabel      string
	}{
		{name: "ferry provider", city: "Naxos", provider: strp("ferry"),
			wantTitle: "Book your ferry to Naxos", wantMode: "ferry", wantLabel: "Add ferry"},
		{name: "ground provider with trip travel mode", city: "Lyon", provider: strp("rome2rio"),
			travelMode: strp("train"),
			wantTitle:  "Book transport to Lyon", wantMode: "train", wantLabel: "Add train"},
		{name: "ground provider without travel mode", city: "Lyon", provider: strp("rome2rio"),
			wantTitle: "Book transport to Lyon", wantMode: "", wantLabel: "Add transport"},
		{name: "per-leg override beats provider", city: "Lyon", provider: strp("google_flights"),
			mode:      strp("train"),
			wantTitle: "Book transport to Lyon", wantMode: "train", wantLabel: "Add train"},
		{name: "unknown provider stays generic", city: "Lyon",
			wantTitle: "Book transport to Lyon", wantMode: "", wantLabel: "Add transport"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := trip(t, tc.city, tc.provider, tc.mode, tc.travelMode)
			step, progress := derive("en", nextStepNow, d)
			mustStep(t, step, progress, "add_transport", 2)
			if step.Title != tc.wantTitle {
				t.Fatalf("title = %q, want %q", step.Title, tc.wantTitle)
			}
			if tc.wantMode == "" {
				if step.Fix.Mode != nil {
					t.Fatalf("mode = %q, want none", *step.Fix.Mode)
				}
			} else if step.Fix.Mode == nil || *step.Fix.Mode != tc.wantMode {
				t.Fatalf("mode = %v, want %q", step.Fix.Mode, tc.wantMode)
			}
			if step.Fix.Label != tc.wantLabel {
				t.Fatalf("label = %q, want %q", step.Fix.Label, tc.wantLabel)
			}
		})
	}
}

// Degradations that must stay graceful: a slot whose title lost its shape, a
// slot with no dates, one stranded outside the trip's days, and a zero-night
// stop that needs no lodging at all.
func TestNextStep_WalkSlotFallbacks(t *testing.T) {
	oneLeg := func(t *testing.T, todo store.BookingTodo) exportData {
		d := nextStepFixture(t)
		d.BookingTodos = []store.BookingTodo{todo}
		return d
	}

	t.Run("title without the arrow falls back to the key", func(t *testing.T) {
		d := oneLeg(t, store.BookingTodo{ID: uuid.New(), Kind: "transport",
			TodoKey: "transport:ewr>>paris", Title: "Flight", Provider: strp("google_flights"),
			Auto: true, DepartDate: dateVal(t, "2026-09-01")})
		step, _ := derive("en", nextStepNow, d)
		// Key endpoints are lowercase — the casing lived only on the title.
		if step.Fix == nil || step.Fix.Origin == nil || *step.Fix.Origin != "ewr" ||
			step.Fix.Destination == nil || *step.Fix.Destination != "paris" {
			t.Fatalf("fix = %+v, want the key-parsed endpoints", step.Fix)
		}
		if step.Detail != "Flight · departs Tue, Sep 1" {
			t.Fatalf("detail = %q", step.Detail)
		}
	})

	t.Run("unparseable slot keeps the generic copy", func(t *testing.T) {
		d := oneLeg(t, store.BookingTodo{ID: uuid.New(), Kind: "transport",
			TodoKey: "transport:", Title: "", Auto: true})
		step, progress := derive("en", nextStepNow, d)
		mustStep(t, step, progress, "add_transport", 2)
		if step.Title != "Add transport between cities" {
			t.Fatalf("title = %q, want the generic fallback", step.Title)
		}
		if step.Fix.Origin != nil || step.Fix.Destination != nil {
			t.Fatalf("fix should carry no endpoints, got %+v", step.Fix)
		}
		if step.Detail != "" {
			t.Fatalf("detail = %q, want empty", step.Detail)
		}
		if !strings.Contains(step.SeedPrompt, "between my cities") {
			t.Fatalf("seed should use the endpoint-less template:\n%s", step.SeedPrompt)
		}
	})

	t.Run("undated slot has no anchor and no date line", func(t *testing.T) {
		d := oneLeg(t, store.BookingTodo{ID: uuid.New(), Kind: "transport",
			TodoKey: "transport:ewr>>paris", Title: "EWR → Paris",
			Provider: strp("google_flights"), Auto: true})
		step, _ := derive("en", nextStepNow, d)
		if step.Day != nil {
			t.Fatalf("day = %v, want nil", step.Day)
		}
		if step.Detail != "EWR → Paris" {
			t.Fatalf("detail = %q, want the bare route label", step.Detail)
		}
		if step.Fix.Date != nil {
			t.Fatalf("fix date = %v, want nil", step.Fix.Date)
		}
	})

	t.Run("stale slot outside the trip days has no anchor", func(t *testing.T) {
		d := oneLeg(t, store.BookingTodo{ID: uuid.New(), Kind: "transport",
			TodoKey: "transport:ewr>>paris", Title: "EWR → Paris",
			Provider: strp("google_flights"), Auto: true,
			DepartDate: dateVal(t, "2026-08-20")}) // before the trip start
		step, _ := derive("en", nextStepNow, d)
		if step.Day != nil {
			t.Fatalf("day = %v, want nil for a pre-trip date", step.Day)
		}
		if step.Fix.Date == nil || *step.Fix.Date != "2026-08-20" {
			t.Fatalf("fix date should still carry the slot's own date, got %v", step.Fix.Date)
		}
	})

	t.Run("zero-night stay needs no lodging", func(t *testing.T) {
		d := nextStepFixture(t)
		d.Accommodations = nil
		d.BookingTodos = []store.BookingTodo{
			{ID: uuid.New(), Kind: "stay", TodoKey: "stay:paris", Title: "Stay in Paris",
				Auto: true, Position: 0,
				DepartDate: dateVal(t, "2026-09-01"), ReturnDate: dateVal(t, "2026-09-01")},
		}
		step, progress := derive("en", nextStepNow, d)
		// A zero-night stop needs no lodging, so the slot is vacuously claimed
		// and the walk never asks the traveler to book it — but it also spans
		// no night, so the trip's real nights stay unslotted and surface
		// through the lodging finding rather than being masked.
		mustStep(t, step, progress, "add_lodging", 2)
		if step.Fix == nil || step.Fix.CheckIn == nil || *step.Fix.CheckIn != "2026-09-01" {
			t.Fatalf("fix should cover the unslotted nights, got %+v", step.Fix)
		}
	})

	t.Run("single-night stay uses the singular copy", func(t *testing.T) {
		d := nextStepFixture(t)
		d.Accommodations = nil
		d.BookingTodos = []store.BookingTodo{
			{ID: uuid.New(), Kind: "stay", TodoKey: "stay:lyon", Title: "Stay in Lyon",
				Auto: true, Position: 0,
				DepartDate: dateVal(t, "2026-09-03"), ReturnDate: dateVal(t, "2026-09-04")},
		}
		step, _ := derive("en", nextStepNow, d)
		if !strings.Contains(step.Detail, "No lodging booked for the night of") {
			t.Fatalf("detail = %q, want the single-night copy", step.Detail)
		}
	})
}

// Display copy localizes; the chat seed stays canonical English (it is agent
// input, not display copy).
func TestNextStep_WalkSpanishTitle(t *testing.T) {
	d := nextStepFixture(t)
	d.BookingTodos = walkTodos(t)
	step, _ := derive("es", nextStepNow, d)
	if step == nil || step.Title != "Reserva tu vuelo a Paris" {
		t.Fatalf("es title = %+v", step)
	}
	if !strings.Contains(step.SeedPrompt, "I still need transport") {
		t.Fatalf("seed must stay canonical English:\n%s", step.SeedPrompt)
	}
}

// --- later phases --------------------------------------------------------------

func TestNextStep_ScheduleCleanup_Unscheduled(t *testing.T) {
	d := nextStepFixture(t)
	d.Items = append(d.Items, store.ItineraryItem{
		ID: uuid.New(), Name: "Bouchon dinner", City: strp("Lyon"), Position: 5}) // day nil
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "schedule_items", 3)
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
	mustStep(t, step, progress, "schedule_items", 3)
	if step.Day == nil || *step.Day != 2 {
		t.Fatalf("day anchor = %v, want 2 (first empty day)", step.Day)
	}
	if step.Count != nil {
		t.Fatalf("count should be nil when nothing is unscheduled, got %v", step.Count)
	}
	if !strings.Contains(step.SeedPrompt, "day 2 is empty") {
		t.Fatalf("empty-day seed off:\n%s", step.SeedPrompt)
	}
	// The rung says "Plan your days" when a day is what's missing; "Tidy up
	// your schedule" is for loose places, and this trip has none.
	if step.Title != "Plan your days" {
		t.Fatalf("empty-day step title = %q", step.Title)
	}
}

// The regression this whole change exists for (Brian, 2026-08-14): a dated
// multi-city trip whose only itinerary rows are the AI's city fillers — the
// tiles the app HIDES. The old ladder read "some item has a day", checked
// "Plan your days" off, and moved on; the traveler had planned nothing.
//
// The rung the traveler is on must not move, though: they are booking eleven
// flights, and holding booking guidance hostage to day planning would be a
// worse ladder than the wrong checkmark.
func TestNextStep_CityFillersAreNotAPlannedDay(t *testing.T) {
	d := nextStepFixture(t)
	// One filler per city, on the day the traveler arrives there — exactly what
	// create_itinerary emits for a day with no specific activities.
	d.Items = []store.ItineraryItem{
		{ID: uuid.New(), Name: "Paris", City: strp("Paris"), Day: i32p(1), Position: 1},
		{ID: uuid.New(), Name: "Lyon", City: strp("Lyon"), Day: i32p(3), Position: 2},
	}

	// Rung 2 still passes — a filler IS a destination pin, and the rung is
	// named for adding those. Rung 3 (booking) is where the traveler stands.
	open := d
	open.Accommodations, open.Segments, open.BookingTodos = nil, nil, nil
	step, progress := derive("en", nextStepNow, open)
	mustStep(t, step, progress, "add_lodging", 2)

	// …and the day rung reports the truth underneath it: nothing planned, out
	// of the trip's three plannable days (4-day span minus the departure day).
	tally := rungTally(t, progress, planPhaseSchedule)
	if tally == nil || tally.Done != 0 || tally.Total != 3 {
		t.Fatalf("schedule tally = %+v, want 0 of 3", tally)
	}

	// With the booking rung closed (the fixture's booked stays and segment) the
	// ladder stops AT the day rung rather than sailing past it to "all set".
	step, progress = derive("en", nextStepNow, d)
	mustStep(t, step, progress, "schedule_items", 3)
	if step.Title != "Plan your days" {
		t.Fatalf("step title = %q, want the day rung's own name", step.Title)
	}

	// One real activity does NOT re-satisfy the rung: the old min..max window
	// would have collapsed to that single day and declared the trip scheduled.
	d.Items = append(d.Items, store.ItineraryItem{
		ID: uuid.New(), Name: "Louvre", City: strp("Paris"), Day: i32p(1), Position: 3})
	step, progress = derive("en", nextStepNow, d)
	mustStep(t, step, progress, "schedule_items", 3)
	if tally := rungTally(t, progress, planPhaseSchedule); tally == nil || tally.Done != 1 {
		t.Fatalf("schedule tally = %+v, want 1 planned day", tally)
	}
	if step.Day == nil || *step.Day != 2 {
		t.Fatalf("day anchor = %v, want the first day with nothing on it", step.Day)
	}
}

// Travel days are planned days: the traveller is on a train, and a rung that
// called that "nothing planned" would trade one lie for another.
func TestNextStep_TravelDayCountsAsPlanned(t *testing.T) {
	d := nextStepFixture(t)
	d.Items = []store.ItineraryItem{
		{ID: uuid.New(), Name: "Louvre", City: strp("Paris"), Day: i32p(1), Position: 1},
		{ID: uuid.New(), Name: "Vieux Lyon", City: strp("Lyon"), Day: i32p(3), Position: 2},
	}
	// Day 2 is empty…
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "schedule_items", 3)

	// …until the Paris→Lyon train is a real booked segment ON it.
	d.Segments[0].DepartDate = dateVal(t, "2026-09-02")
	step, progress = derive("en", nextStepNow, d)
	mustStep(t, step, progress, "all_set", planLadderTotal)
	if tally := rungTally(t, progress, planPhaseSchedule); tally == nil ||
		tally.Done != tally.Total {
		t.Fatalf("schedule tally = %+v, want every plannable day planned", tally)
	}

	// An auto (itinerary-seeded draft) segment is not a booking anyone made,
	// so it must not silently fill the day either.
	d.Segments[0].Auto = true
	step, progress = derive("en", nextStepNow, d)
	mustStep(t, step, progress, "schedule_items", 3)
}

func TestNextStep_BookAggregateDedupe(t *testing.T) {
	d := nextStepFixture(t)
	d.Accommodations[0].Booked = false // open Paris stay (server-truth row)
	d.BookingTodos = []store.BookingTodo{
		// Claimed by the Paris stay above (same city) — must NOT double count.
		{ID: uuid.New(), Kind: "stay", TodoKey: "stay:paris", Title: "Stay in Paris"},
		// Booked, so the walk is satisfied and phase 5 can be reached; a booked
		// row never counts here either.
		{ID: uuid.New(), Kind: "transport", TodoKey: "transport:lyon>>nice",
			Title: "Lyon → Nice", Booked: true},
		{ID: uuid.New(), Kind: "stay", TodoKey: "stay:lyon", Title: "Stay in Lyon", Booked: true},
		// Custom rows are not slots — the aggregate is where they surface.
		{ID: uuid.New(), Kind: "other", TodoKey: "custom:abc", Title: "Rent a car"},
	}
	step, progress := derive("en", nextStepNow, d)
	mustStep(t, step, progress, "book_trip", 4)
	if step.Count == nil || *step.Count != 2 {
		t.Fatalf("count = %v, want 2 (stay row + custom todo)", step.Count)
	}
	if !strings.Contains(step.SeedPrompt, "Hotel Le Marais, Paris") ||
		!strings.Contains(step.SeedPrompt, "Rent a car") ||
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
	mustStep(t, step, progress, "add_packing", 5)
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
// keeps the check_hours=true and =false cache variants in agreement. Asserted
// on both phase-3 paths — the walk reads exportData only, so its invariance is
// structural, and the fallback must not be swayed by a noisier findings list.
func TestNextStep_IgnoresWeatherAndHoursFindings(t *testing.T) {
	day1 := 1
	noise := []Finding{
		{Severity: "info", Category: "weather", Message: "Rain likely on Day 1.", Day: &day1},
		{Severity: "warn", Category: "hours", Message: "Louvre may be closed.", Day: &day1},
	}
	cases := []struct {
		name string
		data func(t *testing.T) exportData
		want string
	}{
		{name: "fallback path", want: "book_trip", data: func(t *testing.T) exportData {
			d := nextStepFixture(t)
			d.Accommodations[0].Booked = false
			return d
		}},
		{name: "walk path", want: "add_transport", data: func(t *testing.T) exportData {
			d := nextStepFixture(t)
			d.BookingTodos = walkTodos(t)
			return d
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			d := tc.data(t)
			findings := reviewTrip(context.Background(), "en", d, reviewOptions{}, reviewDeps{})
			noisy := append(append([]Finding{}, noise...), findings...)

			base, baseProg := deriveNextStep("en", nextStepNow, d, findings)
			withNoise, noiseProg := deriveNextStep("en", nextStepNow, d, noisy)
			if base == nil || withNoise == nil || base.Kind != withNoise.Kind || base.Kind != tc.want {
				t.Fatalf("kinds diverge: %+v vs %+v", base, withNoise)
			}
			if baseProg.Done != noiseProg.Done {
				t.Fatalf("progress diverges: %d vs %d", baseProg.Done, noiseProg.Done)
			}
		})
	}
}

// The ladder on the wire (specs/next-step-cta): ids are the stable identity
// clients and tests key on — they do NOT move with the copy or the locale —
// while labels are localized display text. Pinned end to end because the
// progress sheet renders these labels in this order and nothing else.
func TestNextStep_LadderPhases(t *testing.T) {
	d := nextStepFixture(t)
	d.Accommodations[0].Booked = false // any mid-ladder step will do

	_, en := derive("en", nextStepNow, d)
	_, es := derive("es", nextStepNow, d)
	if en == nil || es == nil {
		t.Fatalf("progress = %v / %v, want both", en, es)
	}
	mustLadder(t, en)
	mustLadder(t, es)

	wantIDs := []string{"dates", "itinerary", "bookings", "schedule", "confirm", "packing"}
	// A rung's label is a promise about its TEST. Rung 2 asks only whether some
	// place sits on some day, so it says "Add your destinations"; the "Plan your
	// days" promise belongs to rung 4, the one that walks the days (Brian,
	// 2026-08-14 — ten city pins over 37 empty days used to check rung 2 off).
	wantEN := []string{
		"Set your travel dates",
		"Add your destinations",
		"Book travel & stays",
		"Plan your days",
		"Book everything",
		"Start your packing list",
	}
	for i := range wantIDs {
		if en.Phases[i].ID != wantIDs[i] || es.Phases[i].ID != wantIDs[i] {
			t.Fatalf("phase %d ids = %q/%q, want %q",
				i, en.Phases[i].ID, es.Phases[i].ID, wantIDs[i])
		}
		if en.Phases[i].Label != wantEN[i] {
			t.Fatalf("phase %d en label = %q, want %q", i, en.Phases[i].Label, wantEN[i])
		}
		if es.Phases[i].Label == en.Phases[i].Label {
			t.Fatalf("phase %d (%s) is not translated: %q", i, wantIDs[i], es.Phases[i].Label)
		}
	}
}

// The bookings rung reports how much of ITSELF is done — the sub-progress a
// 10-city trip needs, because "3 of 6" cannot move while eleven slots close
// one by one (Brian, 2026-08-14). The tally comes from the same walk that
// picks the step, so it counts a slot closed either way the walk closes it:
// checked off, or claimed by a real accommodation/segment.
func TestNextStep_BookingsTally(t *testing.T) {
	base := nextStepFixture(t)

	t.Run("counts closed slots anywhere in the list", func(t *testing.T) {
		d := base
		d.Accommodations, d.Segments = nil, nil // nothing claimed; boxes only
		// Close the FIRST and LAST of the five slots: the walk must keep
		// counting past the open one in between.
		d.BookingTodos = bookSlots(walkTodos(t), "transport:ewr>>paris", "transport:lyon>>ewr")
		step, progress := derive("en", nextStepNow, d)
		mustStep(t, step, progress, "add_lodging", 2) // first open slot: stay in Paris
		if tally := bookingsTally(t, progress); tally == nil || tally.Done != 2 || tally.Total != 5 {
			t.Fatalf("tally = %+v, want 2/5", tally)
		}
	})

	t.Run("a claimed slot counts as done", func(t *testing.T) {
		d := base
		// Not one box is checked, yet the fixture's two booked stays cover
		// every Paris and Lyon night and its booked segment connects them —
		// three slots CLAIMED. The tally must agree with the walk's own
		// definition of closed, not with the checkboxes.
		d.BookingTodos = walkTodos(t)
		step, progress := derive("en", nextStepNow, d)
		mustStep(t, step, progress, "add_transport", 2) // the unclaimed outbound leg
		if tally := bookingsTally(t, progress); tally == nil || tally.Done != 3 || tally.Total != 5 {
			t.Fatalf("tally = %+v, want 3/5 (2 stays + 1 leg claimed)", tally)
		}
	})

	t.Run("a satisfied rung reads full", func(t *testing.T) {
		d := base
		d.BookingTodos = bookSlots(walkTodos(t),
			"transport:ewr>>paris", "stay:paris", "transport:paris>>lyon",
			"stay:lyon", "transport:lyon>>ewr")
		step, progress := derive("en", nextStepNow, d)
		// Phase 3 is satisfied, so the ladder has moved on — and the rung
		// behind it reads 5/5 rather than going silent.
		if step == nil || step.Kind == "add_lodging" || step.Kind == "add_transport" {
			t.Fatalf("step = %+v, want the ladder past phase 3", step)
		}
		if tally := bookingsTally(t, progress); tally == nil || tally.Done != 5 || tally.Total != 5 {
			t.Fatalf("tally = %+v, want 5/5", tally)
		}
	})

	t.Run("no derived slots, no tally", func(t *testing.T) {
		d := base
		d.Accommodations[0].Booked = false // findings-fallback trip, phase 3 via findings
		_, progress := derive("en", nextStepNow, d)
		if tally := bookingsTally(t, progress); tally != nil {
			t.Fatalf("tally = %+v, want none (no derived slots to count)", tally)
		}
	})

	t.Run("rides along on an earlier phase", func(t *testing.T) {
		d := base
		d.Accommodations, d.Segments = nil, nil
		d.Trip.StartDate = pgtype.Date{}
		d.Trip.EndDate = pgtype.Date{}
		d.BookingTodos = bookSlots(walkTodos(t), "transport:ewr>>paris")
		step, progress := derive("en", nextStepNow, d)
		mustStep(t, step, progress, "set_dates", 0)
		if tally := bookingsTally(t, progress); tally == nil || tally.Done != 1 || tally.Total != 5 {
			t.Fatalf("tally = %+v, want 1/5 even at phase 1", tally)
		}
	})
}
