package main

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"unicode"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"golang.org/x/text/runes"
	"golang.org/x/text/transform"
	"golang.org/x/text/unicode/norm"

	"travel-route-planner/store"
)

// itineraryLocationSchema is the JSON schema for a single itinerary place, shared
// by the create_itinerary and update_itinerary_section tools so the two writers
// accept the same shape.
var itineraryLocationSchema = map[string]any{
	"type": "object",
	"properties": map[string]any{
		"name":     map[string]any{"type": "string"},
		"place_id": map[string]any{"type": "string"},
		"address":  map[string]any{"type": "string"},
		"city": map[string]any{
			"type":        "string",
			"description": "The city/town the place is physically located in — use the actual municipality, not the nearest major city (e.g. 'Versailles', not 'Paris'). Used to group the itinerary by city.",
		},
		"day_trip_from": map[string]any{
			"type":        "string",
			"description": "If this place is a day trip from the city the traveler is staying in (a nearby town visited and returned from the same day, e.g. Versailles from Paris), set this to that hub city's name. Leave unset for places in the city you're staying in.",
		},
		"latitude":  map[string]any{"type": "number"},
		"longitude": map[string]any{"type": "number"},
		"category": map[string]any{
			"type":        "string",
			"enum":        []string{"attraction", "restaurant"},
			"description": "What kind of place this is — 'attraction' for sights/activities, 'restaurant' for places to eat.",
		},
		"time_of_day": map[string]any{
			"type":        "string",
			"enum":        []string{"morning", "afternoon", "evening"},
			"description": "Which part of the day to do this — spread a day's places sensibly (sights/activities across morning–afternoon, meals at their natural times).",
		},
		"day": map[string]any{
			"type":        "integer",
			"description": "The trip day this place belongs to, starting at 1 and increasing chronologically across the whole trip; all places on the same day share the same number (e.g. days 1–3 in Paris, then day 4 onward in Rome). Combined with time_of_day this makes each day read as a sequential schedule. A city's LAST day is the day the traveler leaves it, so it holds at most one easy nearby place — and the trip's final day, the journey home, usually holds none at all unless you know they travel late.",
		},
		"local_source_name": map[string]any{
			"type":        "string",
			"description": "If this place came from a search_local_recommendations result, the name of the local who recommended it (the 'source_name' field). Carry it through so the saved trip credits them.",
		},
		"local_recommendation_id": map[string]any{
			"type":        "string",
			"description": "If this place came from a search_local_recommendations result, its 'id' field. Links the itinerary item back to the local pin.",
		},
	},
	"required": []string{"name", "latitude", "longitude"},
}

// sectionSelector targets one slice of a saved itinerary for in-place
// replacement: a single day (optionally qualified by city, since day numbers
// can repeat across cities in legacy trips), one city/hub including its day
// trips, or the whole trip.
type sectionSelector struct {
	Scope string // "day" | "city" | "trip"
	Day   *int
	City  string
}

// sectionKey is the (hub, day) pair every section decision turns on — the ONE
// shape both a stored item and an agent location map reduce to, so membership
// is decided in exactly one place. A stored item and a submitted location must
// never be judged by two predicates that can drift apart: that drift is what let
// a city rewrite splice in another city's places and duplicate them.
type sectionKey struct {
	Hub string // day_trip_from when set, else city; trimmed. "" = unspecified.
	Day *int   // nil = unscheduled/unspecified.
}

// keyOfItem mirrors the Flutter app's _hubOf grouping: an item belongs to its
// day-trip hub when set, otherwise its own city.
func keyOfItem(it store.ItineraryItem) sectionKey {
	k := sectionKey{}
	if it.DayTripFrom != nil {
		k.Hub = strings.TrimSpace(*it.DayTripFrom)
	}
	if k.Hub == "" && it.City != nil {
		k.Hub = strings.TrimSpace(*it.City)
	}
	if it.Day != nil {
		d := int(*it.Day)
		k.Day = &d
	}
	return k
}

// keyOfLocation is [keyOfItem] for the agent's location-map shape. The field
// coercion matches itemParamsFromLocation exactly (JSON numbers decode as
// float64; day < 1 is "unspecified"), so the guard can never reject on a value
// the writer would itself have ignored.
func keyOfLocation(loc map[string]any) sectionKey {
	k := sectionKey{}
	if s, ok := loc["day_trip_from"].(string); ok {
		k.Hub = strings.TrimSpace(s)
	}
	if k.Hub == "" {
		if s, ok := loc["city"].(string); ok {
			k.Hub = strings.TrimSpace(s)
		}
	}
	if v, ok := loc["day"].(float64); ok && v >= 1 {
		d := int(v)
		k.Day = &d
	}
	return k
}

// hubOfItem is the hub half of [keyOfItem], kept for describeSections and the
// repair subcommand.
func hubOfItem(it store.ItineraryItem) string { return keyOfItem(it).Hub }

// foldHub normalizes a hub name for comparison: trimmed, and stripped of
// combining marks so "Kraków" and "Krakow" are one city. The model routinely
// re-types city names it read back from get_trip, and a trip cannot plausibly
// hold both spellings as distinct hubs.
//
// The transformer chain is built per call on purpose: transform.Chain is
// stateful, and a hoisted package-level one would corrupt across concurrent
// /plan requests.
func foldHub(s string) string {
	t := transform.Chain(
		norm.NFD,
		runes.Remove(runes.In(unicode.Mn)),
		norm.NFC,
	)
	out, _, err := transform.String(t, strings.TrimSpace(s))
	if err != nil {
		return strings.TrimSpace(s)
	}
	return out
}

// sameHub compares two hub names for SECTION SELECTION: trimmed,
// case-insensitive and diacritic-insensitive. Deliberately more lenient than the
// run split in computeTripLegs (plain EqualFold) — selection and the guard must
// never reject an edit the traveler plainly meant, whereas the split only
// decides where a rendered leg breaks.
func sameHub(a, b string) bool {
	return strings.EqualFold(foldHub(a), foldHub(b))
}

// matchesKey is THE section-membership predicate.
func (sel sectionSelector) matchesKey(k sectionKey) bool {
	switch sel.Scope {
	case "trip":
		return true
	case "day":
		if k.Day == nil || sel.Day == nil || *k.Day != *sel.Day {
			return false
		}
		if sel.City != "" {
			return sameHub(k.Hub, sel.City)
		}
		return true
	case "city":
		return sameHub(k.Hub, sel.City)
	}
	return false
}

func (sel sectionSelector) matches(it store.ItineraryItem) bool {
	return sel.matchesKey(keyOfItem(it))
}

// inheritUnset fills a submitted location's unspecified fields from the section
// it was submitted under, so "the model left it out" reads as "same as the
// section" rather than as a mismatch — locations carrying neither city nor day
// are the common shape from create_itinerary. This tolerance for omission, paired
// with strictness about contradiction, is the ONLY difference between how a
// stored item and a submitted location are judged.
func (k sectionKey) inheritUnset(sel sectionSelector) sectionKey {
	if k.Hub == "" {
		k.Hub = strings.TrimSpace(sel.City)
	}
	if k.Day == nil {
		k.Day = sel.Day
	}
	return k
}

// locationFromItem converts a stored item back into the agent's location map
// shape, so kept items and the model's replacements share one persist path.
func locationFromItem(it store.ItineraryItem) map[string]any {
	loc := map[string]any{
		"name":      it.Name,
		"latitude":  it.Latitude,
		"longitude": it.Longitude,
	}
	setStr := func(key string, v *string) {
		if v != nil && *v != "" {
			loc[key] = *v
		}
	}
	setStr("place_id", it.PlaceID)
	setStr("address", it.Address)
	setStr("city", it.City)
	setStr("day_trip_from", it.DayTripFrom)
	setStr("category", it.Category)
	setStr("time_of_day", it.TimeOfDay)
	if it.Day != nil {
		// JSON numbers decode as float64; keep the shape consistent for
		// itemParamsFromLocation.
		loc["day"] = float64(*it.Day)
	}
	// Carry the local-source attribution snapshots so a section rewrite doesn't
	// silently strip credit from kept items.
	setStr("local_source_name", it.LocalSourceName)
	if it.LocalRecommendationID.Valid {
		loc["local_recommendation_id"] = uuid.UUID(it.LocalRecommendationID.Bytes).String()
	}
	return loc
}

// spliceSection returns the trip's full new ordered location list: items
// matching sel are removed and newLocs take their place at the position of the
// first match. Errors when a day/city selector matches nothing, listing the
// valid options so the calling model can self-correct.
func spliceSection(existing []store.ItineraryItem, sel sectionSelector, newLocs []map[string]any) ([]map[string]any, error) {
	switch sel.Scope {
	case "trip":
		return newLocs, nil
	case "day":
		if sel.Day == nil {
			return nil, fmt.Errorf("scope 'day' requires a day number")
		}
	case "city":
		if strings.TrimSpace(sel.City) == "" {
			return nil, fmt.Errorf("scope 'city' requires a city name")
		}
	default:
		return nil, fmt.Errorf("unknown scope %q (use 'day', 'city' or 'trip')", sel.Scope)
	}

	insertAt := -1
	var out []map[string]any
	for _, it := range existing {
		if sel.matches(it) {
			if insertAt == -1 {
				insertAt = len(out)
			}
			continue
		}
		out = append(out, locationFromItem(it))
	}
	if insertAt == -1 {
		return nil, fmt.Errorf("no itinerary items matched %s; the trip has %s", describeSelector(sel), describeSections(existing))
	}
	// Every submitted place must already belong to the targeted section. Items
	// outside it survive in `out`, so splicing them in from newLocs as well
	// DUPLICATES them rather than moving them — the bug that put a city in the
	// itinerary twice, once with the right dates and once collapsed to zero
	// nights. Checked after the miss error above (most specific first) and
	// before anything is written: replaceTripSection calls this before its
	// delete, so a rejection leaves the trip untouched.
	var strays []map[string]any
	for _, loc := range newLocs {
		if !sel.matchesKey(keyOfLocation(loc).inheritUnset(sel)) {
			strays = append(strays, loc)
		}
	}
	if len(strays) > 0 {
		return nil, errStraySectionItems(sel, newLocs, strays, existing)
	}
	spliced := make([]map[string]any, 0, len(out)+len(newLocs))
	spliced = append(spliced, out[:insertAt]...)
	spliced = append(spliced, newLocs...)
	spliced = append(spliced, out[insertAt:]...)
	return spliced, nil
}

func describeSelector(sel sectionSelector) string {
	if sel.Scope == "day" {
		s := fmt.Sprintf("day %d", *sel.Day)
		if sel.City != "" {
			s += " in " + sel.City
		}
		return s
	}
	return "city " + sel.City
}

// straySampleCap bounds how many offending places errStraySectionItems names, so
// a whole-itinerary mistake can't blow up the tool_result.
const straySampleCap = 4

// describeStrays names the offending places and the section each ACTUALLY
// belongs to, so the model can see which entries to move instead of guessing.
func describeStrays(strays []map[string]any) string {
	parts := make([]string, 0, straySampleCap)
	for _, loc := range strays {
		if len(parts) == straySampleCap {
			break
		}
		name, _ := loc["name"].(string)
		if name = strings.TrimSpace(name); name == "" {
			name = "(unnamed place)"
		}
		k := keyOfLocation(loc)
		where := k.Hub
		if where == "" {
			where = "no city"
		}
		when := "no day"
		if k.Day != nil {
			when = fmt.Sprintf("day %d", *k.Day)
		}
		parts = append(parts, fmt.Sprintf("%s (%s, %s)", name, where, when))
	}
	s := strings.Join(parts, ", ")
	if rest := len(strays) - len(parts); rest > 0 {
		s += fmt.Sprintf(" and %d more", rest)
	}
	return s
}

// errStraySectionItems is the self-correcting rejection for a section rewrite
// carrying places from OUTSIDE the section. Mirrors the miss error above: name
// what's wrong, name the valid options, name the tool call that works. Nothing
// has been written when this fires, so the model can retry against an unchanged
// trip.
func errStraySectionItems(sel sectionSelector, newLocs, strays []map[string]any, existing []store.ItineraryItem) error {
	hint := ""
	if city := strings.TrimSpace(sel.City); city != "" {
		hint = fmt.Sprintf(" (a nearby town counts as part of %s only when its day_trip_from is %q — set that and resend if that is what you meant)", city, city)
	}
	return fmt.Errorf("%d of the %d places sent are not in %s: %s%s; "+
		"update_itinerary_section replaces a section IN PLACE and cannot move places between sections — the places above would be duplicated, not moved, so nothing was changed. "+
		"To swap or reorder whole cities, or to move places from one city or day to another, call update_itinerary_section with scope 'trip' and the COMPLETE itinerary: every place in the trip, in the new order. "+
		"To change only this section, resend just the places that are in %s. The trip has %s",
		len(strays), len(newLocs), describeSelector(sel), describeStrays(strays), hint,
		describeSelector(sel), describeSections(existing))
}

// describeSections summarizes the days and hubs present in a trip for the
// model's error feedback.
func describeSections(items []store.ItineraryItem) string {
	daySet := map[int]bool{}
	hubSet := map[string]bool{}
	for _, it := range items {
		if it.Day != nil {
			daySet[int(*it.Day)] = true
		}
		if h := hubOfItem(it); h != "" {
			hubSet[h] = true
		}
	}
	days := make([]int, 0, len(daySet))
	for d := range daySet {
		days = append(days, d)
	}
	sort.Ints(days)
	hubs := make([]string, 0, len(hubSet))
	for h := range hubSet {
		hubs = append(hubs, h)
	}
	sort.Strings(hubs)
	return fmt.Sprintf("days %v and cities %v", days, hubs)
}

// itemParamsFromLocation coerces one agent/location map into insert params.
// Unknown category/time_of_day values are dropped rather than rejected, and
// only sensible 1-based day numbers are kept (JSON numbers decode as float64).
func itemParamsFromLocation(tripID uuid.UUID, position int32, loc map[string]any) store.CreateItineraryItemParams {
	name, _ := loc["name"].(string)
	lat, _ := loc["latitude"].(float64)
	lng, _ := loc["longitude"].(float64)
	params := store.CreateItineraryItemParams{
		TripID:    tripID,
		Position:  position,
		Name:      name,
		Latitude:  lat,
		Longitude: lng,
	}
	if s, ok := loc["place_id"].(string); ok && s != "" {
		params.PlaceID = &s
	}
	if s, ok := loc["address"].(string); ok && s != "" {
		params.Address = &s
	}
	if s, ok := loc["city"].(string); ok {
		if c := strings.TrimSpace(s); c != "" {
			params.City = &c
		}
	}
	if s, ok := loc["day_trip_from"].(string); ok {
		if d := strings.TrimSpace(s); d != "" {
			params.DayTripFrom = &d
		}
	}
	if s, ok := loc["category"].(string); ok {
		c := strings.ToLower(strings.TrimSpace(s))
		if allowedItemCategories[c] {
			params.Category = &c
		}
	}
	if s, ok := loc["time_of_day"].(string); ok {
		t := strings.ToLower(strings.TrimSpace(s))
		if allowedTimesOfDay[t] {
			params.TimeOfDay = &t
		}
	}
	if v, ok := loc["day"].(float64); ok && v >= 1 {
		d := int32(v)
		params.Day = &d
	}
	// Local-source attribution: snapshot the local's name so a saved trip still
	// credits them even if the underlying pin is later archived.
	if s, ok := loc["local_source_name"].(string); ok {
		if n := strings.TrimSpace(s); n != "" {
			params.LocalSourceName = &n
		}
	}
	if s, ok := loc["local_recommendation_id"].(string); ok {
		if id, err := uuid.Parse(strings.TrimSpace(s)); err == nil {
			params.LocalRecommendationID = pgtype.UUID{Bytes: id, Valid: true}
		}
	}
	return params
}

// replaceTripSection rewrites the trip's itinerary in one transaction: load the
// current items, splice the targeted section, then reinsert everything with a
// dense 0-based position sequence. Item ids are not stable across a rewrite;
// nothing external references them.
func replaceTripSection(ctx context.Context, tripID, actorID uuid.UUID, sel sectionSelector, newLocs []map[string]any) error {
	tx, err := dbPool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	q := store.New(tx)

	// Serialize whole-itinerary rewrites: a concurrent rewrite's delete would
	// miss rows inserted after our snapshot, leaving both item sets merged.
	if _, err := q.GetTripForUpdate(ctx, tripID); err != nil {
		return err
	}
	existing, err := q.GetItineraryItemsByTrip(ctx, tripID)
	if err != nil {
		return err
	}
	spliced, err := spliceSection(existing, sel, newLocs)
	if err != nil {
		return err
	}
	if err := q.DeleteItineraryItemsByTrip(ctx, tripID); err != nil {
		return err
	}
	for i, loc := range spliced {
		if _, err := q.CreateItineraryItem(ctx, itemParamsFromLocation(tripID, int32(i), loc)); err != nil {
			return err
		}
	}
	if err := q.TouchTrip(ctx, store.TouchTripParams{
		ID: tripID, UpdatedBy: pgtype.UUID{Bytes: actorID, Valid: true},
	}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
