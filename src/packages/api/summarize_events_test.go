package main

import (
	"strings"
	"testing"
)

func summarizeEventsFixture() []Event {
	return []Event{
		{
			ID:        "e1",
			Name:      "Berliner Philharmoniker",
			Category:  "Music",
			Venue:     "Philharmonie",
			StartDate: "2026-09-01",
			StartTime: "20:00",
		},
		{
			ID:        "e2",
			Name:      "Romeo & Julia",
			Category:  "Arts & Theatre",
			Venue:     "Globe Berlin",
			StartDate: "2026-09-04",
			StartTime: "19:30",
		},
	}
}

func TestSummarizeEventsListsWhenAndWhere(t *testing.T) {
	text := summarizeEvents("Berlin", summarizeEventsFixture())

	for _, want := range []string{
		"Found 2 events in Berlin",
		"1. Berliner Philharmoniker — 2026-09-01 20:00 @ Philharmonie (Music)",
		"2. Romeo & Julia — 2026-09-04 19:30 @ Globe Berlin (Arts & Theatre)",
		"name the date and venue",
	} {
		if !strings.Contains(text, want) {
			t.Errorf("events summary missing %q:\n%s", want, text)
		}
	}
}

// Events are a live lookup with no persistence anywhere: no itinerary item can
// hold one (allowedItemCategories is {attraction, restaurant}) and no table
// stores them. A closing line claiming otherwise lets the model tell a
// traveler their events were saved. Twin of the same guard in
// TestSummarizeOffersOneWaySolo.
func TestSummarizeEventsDoesNotClaimPersistence(t *testing.T) {
	text := summarizeEvents("Berlin", summarizeEventsFixture())

	if strings.Contains(text, "saved with their trip") {
		t.Errorf("nothing persists these events; the closing line must not claim so:\n%s", text)
	}
	if !strings.Contains(text, "Nothing here is saved") {
		t.Errorf("the closing line must say the listings are not saved:\n%s", text)
	}
}

func TestSummarizeEventsEmpty(t *testing.T) {
	text := summarizeEvents("Berlin", nil)

	if want := "No events found in Berlin for those dates."; text != want {
		t.Errorf("empty summary = %q, want %q", text, want)
	}
}

// The Flutter rail renders "30+ events" rather than "30" when a lookup comes
// back at exactly this many, because the response carries no total and the
// server truncates silently. Pinned on the Dart side by the matching
// expectation on kEventsServerCap in test/event_picks_test.dart — if one moves
// without the other, one of the two tests fails instead of the UI quietly
// claiming a total the server never promised.
func TestEventsServerCapIsThirty(t *testing.T) {
	if maxEvents != 30 {
		t.Errorf("maxEvents = %d; kEventsServerCap in the Flutter app mirrors this and must move with it", maxEvents)
	}
}
