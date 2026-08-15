package main

import (
	"fmt"
	"strings"

	"github.com/google/uuid"
)

// plan_spine.go — the boundary an itinerary write has to clear before anything
// is persisted (specs/shape-before-schedule).
//
// The planner now agrees a trip's SHAPE first and then saves a SPINE: every
// city with one place on the day the traveler arrives and one on the day they
// move on, and the days between deliberately empty. That is a good plan and a
// fragile one. A leg's calendar span is DERIVED from its items' day numbers
// (trip_render_legs.go), so a sparse itinerary rests each city's dates on two
// rows where a dense one had a dozen — and docs/zen.md is explicit that an
// invariant holding only by convention, through rows that can be deleted, is
// not an invariant.
//
// The three refusals below are the mistakes that are MECHANICAL: decidable from
// the tool input alone, with no judgement and no database read. They are
// refused BEFORE the write, so the model retries against an unchanged trip
// rather than reading about the damage afterwards.
//
// Each is scoped to the failure it actually prevents, not to a blanket
// requirement — an over-broad rule here would be the last-day arc's draft two,
// which banned museums on a whole departure day and was rightly disobeyed:
//
//   - end_date missing beside start_date. persistTrip derives a missing end as
//     start + (highest item day) - 1. On a dense itinerary the highest day was
//     the real last day; on a spine it is the FINAL city's ARRIVAL day, so the
//     trip saves days short — a one-city spine saves as a ONE-DAY trip — and
//     because the trip then genuinely ends early, the last-leg trip-end anchor
//     has nothing left to correct it against. Unconditional: whenever the write
//     dates the trip at all, it must date both ends.
//   - a dated trip with an undated place. computeTripLegs takes its item-day
//     branch only when the leg has a dated item AND the trip has a start date;
//     otherwise the leg falls through to the weighted auto-allocation, whose
//     weight is the item COUNT. Every city in a spine has the same count, so
//     that path renders an EQUAL SPLIT of the trip as though it were the nights
//     the traveler agreed to. Scoped to dated trips because on an undated draft
//     a day number dates nothing — which is a legitimate shape the "Add your
//     destinations" rung already exists for.
//   - a MIX of hub-tagged and untagged places. renderHubOf reads city and
//     day_trip_from and nothing else — it deliberately does not parse addresses
//     — so an untagged place among tagged ones becomes its own "Other places"
//     run with its own dates, splitting a city in half. Scoped to the mix
//     because an itinerary with no tags anywhere is one coherent unnamed run,
//     which is exactly what legacy and manually-built trips look like.
//
// Deliberately NOT refused: a city whose places sit on a single day. That is
// usually a missing move-on place and sometimes a genuine same-day stop, and
// no payload can tell the two apart. It gets the two honest channels instead —
// the warning line in the tool result (legsRenderSummary) and a Trip Health
// finding (checkLegShape) — rather than a guess dressed up as a rule.
//
// Coercion is NOT re-implemented here: every check reads the params
// itemParamsFromLocation already produces, so this file and storage cannot
// drift about what "has a day" or "has a hub" means.

// spineRefusalNamesMax caps how many offending places a refusal lists by name,
// so a forty-place payload still returns a readable tool result.
const spineRefusalNamesMax = 5

// itineraryWriteRefusal reports why an itinerary write cannot be persisted, or
// "" when it can. The string is model-facing and self-correcting: what is
// wrong, why it matters in terms of what the traveler would SEE, and the call
// that works — the shape errStraySectionItems established.
func itineraryWriteRefusal(startDate, endDate string, locations []map[string]any) string {
	dated := strings.TrimSpace(startDate) != ""

	if dated && strings.TrimSpace(endDate) == "" {
		return "end_date is required whenever you pass start_date. Without it the trip's end is derived from the highest day number in the itinerary — and on a spine that is the FINAL city's ARRIVAL day, not the day the traveler comes home, so the trip would be saved days short and its last city would render too few nights. Send create_itinerary again with both start_date and end_date, taken from the shape the traveler agreed to."
	}

	var undated, untagged []string
	tagged := 0
	for i, loc := range locations {
		p := itemParamsFromLocation(uuid.Nil, int32(i), loc)
		name := strings.TrimSpace(p.Name)
		if name == "" {
			name = fmt.Sprintf("place %d", i+1)
		}
		if p.Day == nil {
			undated = append(undated, name)
		}
		if p.City == nil && p.DayTripFrom == nil {
			untagged = append(untagged, name)
		} else {
			tagged++
		}
	}

	if dated && len(undated) > 0 {
		return fmt.Sprintf("Every place needs a day — the 1-based trip day it falls on — once the trip has dates. %s carr%s none. A city whose places are undated does not get its dates from them: it gets an equal share of the trip split between every city, which would show the traveler nights they never agreed to. Send create_itinerary again with a day on every place.",
			namesClause(undated), pluralCarry(len(undated)))
	}

	if tagged > 0 && len(untagged) > 0 {
		return fmt.Sprintf("Every place needs the city it is in — or day_trip_from when it is a day trip from the city the traveler is staying in. %s ha%s neither, while the rest of the itinerary is tagged. Places are grouped into city legs by exactly those two fields, so an untagged place among tagged ones becomes its own leg with its own dates and splits the trip. Send create_itinerary again with a city on every place.",
			namesClause(untagged), pluralHave(len(untagged)))
	}

	return ""
}

// namesClause renders an offending-place list, capped so the result stays
// readable: "Rijksmuseum, Vondelpark and 3 more".
func namesClause(names []string) string {
	if len(names) <= spineRefusalNamesMax {
		if len(names) == 1 {
			return names[0]
		}
		return strings.Join(names[:len(names)-1], ", ") + " and " + names[len(names)-1]
	}
	return fmt.Sprintf("%s and %d more", strings.Join(names[:spineRefusalNamesMax], ", "), len(names)-spineRefusalNamesMax)
}

func pluralCarry(n int) string {
	if n == 1 {
		return "ies"
	}
	return "y"
}

func pluralHave(n int) string {
	if n == 1 {
		return "s"
	}
	return "ve"
}
