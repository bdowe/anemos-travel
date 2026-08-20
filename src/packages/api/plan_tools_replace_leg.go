package main

// replace_leg — swap ONE city of a saved trip for another without rewriting
// the trip.
//
// The tool exists because the sanctioned path for a swap was a whole-trip
// rewrite (update_itinerary_section scope 'trip'), and a whole-trip rewrite
// requires the model to re-author every position and every day number by hand.
// The same system prompt then warns that recomputing day numbers "will not
// produce the calendar dates you intend and can undo earlier date moves" — a
// contradiction no wording fixes, because both halves are true. Dogfooding it
// on 2026-08-20 fragmented four cities and moved two legs' dates, and the
// traveler watched the model hand-repair its own output.
//
// So the tool surface changes instead: the model supplies the new city's places
// in visit order, and the SERVER owns the positions and the day numbers
// (spliceLeg, replace_leg_splice.go). Fragmentation and date drift become
// unreachable rather than warned against.
//
// The write follows replaceTripSection's shape exactly — GetTripForUpdate to
// serialize against a concurrent rewrite, delete, dense 0-based reinsert,
// TouchTrip — but is spelled out here rather than delegated, because the
// clearing has to land in the SAME transaction and because the splice must run
// against items read UNDER the lock.
//
// Registry: one entry, appended at the tail (plan_tool_registry.go). The tools
// array is the Anthropic prompt-cache prefix, so a reorder silently destroys
// caching and no test fails.

import (
	"encoding/json"
	"fmt"
	"strings"

	anthropic "github.com/anthropics/anthropic-sdk-go"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

var replaceLegTool = anthropic.ToolParam{
	Name: "replace_leg",
	Description: anthropic.String("Swap ONE city of the traveler's saved trip for a different city, keeping everything else exactly where it is — 'replace Copenhagen with Belgrade', 'let's do Porto instead of Seville'. " +
		"This is the tool for a city swap. Do NOT use update_itinerary_section scope 'trip' for one: that rewrites the whole itinerary from your own day numbers, which fragments cities and moves other legs' dates. " +
		"Send the new city's places in visit order and nothing else — no other city's places, and no day numbers. THE SERVER ASSIGNS THE DAYS. Any `day` you send is ignored, on purpose: the leg keeps the exact trip days the old city occupied, which is what leaves every other city's dates and night counts untouched. " +
		"Send at least two places: the one they arrive at, and one easy place near their lodging for the day they move on to the next city. Those two days are shared with the neighbouring cities and are what date this leg. The days between them stay empty until the traveler asks you to fill that city. " +
		"Search for the new city's places first so they carry real coordinates. " +
		"It also removes what belonged to the old city — its stay, its transport in and out, its checklist rows — and the result names each one, so tell the traveler what was dropped and offer to rebook. " +
		"It does NOT change WHEN the leg happens: the new city inherits the old city's dates. If the traveler wants different dates or a different number of nights, call set_leg_dates after this, in the same turn. " +
		"To fill in a city that is already in the trip, use update_itinerary_section with scope 'city' instead — this tool is for changing WHICH city it is."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"city": map[string]any{
				"type":        "string",
				"description": "The city being replaced, exactly as it appears in the itinerary, e.g. 'Copenhagen'. If the trip visits that city twice, say which stay with 'Copenhagen#2' (the second one); the tool asks if you leave it ambiguous.",
			},
			"new_city": map[string]any{
				"type":        "string",
				"description": "The city replacing it, e.g. 'Belgrade'. Omit ONLY to re-place the same city with a different set of places — for that, prefer update_itinerary_section scope 'city'.",
			},
			"places": map[string]any{
				"type":        "array",
				"description": "The new city's places, in visit order. At least two: the arrival place and one easy place for the day they move on. Do NOT send a `day` — the server assigns it and anything you send is ignored. Every place must be in the new city, or be a day trip whose day_trip_from is the new city.",
				"items":       itineraryLocationSchema,
			},
		},
		Required: []string{"city", "places"},
	},
}

func runReplaceLegTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		City    string           `json:"city"`
		NewCity string           `json:"new_city"`
		Places  []map[string]any `json:"places"`
	}
	json.Unmarshal(input, &in)

	if s.boundTripID == nil {
		return "This session is not bound to a saved trip; replace_leg is unavailable. Propose the swap in your reply instead.", true
	}
	if dbPool == nil {
		return "Saved trips are unavailable right now (persistence offline).", true
	}
	tid := *s.boundTripID

	tx, err := dbPool.Begin(s.ctx)
	if err != nil {
		return "Could not change the trip right now.", true
	}
	defer tx.Rollback(s.ctx)
	q := store.New(tx)

	// The same row lock replaceTripSection, set_trip_dates and set_leg_dates
	// take: a concurrent whole-itinerary rewrite's delete would otherwise miss
	// rows inserted after our snapshot and leave both item sets merged.
	if _, err := q.GetTripForUpdate(s.ctx, tid); err != nil {
		return "Could not load the trip to change it.", true
	}
	items, err := q.GetItineraryItemsByTrip(s.ctx, tid)
	if err != nil {
		return "Could not load the trip's itinerary.", true
	}

	// Everything that can be rejected is rejected BEFORE the first write, so a
	// refusal leaves the trip untouched and the model can retry against a trip
	// that still matches what it read (spliceSection's contract, kept).
	splice, err := spliceLeg(items, in.City, in.NewCity, in.Places)
	if err != nil {
		return err.Error(), true
	}

	if err := q.DeleteItineraryItemsByTrip(s.ctx, tid); err != nil {
		return "Could not change the trip's itinerary.", true
	}
	for i, loc := range splice.Locations {
		if _, err := q.CreateItineraryItem(s.ctx, itemParamsFromLocation(tid, int32(i), loc)); err != nil {
			return "Could not change the trip's itinerary.", true
		}
	}

	// Only a real swap detaches anything. Re-placing a city with itself leaves
	// its stay, its transport and its checklist rows valid — clearing them
	// there would be destruction with no question behind it.
	var cleared clearedLeg
	if !splice.SameCity() {
		cleared, err = clearLegAttachments(s.ctx, q, tid, splice.OldHub)
		if err != nil {
			return "Could not remove what belonged to " + splice.OldHub + "; nothing was changed.", true
		}
	}

	if err := q.TouchTrip(s.ctx, store.TouchTripParams{
		ID: tid, UpdatedBy: pgtype.UUID{Bytes: s.uid, Valid: true},
	}); err != nil {
		return "Could not change the trip.", true
	}
	if err := tx.Commit(s.ctx); err != nil {
		return "Could not change the trip.", true
	}

	sendSSE(s.w, "trip_updated", map[string]string{"trip_id": tid.String()})
	s.itineraryEmitted = true
	s.tripID = &tid
	safeGo("recordEvent", func() {
		recordEvent(s.uid, "agent_leg_replaced", &tid, map[string]any{
			"from":             splice.OldHub,
			"to":               splice.NewHub,
			"places":           len(splice.Locations),
			"replaced_items":   splice.Replaced,
			"first_day":        splice.FirstDay,
			"last_day":         splice.LastDay,
			"stays_cleared":    len(cleared.Stays),
			"segments_cleared": len(cleared.Segments),
			"todos_cleared":    len(cleared.TodosDeleted),
			"todos_demoted":    len(cleared.TodosDemoted),
			"is_collaborator":  s.uid != s.boundTripOwnerID,
		})
	})
	// replaceTripSection's TouchTrip doesn't run through touchedBy, so the
	// collaborator-edit signal is sent here; the SQL self-gates for owners.
	if s.uid != s.boundTripOwnerID {
		safeGo("notifyCollabEdit", func() { notifyCollabEdit(tid, s.uid) })
	}

	return replaceLegResult(s, splice, cleared), false
}

// replaceLegResult states the post-state the traveler will SEE, not the change
// that was requested.
//
// The rendered legs come from computeTripLegs via tripPostStateRender — THE one
// derivation, the same one the page draws and the `legs` payload serializes —
// so a wrong day→date mental model cannot survive a successful call. This tool
// is the one place that matters most: its entire promise is "every other city
// held still", and the only honest way to make that checkable is to hand back
// the ranges. Best-effort, like the other writers': a failed read costs the
// extra sentences, never a write that already committed.
func replaceLegResult(s *planSession, splice legSplice, cleared clearedLeg) string {
	var b strings.Builder
	if splice.SameCity() {
		fmt.Fprintf(&b, "%s has been re-placed with %d place(s), keeping its trip days %d-%d.",
			splice.NewHub, len(splice.Days), splice.FirstDay, splice.LastDay)
	} else {
		fmt.Fprintf(&b, "%s is now %s, on the same trip days %d-%d the old city held — so no other city's dates or night counts changed.",
			splice.OldHub, splice.NewHub, splice.FirstDay, splice.LastDay)
	}
	b.WriteString(clearedLegText(splice.OldHub, cleared))

	legs, transport, open := tripPostStateRender(s, *s.boundTripID)
	if legs != "" {
		b.WriteString(" The page now renders these city legs:\n" + legs + open +
			"Check those against what the traveler asked for before you reply. If the dates are right but the LENGTH of this leg is wrong — they want more or fewer nights in " + splice.NewHub +
			" — call set_leg_dates for it now; do NOT resend the itinerary with recomputed day numbers.")
	}
	b.WriteString(transportEchoText(transport))
	b.WriteString(tripDescriptionEcho(s, *s.boundTripID))
	return b.String()
}
