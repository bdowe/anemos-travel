package main

// set_trip_dates (specs/set-trip-dates): the /plan agent's way to move or set
// WHEN a saved trip happens. Shifting the anchor without the dated children
// would strand every stay, leg, and booking to-do on the old dates, so the
// whole trip moves by one day-delta in a single transaction. The tool is
// gated authedOnly (per-conversation stable, prompt-cache safe); which trip
// it targets is resolved here at call time instead — the bound trip, the trip
// create_itinerary persisted earlier this request, or the chat lineage's
// newest version on a later turn of the same conversation.

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"

	anthropic "github.com/anthropics/anthropic-sdk-go"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

var setTripDatesTool = anthropic.ToolParam{
	Name: "set_trip_dates",
	Description: anthropic.String("Move or set the travel dates of the traveler's saved trip. " +
		"Call it when they change when the trip happens — 'shift everything a week later', 'we now leave June 12' — or when a dateless trip finally gets dates. " +
		"It moves the WHOLE trip in one step: the trip's start/end plus every dated stay, transport leg, and booking to-do shift by the same number of days — never rebuild itinerary sections just to change dates. " +
		"Omit end_date to keep the trip the same length. " +
		"It only changes the saved plan: anything already booked with a real provider keeps its original dates, so remind the traveler to re-check those bookings. " +
		"For a plan not saved yet, pass the dates to create_itinerary instead."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"start_date": map[string]any{
				"type":        "string",
				"description": "The trip's new first day as YYYY-MM-DD (day 1 of the itinerary)",
			},
			"end_date": map[string]any{
				"type":        "string",
				"description": "Optional new last day as YYYY-MM-DD; omit to preserve the trip's current length (or derive it from the itinerary's day span). Must not be before start_date.",
			},
		},
		Required: []string{"start_date"},
	},
}

// computeTripDateShift decides the new end date and the whole-trip day delta.
// A nil newEnd preserves the old duration when both old dates exist, else
// derives from maxDay (start + maxDay - 1; maxDay is clamped to >= 1, the
// same derivation persistTrip uses). deltaDays is 0 when the trip had no
// previous start date (no anchor to shift children from). All values are
// civil dates carried as UTC midnights, so hour math is exact — no DST.
func computeTripDateShift(oldStart, oldEnd pgtype.Date, newStart time.Time, newEnd *time.Time, maxDay int) (end time.Time, deltaDays int, hadAnchor bool, err error) {
	if maxDay < 1 {
		maxDay = 1
	}
	switch {
	case newEnd != nil:
		end = *newEnd
	case oldStart.Valid && oldEnd.Valid:
		end = newStart.Add(oldEnd.Time.Sub(oldStart.Time))
	default:
		end = newStart.AddDate(0, 0, maxDay-1)
	}
	if end.Before(newStart) {
		return time.Time{}, 0, false, fmt.Errorf("end_date must not be before start_date")
	}
	if oldStart.Valid {
		hadAnchor = true
		deltaDays = int(newStart.Sub(oldStart.Time).Hours() / 24)
	}
	return end, deltaDays, hadAnchor, nil
}

// resolveDateShiftTrip picks which trip a set_trip_dates call targets. The
// registry gate is authedOnly (stable per conversation), so trip availability
// is enforced here: the bound trip when refining, the trip this request
// already persisted, or — on a later turn of a fresh chat — the newest
// version of the conversation's lineage (owner-scoped by construction).
func resolveDateShiftTrip(s *planSession) (uuid.UUID, string, bool) {
	q := store.New(dbPool)
	if s.boundTripID != nil {
		tid := *s.boundTripID
		if _, err := q.GetEditableTripByID(s.ctx, store.GetEditableTripByIDParams{ID: tid, UserID: s.uid}); err != nil {
			return uuid.Nil, "That trip can't be edited by this traveler.", true
		}
		return tid, "", false
	}
	if s.tripID != nil {
		if _, err := q.GetTripByIDAndOwner(s.ctx, store.GetTripByIDAndOwnerParams{ID: *s.tripID, UserID: s.uid}); err == nil {
			return *s.tripID, "", false
		}
	}
	if chatID := strings.TrimSpace(s.req.ChatID); chatID != "" {
		if versions, err := q.ListTripVersionsByChat(s.ctx, store.ListTripVersionsByChatParams{UserID: s.uid, ChatID: &chatID}); err == nil && len(versions) > 0 {
			return versions[0].ID, "", false
		}
	}
	return uuid.Nil, "No trip has been saved in this conversation yet. Pass start_date (and end_date) to create_itinerary when you save the plan instead.", true
}

func runSetTripDatesTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		StartDate string `json:"start_date"`
		EndDate   string `json:"end_date"`
	}
	json.Unmarshal(input, &in)

	if !s.authed {
		return "The traveler isn't signed in, so there's no saved trip to change. Give the advice in your reply instead.", true
	}
	if dbPool == nil {
		return "Saved trips are unavailable right now (persistence offline).", true
	}

	start, err := parseDateParam(&in.StartDate)
	if err != nil || !start.Valid {
		return "start_date is required and must be YYYY-MM-DD.", true
	}
	var newEnd *time.Time
	if endParam, err := parseDateParam(&in.EndDate); err != nil {
		return "end_date must be YYYY-MM-DD.", true
	} else if endParam.Valid {
		newEnd = &endParam.Time
	}

	tid, msg, failed := resolveDateShiftTrip(s)
	if failed {
		return msg, true
	}

	tx, err := dbPool.Begin(s.ctx)
	if err != nil {
		return "Could not update the trip dates right now.", true
	}
	defer tx.Rollback(s.ctx)
	q := store.New(tx)

	// Same row lock replaceTripSection takes: serializes date shifts against
	// concurrent whole-itinerary rewrites (and other shifts) on this trip.
	trip, err := q.GetTripForUpdate(s.ctx, tid)
	if err != nil {
		return "Could not load the trip to update its dates.", true
	}

	// The end-date derivation needs the itinerary's day span only when the
	// old duration is unknown and the model omitted end_date.
	maxDay := 1
	if newEnd == nil && !(trip.StartDate.Valid && trip.EndDate.Valid) {
		if items, err := q.GetItineraryItemsByTrip(s.ctx, tid); err == nil {
			for _, it := range items {
				if it.Day != nil && int(*it.Day) > maxDay {
					maxDay = int(*it.Day)
				}
			}
		}
	}

	end, deltaDays, hadAnchor, err := computeTripDateShift(trip.StartDate, trip.EndDate, start.Time, newEnd, maxDay)
	if err != nil {
		return err.Error() + ".", true
	}

	if err := q.SetTripDates(s.ctx, store.SetTripDatesParams{
		ID:        tid,
		StartDate: start,
		EndDate:   pgtype.Date{Time: end, Valid: true},
	}); err != nil {
		return "Could not update the trip dates.", true
	}

	var stays, legs, todos int64
	if hadAnchor && deltaDays != 0 {
		days := int32(deltaDays)
		if stays, err = q.ShiftAccommodationDates(s.ctx, store.ShiftAccommodationDatesParams{TripID: tid, Days: days}); err != nil {
			return "Could not shift the trip's stays with the dates.", true
		}
		if legs, err = q.ShiftSegmentDates(s.ctx, store.ShiftSegmentDatesParams{TripID: tid, Days: days}); err != nil {
			return "Could not shift the trip's transport legs with the dates.", true
		}
		if todos, err = q.ShiftBookingTodoDates(s.ctx, store.ShiftBookingTodoDatesParams{TripID: tid, Days: days}); err != nil {
			return "Could not shift the trip's booking to-dos with the dates.", true
		}
	}
	if err := q.TouchTrip(s.ctx, store.TouchTripParams{
		ID: tid, UpdatedBy: pgtype.UUID{Bytes: s.uid, Valid: true},
	}); err != nil {
		return "Could not update the trip dates.", true
	}
	if err := tx.Commit(s.ctx); err != nil {
		return "Could not update the trip dates.", true
	}

	sendSSE(s.w, "trip_updated", map[string]string{"trip_id": tid.String()})
	s.itineraryEmitted = true
	s.tripID = &tid
	ownerID := trip.UserID
	safeGo("recordEvent", func() {
		recordEvent(s.uid, "agent_trip_dates_set", &tid, map[string]any{
			"delta_days":      deltaDays,
			"stays":           stays,
			"segments":        legs,
			"todos":           todos,
			"is_collaborator": s.uid != ownerID,
		})
	})
	// Same collaborator-edit signal as touchTripAs; self-gated in SQL for
	// owner actors.
	if s.uid != ownerID {
		safeGo("notifyCollabEdit", func() { notifyCollabEdit(tid, s.uid) })
	}

	rangeText := start.Time.Format(dateLayout) + " to " + end.Format(dateLayout)
	switch {
	case !hadAnchor:
		return fmt.Sprintf("Trip dates set to %s. The trip had no dates before, so existing stays, transport legs, and booking to-dos were not moved — check whether any of their dates need updating (update_booking_todo etc.). The traveler's trip page has refreshed.", rangeText), false
	case deltaDays == 0:
		return fmt.Sprintf("Trip dates are now %s (the start is unchanged, so stays, legs, and to-dos were not moved). The traveler's trip page has refreshed.", rangeText), false
	default:
		direction := "later"
		n := deltaDays
		if n < 0 {
			direction = "earlier"
			n = -n
		}
		return fmt.Sprintf("Trip dates are now %s (moved %d day(s) %s). Shifted with the trip: %d stay(s), %d transport leg(s), %d booking to-do(s); undated ones were left untouched. IMPORTANT: anything already booked with a real provider (flights, hotels, ferries) still holds its ORIGINAL dates — remind the traveler to re-check and rebook those. The traveler's trip page has refreshed.", rangeText, n, direction, stays, legs, todos), false
	}
}
