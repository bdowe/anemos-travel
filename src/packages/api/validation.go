package main

import (
	"fmt"
	"strings"
	"unicode/utf8"
)

// validation.go — shared input validators and per-user/per-trip data-volume
// caps (Hardening PR3). The goal is narrow: reject obviously bad input
// (out-of-range coordinates, megabyte string sinks) and bound how much a single
// user or trip can store, so one client can't fill the disk or wedge the
// single-instance API. The length ceilings are deliberately generous — these
// are abuse/runaway guards, not product rules — and the data-volume caps are
// env-tunable via envInt (like the FREE_* knobs), read at call time.

// --- field length ceilings (rune counts). Generous by design. ---

const (
	maxNameLen        = 200  // titles, place names, cities, origins/destinations
	maxProviderLen    = 200  // provider labels
	maxAddressLen     = 500  // postal addresses
	maxURLLen         = 2000 // search/booking links
	maxNoteLen        = 5000 // price_note / free-text notes — the biggest sinks
	maxDisplayNameLen = 60   // mirror the account-update cap (account_handler.go)

	// maxItineraryDay bounds a manually-set day number. A floor of >= 1 already
	// exists in the item handlers; this is the missing ceiling. 366 covers a
	// year-plus trip with slack.
	maxItineraryDay = 366

	// maxLoggedDestinations bounds one manually logged trip (specs/log-past-trip).
	// Every destination is typed or tapped by hand, so this sits far above any
	// real entry — it exists only so a scripted client can't POST a 10k-element
	// array. Deliberately tighter than importMaxLocations (80): that path
	// transcribes a whole AI itinerary, this one records where someone went.
	maxLoggedDestinations = 50
)

// validateCoords enforces valid WGS84 ranges when coordinates are provided.
// Nil is allowed — coordinates are optional in several models (name-only
// resolution). Mirrors the bounds the /optimize-route and /plan paths use.
func validateCoords(lat, lng *float64) error {
	if lat != nil && (*lat < -90 || *lat > 90) {
		return fmt.Errorf("latitude must be between -90 and 90")
	}
	if lng != nil && (*lng < -180 || *lng > 180) {
		return fmt.Errorf("longitude must be between -180 and 180")
	}
	return nil
}

// boundedString trims val and enforces a max rune length, returning the trimmed
// value. It is for required fields the caller already trims + non-empty-checks;
// an over-length value yields a clear "field too long" 400.
func boundedString(field, val string, max int) (string, error) {
	v := strings.TrimSpace(val)
	if utf8.RuneCountInString(v) > max {
		return "", fmt.Errorf("%s too long (max %d characters)", field, max)
	}
	return v, nil
}

// boundedOptional length-checks an optional (pointer) string field without
// mutating it, so the handlers' existing nil-vs-empty semantics are untouched.
// Nil passes. It only rejects megabyte sinks.
func boundedOptional(field string, val *string, max int) error {
	if val == nil {
		return nil
	}
	if utf8.RuneCountInString(*val) > max {
		return fmt.Errorf("%s too long (max %d characters)", field, max)
	}
	return nil
}

// --- per-user / per-trip data-volume caps (runaway guards). Count-before-
// insert, generous defaults, env-tunable: count first, reject with a clear
// 422 when over. ---

const (
	defaultMaxTripsPerUser          = 200
	defaultMaxItemsPerTrip          = 500
	defaultMaxExpensesPerTrip       = 200
	defaultMaxSegmentsPerTrip       = 200
	defaultMaxAccommodationsPerTrip = 200
	defaultMaxChecklistItemsPerTrip = 200
	defaultMaxBookingTodosPerTrip   = 200
)

func maxTripsPerUser() int { return envInt("MAX_TRIPS_PER_USER", defaultMaxTripsPerUser) }
func maxItemsPerTrip() int { return envInt("MAX_ITEMS_PER_TRIP", defaultMaxItemsPerTrip) }
func maxExpensesPerTrip() int {
	return envInt("MAX_EXPENSES_PER_TRIP", defaultMaxExpensesPerTrip)
}
func maxSegmentsPerTrip() int {
	return envInt("MAX_SEGMENTS_PER_TRIP", defaultMaxSegmentsPerTrip)
}
func maxAccommodationsPerTrip() int {
	return envInt("MAX_ACCOMMODATIONS_PER_TRIP", defaultMaxAccommodationsPerTrip)
}
func maxChecklistItemsPerTrip() int {
	return envInt("MAX_CHECKLIST_ITEMS_PER_TRIP", defaultMaxChecklistItemsPerTrip)
}
func maxBookingTodosPerTrip() int {
	return envInt("MAX_BOOKING_TODOS_PER_TRIP", defaultMaxBookingTodosPerTrip)
}
