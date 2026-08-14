package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5"

	"travel-route-planner/store"
)

var allowedBudgets = map[string]bool{"budget": true, "mid": true, "luxury": true}
var allowedPaces = map[string]bool{"relaxed": true, "balanced": true, "packed": true}
var allowedWorkStyles = map[string]bool{"digital_nomad": true, "workation": true, "leisure_only": true}

// "none" is a real answer, not an absence: it says the traveler has been asked
// and keeps no routine, so the agent should stop volunteering gyms and runs.
// (It also happens to be the one choice field on this profile with a way back
// to "no" — see specs/active-profile on the shared clear-to-unknown wart.)
var allowedFitnessRoutines = map[string]bool{"gym": true, "running": true, "both": true, "none": true}

// How demanding an active outing should be. Orthogonal to pace, which is how
// MANY things happen in a day rather than how hard they are.
var allowedOutdoorIntensities = map[string]bool{"easy": true, "moderate": true, "challenging": true}

var allowedCompanions = map[string]bool{"solo": true, "partner": true, "friends": true, "family_with_kids": true, "varies": true}

type PreferencesResponse struct {
	Budget           *string  `json:"budget"`
	Pace             *string  `json:"pace"`
	Interests        []string `json:"interests"`
	HomeAirport      *string  `json:"home_airport"`
	ProfileNotes     *string  `json:"profile_notes"`
	WorkStyle        *string  `json:"work_style"`
	FitnessRoutine   *string  `json:"fitness_routine"`
	OutdoorIntensity *string  `json:"outdoor_intensity"`
	Companions       *string  `json:"companions"`
}

type PutPreferencesRequest struct {
	Budget *string `json:"budget"`
	Pace   *string `json:"pace"`
	// Pointer distinguishes omitted (nil -> keep) from cleared ([] -> clear).
	Interests   *[]string `json:"interests"`
	HomeAirport *string   `json:"home_airport"`
	// Pointer distinguishes omitted (nil -> keep) from cleared ("" -> clear).
	ProfileNotes     *string `json:"profile_notes"`
	WorkStyle        *string `json:"work_style"`
	FitnessRoutine   *string `json:"fitness_routine"`
	OutdoorIntensity *string `json:"outdoor_intensity"`
	Companions       *string `json:"companions"`
}

func toPreferencesResponse(p store.TravelerPreference) PreferencesResponse {
	interests := p.Interests
	if interests == nil {
		interests = []string{}
	}
	return PreferencesResponse{
		Budget:           p.Budget,
		Pace:             p.Pace,
		Interests:        interests,
		HomeAirport:      p.HomeAirport,
		ProfileNotes:     p.ProfileNotes,
		WorkStyle:        p.WorkStyle,
		FitnessRoutine:   p.FitnessRoutine,
		OutdoorIntensity: p.OutdoorIntensity,
		Companions:       p.Companions,
	}
}

func getPreferencesHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	user, _ := userFromContext(r.Context())
	p, err := store.New(dbPool).GetPreferences(r.Context(), user.ID)
	if errors.Is(err, pgx.ErrNoRows) {
		writeJSON(w, http.StatusOK, PreferencesResponse{Interests: []string{}})
		return
	}
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load preferences")
		return
	}
	writeJSON(w, http.StatusOK, toPreferencesResponse(p))
}

func putPreferencesHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	user, _ := userFromContext(r.Context())

	var req PutPreferencesRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}

	budget, err := normalizeChoice(req.Budget, allowedBudgets, "budget")
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	pace, err := normalizeChoice(req.Pace, allowedPaces, "pace")
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	workStyle, err := normalizeChoice(req.WorkStyle, allowedWorkStyles, "work_style")
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	fitnessRoutine, err := normalizeChoice(req.FitnessRoutine, allowedFitnessRoutines, "fitness_routine")
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	outdoorIntensity, err := normalizeChoice(req.OutdoorIntensity, allowedOutdoorIntensities, "outdoor_intensity")
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	companions, err := normalizeChoice(req.Companions, allowedCompanions, "companions")
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}

	homeAirport, err := normalizeAirportCode(req.HomeAirport)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}

	// nil interests -> leave unchanged; provided (incl. empty) -> set/clear.
	var interestsArg interface{}
	if req.Interests != nil {
		interestsArg = normalizeInterests(*req.Interests)
	}

	p, err := store.New(dbPool).UpsertPreferences(r.Context(), store.UpsertPreferencesParams{
		UserID:           user.ID,
		Budget:           budget,
		Pace:             pace,
		Interests:        interestsArg,
		HomeAirport:      homeAirport,
		ProfileNotes:     normalizeNotes(req.ProfileNotes),
		WorkStyle:        workStyle,
		FitnessRoutine:   fitnessRoutine,
		OutdoorIntensity: outdoorIntensity,
		Companions:       companions,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not save preferences")
		return
	}
	writeJSON(w, http.StatusOK, toPreferencesResponse(p))
}

// normalizeChoice lowercases/trims a choice field. Empty -> nil (omit, keep
// existing); an unrecognized value -> error.
func normalizeChoice(v *string, allowed map[string]bool, field string) (*string, error) {
	if v == nil {
		return nil, nil
	}
	s := strings.ToLower(strings.TrimSpace(*v))
	if s == "" {
		return nil, nil
	}
	if !allowed[s] {
		return nil, errors.New(field + " is not a recognized value")
	}
	return &s, nil
}

// normalizeAirportCode validates and upper-cases a home airport. Empty/nil ->
// nil (omit, keep existing); anything other than a 3-letter IATA code -> error.
func normalizeAirportCode(v *string) (*string, error) {
	if v == nil {
		return nil, nil
	}
	s := strings.ToUpper(strings.TrimSpace(*v))
	if s == "" {
		return nil, nil
	}
	if len(s) != 3 || !isAlpha(s) {
		return nil, errors.New("home_airport must be a 3-letter IATA code")
	}
	return &s, nil
}

const maxProfileNotesLen = 2000

// normalizeNotes trims and caps the AI-maintained profile notes. nil -> nil
// (omit, keep existing); a provided value — including "" — replaces, so the
// user can clear notes. Truncation counts runes to avoid splitting characters.
func normalizeNotes(v *string) *string {
	if v == nil {
		return nil
	}
	s := strings.TrimSpace(*v)
	if r := []rune(s); len(r) > maxProfileNotesLen {
		s = string(r[:maxProfileNotesLen])
	}
	return &s
}

// normalizeInterests trims, drops blanks, and de-duplicates (case-insensitive,
// order-preserving). Always returns a non-nil slice so an empty input clears.
func normalizeInterests(in []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, s := range in {
		t := strings.TrimSpace(s)
		if t == "" {
			continue
		}
		key := strings.ToLower(t)
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, t)
	}
	return out
}
