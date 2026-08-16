package main

// set_trip_description — the planner's way to change a saved trip's description:
// the prose overview shown under its title on the trip page.
//
// Before specs/trip-description that overview was write-once. create_itinerary
// supplied it at creation and was then gated OFF for the rest of the trip's life
// (a refine session's only itinerary writer is update_itinerary_section, which
// never touches the trips row), so the sentence describing a three-city trip
// survived it growing to five — with no tool able to fix it and no line in
// get_trip for the model to even notice.
//
// Two things make this safe to hand a model. get_trip and every
// update_itinerary_section echo now carry tripDescriptionSummary, so a stale
// description is something the planner can SEE rather than something it must
// remember to reconsider. And `reason` is required: refreshing on its own
// initiative is refused against a description the traveler wrote, by the server,
// not by a sentence in the prompt that the model has to keep in mind.
//
// The write itself is applyTripSummary (trip_summary.go) — the same one the trip
// page's PATCH calls, so the page and the chat cannot drift about what changing a
// description means.

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/google/uuid"

	"travel-route-planner/store"
)

// The two reasons a description gets rewritten. They are not interchangeable:
// one is the traveler's instruction, the other is the planner's own judgement,
// and only the second can be wrong about whose words it is replacing.
const (
	summaryReasonAsked        = "traveler_asked"
	summaryReasonTripChanged  = "trip_changed"
	summaryDescriptionMaxHint = "a sentence or two"
)

var setTripDescriptionTool = anthropic.ToolParam{
	Name: "set_trip_description",
	Description: anthropic.String("Set or change the DESCRIPTION of the traveler's saved trip — the short prose overview shown under the trip's title on their trip page, the same text create_itinerary takes as `summary`. " +
		"It has nothing to do with any summary of this conversation. " +
		"Call it when they ask for different wording ('change the description to mention it's our anniversary'), and when a change you just made has left the description contradicting the trip — after adding or dropping a city, or moving the dates, a blurb that still describes the old shape is worse than none. " +
		"You can see the current description in get_trip and after every update_itinerary_section, so call this only when it is actually wrong, never to restate one that already fits. " +
		"Keep it to " + summaryDescriptionMaxHint + ": the trip page clamps it to two lines. " +
		"This changes ONE trip's description. It does not rename the trip — the title is a separate 3-6 word name."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"description": map[string]any{
				"type":        "string",
				"description": "The new description, in prose the traveler would recognize as being about their trip. Pass an empty string ONLY when they ask for the description to be removed.",
			},
			"reason": map[string]any{
				"type": "string",
				"enum": []string{summaryReasonAsked, summaryReasonTripChanged},
				"description": "Why you are writing it. '" + summaryReasonAsked + "' = the traveler asked for this wording or asked you to rewrite it. '" +
					summaryReasonTripChanged + "' = your own initiative, because the trip changed and the description no longer matches. Say which honestly: a description the traveler wrote themselves is left alone on your initiative, and rewritten only when they ask.",
			},
		},
		Required: []string{"description", "reason"},
	},
}

func runSetTripDescriptionTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		Description string `json:"description"`
		Reason      string `json:"reason"`
	}
	json.Unmarshal(input, &in)

	text, reason := strings.TrimSpace(in.Description), strings.TrimSpace(in.Reason)
	if reason != summaryReasonAsked && reason != summaryReasonTripChanged {
		return fmt.Sprintf("reason must be %q (the traveler asked) or %q (your own initiative because the trip changed). Nothing was changed.", summaryReasonAsked, summaryReasonTripChanged), true
	}
	// Clearing is the traveler's call, never the planner's: "the trip changed, so
	// I removed the description" is not a thing anyone asked for.
	if text == "" && reason != summaryReasonAsked {
		return "Nothing was changed. An empty description removes it, which only the traveler can ask for — pass the new wording, or call this with reason \"" + summaryReasonAsked + "\" if they asked you to take it off.", true
	}
	if n := utf8.RuneCountInString(text); n > maxSummaryLen {
		return summaryTooLongReply(n), true
	}
	if !s.authed {
		return "The traveler isn't signed in, so there's no saved trip to change. Describe the trip in your reply instead.", true
	}
	if dbPool == nil {
		return "Saved trips are unavailable right now (persistence offline).", true
	}

	// Unlike set_trip_origin there is nothing to carry on the session for a trip
	// that doesn't exist yet: create_itinerary already takes `summary`, so a
	// second way to pre-stage the same string would be a second writer of it.
	tripID, msg, failed := resolveDateShiftTrip(s)
	if failed {
		if strings.Contains(msg, "No trip has been saved") {
			return "No trip has been saved in this conversation yet, so there is no description to change. Pass `summary` to create_itinerary when you save the plan instead.", true
		}
		return msg, true
	}

	tx, err := dbPool.Begin(s.ctx)
	if err != nil {
		return "Could not update the trip's description right now.", true
	}
	defer tx.Rollback(s.ctx)
	q := store.New(tx)

	// The row lock the decision needs, not just the write: reading the author on
	// an unlocked row would let a concurrent edit slip in between "the assistant
	// wrote this" and the overwrite that relies on it.
	trip, err := q.GetTripForUpdate(s.ctx, tripID)
	if err != nil {
		return "Could not load the trip to update its description.", true
	}
	// The one refusal that matters: the traveler's own words are not the
	// planner's to replace on a hunch. Stored, not inferred (migration 00070) —
	// a prompt rule the model must remember is not an invariant.
	if reason == summaryReasonTripChanged && travelerWroteSummary(trip) {
		return travelerAuthoredReply(trip), true
	}

	applied, err := applyTripSummary(s.ctx, q, trip, text, summarySourceAgent, s.uid)
	if err != nil {
		return "Could not save the trip's description.", true
	}
	if err := tx.Commit(s.ctx); err != nil {
		return "Could not save the trip's description.", true
	}

	sendSSE(s.w, "trip_updated", map[string]string{"trip_id": tripID.String()})
	s.tripID = &tripID
	ownerID := trip.UserID
	safeGo("recordEvent", func() {
		recordEvent(s.uid, "agent_trip_description_set", &tripID, map[string]any{
			"reason":          reason,
			"cleared":         applied.cleared,
			"length":          utf8.RuneCountInString(applied.summary),
			"is_collaborator": s.uid != ownerID,
		})
	})
	if s.uid != ownerID {
		safeGo("notifyCollabEdit", func() { notifyCollabEdit(tripID, s.uid) })
	}

	// State the post-state, not "done": the stored text, quoted, so a wrong idea
	// of what the trip now says cannot survive a successful call (docs/zen.md).
	if applied.cleared {
		return "The trip's description has been removed, at the traveler's request. Their trip page has refreshed and now shows just the title and dates.", false
	}
	return fmt.Sprintf("The trip's description now reads: %q. The traveler's trip page has refreshed. Don't repeat it back to them verbatim — they can see it — and don't call this again unless it stops matching the trip.", applied.summary), false
}

// tripDescriptionEcho is the line an itinerary writer's result carries so a
// reshape hands the model the description it may have just invalidated. This is
// what makes the refresh a reaction to something visible rather than a rule the
// model has to remember — the same trick legTransportSummary plays for leg modes.
//
// Emitted only when there IS a description: "none yet" on every section edit
// would be noise, and get_trip already states all four cases in full.
// Best-effort, like tripLegsRender — a read error degrades to saying nothing,
// never to failing a write that already committed.
func tripDescriptionEcho(s *planSession, tripID uuid.UUID) string {
	if dbPool == nil {
		return ""
	}
	trip, err := store.New(dbPool).GetEditableTripByID(s.ctx, store.GetEditableTripByIDParams{ID: tripID, UserID: s.uid})
	if err != nil || strings.TrimSpace(strPtrVal(trip.Summary)) == "" {
		return ""
	}
	return " " + tripDescriptionSummary(trip) +
		" If the trip you just changed no longer matches that, fix it with set_trip_description; if it still fits, leave it alone."
}
