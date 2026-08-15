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

// exportFixtureTrip builds a dated trip with a day-tagged item, a stay, and a
// segment so both export formats have something to render. Returns the trip.
func exportFixtureTrip(t *testing.T, owner uuid.UUID, title string) store.Trip {
	t.Helper()
	ctx := context.Background()
	q := store.New(dbPool)
	chat := title + "-chat"
	trip, err := q.CreateTrip(ctx, store.CreateTripParams{
		UserID: owner, Title: title, ChatID: &chat,
	})
	if err != nil {
		t.Fatalf("CreateTrip: %v", err)
	}
	start := pgDate(t, "2026-08-01")
	end := pgDate(t, "2026-08-05")
	if _, err := q.UpdateTrip(ctx, store.UpdateTripParams{
		ID: trip.ID, UserID: owner, StartDate: start, EndDate: end,
	}); err != nil {
		t.Fatalf("UpdateTrip dates: %v", err)
	}
	day := int32(2)
	city := "Athens"
	tod := "morning"
	rec := "Maria"
	if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
		TripID: trip.ID, Position: 0, Name: "Acropolis, & the Parthenon; ruins",
		Latitude: 37.97, Longitude: 23.72,
		Day: &day, City: &city, TimeOfDay: &tod, LocalSourceName: &rec,
	}); err != nil {
		t.Fatalf("CreateItineraryItem: %v", err)
	}
	if _, err := q.CreateAccommodation(ctx, store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Hotel Grande Bretagne",
		CheckIn: pgDate(t, "2026-08-01"), CheckOut: pgDate(t, "2026-08-05"),
	}); err != nil {
		t.Fatalf("CreateAccommodation: %v", err)
	}
	if _, err := q.CreateSegment(ctx, store.CreateSegmentParams{
		TripID: trip.ID, Mode: "flight", Origin: strp("JFK"), Destination: strp("ATH"),
		DepartDate: pgDate(t, "2026-08-01"), ArriveDate: pgDate(t, "2026-08-01"),
	}); err != nil {
		t.Fatalf("CreateSegment: %v", err)
	}
	final, err := q.GetTripByIDAndOwner(ctx, store.GetTripByIDAndOwnerParams{ID: trip.ID, UserID: owner})
	if err != nil {
		t.Fatalf("reload trip: %v", err)
	}
	return final
}

func pgDate(t *testing.T, s string) pgtype.Date {
	t.Helper()
	tm, err := time.Parse("2006-01-02", s)
	if err != nil {
		t.Fatalf("parse date %q: %v", s, err)
	}
	return pgtype.Date{Time: tm, Valid: true}
}

func TestExportToken_RequiresAuthAndOwnership(t *testing.T) {
	resetDB(t)
	owner, ownerTok := createTestUser(t, "owner@example.com")
	_, strangerTok := createTestUser(t, "stranger@example.com")
	trip := createTestTrip(t, owner.ID, 1)

	// Anonymous → 401.
	if rec := doJSON(t, "POST", "/api/v1/trips/"+trip.ID.String()+"/export-token", "", nil); rec.Code != 401 {
		t.Fatalf("anonymous export-token: got %d want 401", rec.Code)
	}
	// Non-owner → 404 (editableTrip hides existence).
	if rec := doJSON(t, "POST", "/api/v1/trips/"+trip.ID.String()+"/export-token", strangerTok, nil); rec.Code != 404 {
		t.Fatalf("non-owner export-token: got %d want 404", rec.Code)
	}
	// Owner → 200 with a token + expiry.
	rec := doJSON(t, "POST", "/api/v1/trips/"+trip.ID.String()+"/export-token", ownerTok, nil)
	if rec.Code != 200 {
		t.Fatalf("owner export-token: got %d want 200 (%s)", rec.Code, rec.Body.String())
	}
	m := decode(t, rec)
	if _, ok := m["token"].(string); !ok || m["token"] == "" {
		t.Fatalf("missing token in %v", m)
	}
	if _, ok := m["expires_at"].(string); !ok {
		t.Fatalf("missing expires_at in %v", m)
	}
	// The minted token must verify back to this trip.
	if id, ok := verifyExportToken(m["token"].(string)); !ok || id != trip.ID {
		t.Fatalf("minted token did not verify to trip")
	}
}

func TestExportPrintView_RendersAndEscapes(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "printer@example.com")
	trip := exportFixtureTrip(t, owner.ID, "<script>alert(1)</script> Trip")
	token, _ := newExportToken(trip.ID)

	rec := doJSON(t, "GET", "/api/v1/export/"+token+"/print.html", "", nil)
	if rec.Code != 200 {
		t.Fatalf("print.html: got %d want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
		t.Fatalf("print.html content-type: %q", ct)
	}
	body := rec.Body.String()
	// Title present but the <script> escaped, never raw.
	if strings.Contains(body, "<script>alert(1)</script>") {
		t.Fatal("print.html leaked an unescaped <script> title")
	}
	if !strings.Contains(body, "&lt;script&gt;") {
		t.Fatal("print.html did not render the escaped title")
	}
	// Day header + item name.
	if !strings.Contains(body, "Day 2") {
		t.Fatal("print.html missing day header")
	}
	if !strings.Contains(body, "Acropolis") {
		t.Fatal("print.html missing item name")
	}
	if !strings.Contains(body, "Recommended by Maria") {
		t.Fatal("print.html missing local attribution")
	}
}

// TestExportPrintView_DayPacket exercises the day-by-day packet layout
// (specs/print-travel-packet): summary, per-day sections with weather and
// tonight's stay, unscheduled items, booking details, and the budget table.
func TestExportPrintView_DayPacket(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "packet@example.com")
	ctx := context.Background()
	q := store.New(dbPool)

	summary := "A slow loop through Athens with a Delphi day trip."
	chat := "packet-chat"
	trip, err := q.CreateTrip(ctx, store.CreateTripParams{
		UserID: owner.ID, Title: "Packet Trip", ChatID: &chat, Summary: &summary,
	})
	if err != nil {
		t.Fatalf("CreateTrip: %v", err)
	}
	if _, err := q.UpdateTrip(ctx, store.UpdateTripParams{
		ID: trip.ID, UserID: owner.ID,
		StartDate: pgDate(t, "2026-08-01"), EndDate: pgDate(t, "2026-08-05"),
	}); err != nil {
		t.Fatalf("UpdateTrip dates: %v", err)
	}

	day := int32(2)
	city := "Athens"
	rec := "Maria"
	if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
		TripID: trip.ID, Position: 0, Name: "Acropolis", Latitude: 37.97, Longitude: 23.72,
		Day: &day, City: &city, LocalSourceName: &rec,
	}); err != nil {
		t.Fatalf("create day item: %v", err)
	}
	// No day ⇒ Unscheduled section.
	if _, err := q.CreateItineraryItem(ctx, store.CreateItineraryItemParams{
		TripID: trip.ID, Position: 1, Name: "Someday Taverna", Latitude: 37.97, Longitude: 23.73,
		City: &city,
	}); err != nil {
		t.Fatalf("create unscheduled item: %v", err)
	}

	stayURL := "https://www.booking.com/hotel/gr/grande.html?aid=42"
	stayPrice := "€180/night"
	if _, err := q.CreateAccommodation(ctx, store.CreateAccommodationParams{
		TripID: trip.ID, Name: "Hotel Grande Bretagne",
		Url: &stayURL, PriceNote: &stayPrice,
		CheckIn: pgDate(t, "2026-08-01"), CheckOut: pgDate(t, "2026-08-05"),
	}); err != nil {
		t.Fatalf("create stay: %v", err)
	}

	provider := "Hellenic Train"
	segPrice := "€25"
	seg, err := q.CreateSegment(ctx, store.CreateSegmentParams{
		TripID: trip.ID, Mode: "train", Origin: strp("Athens"), Destination: strp("Kalambaka"),
		DepartDate: pgDate(t, "2026-08-02"), ArriveDate: pgDate(t, "2026-08-02"),
		Provider: &provider, PriceNote: &segPrice,
	})
	if err != nil {
		t.Fatalf("create segment: %v", err)
	}
	booked := true
	if _, err := q.UpdateSegment(ctx, store.UpdateSegmentParams{
		ID: seg.ID, TripID: trip.ID, Booked: &booked,
	}); err != nil {
		t.Fatalf("book segment: %v", err)
	}

	target := 2000.0
	if _, err := q.UpsertBudget(ctx, store.UpsertBudgetParams{
		TripID: trip.ID, TargetAmount: &target, Currency: "EUR",
	}); err != nil {
		t.Fatalf("upsert budget: %v", err)
	}
	for i, e := range []struct {
		cat, label string
		amount     float64
	}{
		{"lodging", "Hotel Grande Bretagne", 600},
		{"food", "Tavernas", 150},
	} {
		if _, err := q.CreateExpense(ctx, store.CreateExpenseParams{
			TripID: trip.ID, Category: e.cat, Label: e.label,
			ActualAmount: ptrTo(e.amount), Position: int32(i),
		}); err != nil {
			t.Fatalf("create expense: %v", err)
		}
	}

	// Point the shared weather singleton at a stub double (idiom from
	// trip_review_integration_test.go); it serves both forecast and archive
	// paths, so the assertion is date-independent.
	prevWeather := weatherService
	weatherService = weatherStub(t, false, 30, 21)
	t.Cleanup(func() { weatherService = prevWeather })

	token, _ := newExportToken(trip.ID)
	res := doJSON(t, "GET", "/api/v1/export/"+token+"/print.html", "", nil)
	if res.Code != 200 {
		t.Fatalf("print.html: got %d want 200", res.Code)
	}
	body := res.Body.String()

	for _, want := range []string{
		summary,
		"Day 1 · Sat, Aug 1",
		"Day 2 · Sun, Aug 2 — Athens",
		"Day 5 · Wed, Aug 5",
		"Weather:", "°C",
		"Train · Athens → Kalambaka",
		"(booked)",
		"Hellenic Train", "€25",
		"Acropolis", "Recommended by Maria",
		"No plans yet for this day.",
		"Tonight: Hotel Grande Bretagne",
		"Check in today",
		"Check out Wed, Aug 5",
		"€180/night",
		"booking.com/hotel/gr/grande.html",
		"Unscheduled", "Someday Taverna",
		"Budget (EUR)", "Target: 2000.00",
		"Total spent: 750.00", "Remaining: 1250.00",
	} {
		if !strings.Contains(body, want) {
			t.Fatalf("print packet missing %q\n%s", want, body)
		}
	}

	// The stay covers nights 1–4 only; no "Tonight" block on the check-out day.
	if n := strings.Count(body, "Tonight: Hotel Grande Bretagne"); n != 4 {
		t.Fatalf("stay should appear on 4 nights, got %d", n)
	}
	// The raw booking URL query string must not leak into the visible text.
	if strings.Contains(body, "aid=42</a>") {
		t.Fatal("URL text should strip the query string")
	}
}

// TestExportPrintView_WeatherFailureIsSilent proves a dead weather upstream
// degrades to a page without weather lines, never an error.
func TestExportPrintView_WeatherFailureIsSilent(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "noweather@example.com")
	trip := exportFixtureTrip(t, owner.ID, "Stormy Trip")

	dead := NewWeatherService()
	dead.GeocodeBaseURL = "http://127.0.0.1:1"
	dead.ForecastBaseURL = "http://127.0.0.1:1"
	dead.ArchiveBaseURL = "http://127.0.0.1:1"
	prevWeather := weatherService
	weatherService = dead
	t.Cleanup(func() { weatherService = prevWeather })

	token, _ := newExportToken(trip.ID)
	res := doJSON(t, "GET", "/api/v1/export/"+token+"/print.html", "", nil)
	if res.Code != 200 {
		t.Fatalf("print.html with dead weather: got %d want 200", res.Code)
	}
	body := res.Body.String()
	if strings.Contains(body, "Weather:") {
		t.Fatal("weather line should be absent when the upstream is down")
	}
	if !strings.Contains(body, "Acropolis") || !strings.Contains(body, "Day 2") {
		t.Fatal("packet content should survive a weather outage")
	}
}

func TestExportPrintView_InvalidTokenIs404(t *testing.T) {
	resetDB(t)
	rec := doJSON(t, "GET", "/api/v1/export/not-a-real-token/print.html", "", nil)
	if rec.Code != 404 {
		t.Fatalf("invalid print token: got %d want 404", rec.Code)
	}
}

func TestExportCalendar_ICSShapeAndEscaping(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "ical@example.com")
	trip := exportFixtureTrip(t, owner.ID, "Greek Islands")
	token, _ := newExportToken(trip.ID)

	rec := doJSON(t, "GET", "/api/v1/export/"+token+"/calendar.ics", "", nil)
	if rec.Code != 200 {
		t.Fatalf("calendar.ics: got %d want 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/calendar") {
		t.Fatalf("calendar content-type: %q", ct)
	}
	if cd := rec.Header().Get("Content-Disposition"); !strings.Contains(cd, `filename="greek-islands.ics"`) {
		t.Fatalf("calendar content-disposition: %q", cd)
	}
	body := rec.Body.String()
	if n := strings.Count(body, "BEGIN:VEVENT"); n != 3 {
		t.Fatalf("expected 3 VEVENTs (item+stay+segment), got %d\n%s", n, body)
	}
	// The whole-trip import is labeled in the user's calendar.
	if !strings.Contains(body, "X-WR-CALNAME:Greek Islands") {
		t.Fatalf("missing calendar name; body:\n%s", body)
	}
	// Item is a TIMED floating event: day 2 → 2026-08-02, "morning" → 09:00–12:00.
	if !strings.Contains(body, "DTSTART:20260802T090000") || !strings.Contains(body, "DTEND:20260802T120000") {
		t.Fatalf("item timed DTSTART/DTEND wrong; body:\n%s", body)
	}
	if strings.Contains(body, "DTSTART:20260802T090000Z") {
		t.Fatalf("timed events must be floating (no Z); body:\n%s", body)
	}
	// Stay check-in 2026-08-01 stays all-day alongside the timed item.
	if !strings.Contains(body, "DTSTART;VALUE=DATE:20260801") {
		t.Fatalf("stay DTSTART wrong; body:\n%s", body)
	}
	// RFC escaping: "Acropolis, & the Parthenon; ruins" → comma & semicolon escaped.
	if !strings.Contains(body, `Acropolis\, & the Parthenon\; ruins`) {
		t.Fatalf("ICS TEXT escaping wrong; body:\n%s", body)
	}
	// CRLF line endings.
	if !strings.Contains(body, "\r\n") {
		t.Fatal("ICS not CRLF-terminated")
	}
}

func TestExportCalendar_InvalidTokenIs404(t *testing.T) {
	resetDB(t)
	rec := doJSON(t, "GET", "/api/v1/export/bogus.token/calendar.ics", "", nil)
	if rec.Code != 404 {
		t.Fatalf("invalid calendar token: got %d want 404", rec.Code)
	}
}

func TestExportEventCalendar_SingleEventAndOpaque404s(t *testing.T) {
	resetDB(t)
	owner, _ := createTestUser(t, "one-event@example.com")
	trip := exportFixtureTrip(t, owner.ID, "Greek Islands")
	token, _ := newExportToken(trip.ID)

	stays, err := store.New(dbPool).ListAccommodationsByTrip(context.Background(), trip.ID)
	if err != nil || len(stays) != 1 {
		t.Fatalf("fixture stays: %v (%d)", err, len(stays))
	}
	stayID := stays[0].ID.String()

	rec := doJSON(t, "GET", "/api/v1/export/"+token+"/event/stay/"+stayID+".ics", "", nil)
	if rec.Code != 200 {
		t.Fatalf("event stay.ics: got %d want 200 (%s)", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/calendar") {
		t.Fatalf("event content-type: %q", ct)
	}
	if cd := rec.Header().Get("Content-Disposition"); !strings.Contains(cd, `attachment; filename="stay-hotel-grande-bretagne.ics"`) {
		t.Fatalf("event content-disposition: %q", cd)
	}
	body := rec.Body.String()
	if n := strings.Count(body, "BEGIN:VEVENT"); n != 1 {
		t.Fatalf("expected exactly 1 VEVENT, got %d\n%s", n, body)
	}
	if !strings.Contains(body, "UID:acc-"+stayID+"@goldentempo") {
		t.Fatalf("event UID missing; body:\n%s", body)
	}

	// All failure shapes are one opaque 404, indistinguishable from a bad token.
	for name, path := range map[string]string{
		"bad token":    "/api/v1/export/bogus.token/event/stay/" + stayID + ".ics",
		"bogus uuid":   "/api/v1/export/" + token + "/event/stay/not-a-uuid.ics",
		"unknown id":   "/api/v1/export/" + token + "/event/stay/" + uuid.NewString() + ".ics",
		"unknown kind": "/api/v1/export/" + token + "/event/hovercraft/" + stayID + ".ics",
	} {
		rec := doJSON(t, "GET", path, "", nil)
		if rec.Code != 404 {
			t.Fatalf("%s: got %d want 404", name, rec.Code)
		}
		if got := rec.Body.String(); got != "export link not available" {
			t.Fatalf("%s: body %q not opaque", name, got)
		}
	}
}
