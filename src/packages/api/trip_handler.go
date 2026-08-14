package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/mux"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"golang.org/x/sync/errgroup"

	"travel-route-planner/store"
)

const dateLayout = "2006-01-02"

// --- response / request types ---

type ItineraryItemResponse struct {
	ID          string  `json:"id"`
	Position    int     `json:"position"`
	Name        string  `json:"name"`
	PlaceID     *string `json:"place_id,omitempty"`
	Address     *string `json:"address,omitempty"`
	Latitude    float64 `json:"latitude"`
	Longitude   float64 `json:"longitude"`
	Category    *string `json:"category,omitempty"`
	TimeOfDay   *string `json:"time_of_day,omitempty"`
	City        *string `json:"city,omitempty"`
	DayTripFrom *string `json:"day_trip_from,omitempty"`
	Day         *int    `json:"day,omitempty"`
	// Local-source attribution snapshots (specs/add-to-itinerary): who
	// recommended this place and which pin it came from. Nullable, no FK —
	// they survive pin archival by design.
	LocalSourceName       *string `json:"local_source_name,omitempty"`
	LocalRecommendationID *string `json:"local_recommendation_id,omitempty"`
}

var allowedItemCategories = map[string]bool{"attraction": true, "restaurant": true}

var allowedTimesOfDay = map[string]bool{"morning": true, "afternoon": true, "evening": true}

type TripResponse struct {
	ID             string                  `json:"id"`
	Title          string                  `json:"title"`
	Summary        *string                 `json:"summary,omitempty"`
	StartDate      *string                 `json:"start_date,omitempty"`
	EndDate        *string                 `json:"end_date,omitempty"`
	ChatID         *string                 `json:"chat_id,omitempty"`
	TravelMode     *string                 `json:"travel_mode,omitempty"`
	VersionCount   int                     `json:"version_count"`
	Cities         []string                `json:"cities,omitempty"`
	CreatedAt      time.Time               `json:"created_at"`
	UpdatedAt      time.Time               `json:"updated_at"`
	Items          []ItineraryItemResponse `json:"items,omitempty"`
	Accommodations []AccommodationResponse `json:"accommodations,omitempty"`
	Segments       []SegmentResponse       `json:"segments,omitempty"`
	BookingTodos   []BookingTodoResponse   `json:"booking_todos,omitempty"`
	// Access is "owner" or "editor" (collaborator). Absent on responses
	// that predate collaboration; clients treat missing as owner.
	Access    string  `json:"access,omitempty"`
	OwnerName *string `json:"owner_name,omitempty"` // set when access == "editor"
	// UpdatedByName attributes the last content edit ("Updated by Maria");
	// empty when unknown. Shared marks a trip that has active collaborators —
	// the owner's client polls /status only when set (editors always poll).
	UpdatedByName *string `json:"updated_by_name,omitempty"`
	Shared        bool    `json:"shared,omitempty"`
	// List-row enrichment (the laterals in ListLatestTripsByOwner /
	// ListLatestCollaboratedTripsForUser): total itinerary items,
	// booking-todo progress, and the insight fields below
	// (specs/trips-page-insights). Pointers so absence (full views, old
	// servers) is distinct from a real zero — "0/9 booked" and "0/2 stays"
	// must serialize. List responses only; full views carry the real arrays
	// and clients derive from those. Booking fields are nil'd for viewers
	// on shared-with-me (the getTripHandler visibility boundary); the
	// insight fields are owner-list only — shared-with-me rows carry NONE
	// of them (v1 exclusion, stricter than the viewer boundary).
	ItemCount     *int `json:"item_count,omitempty"`
	BookingTotal  *int `json:"booking_total,omitempty"`
	BookingBooked *int `json:"booking_booked,omitempty"`
	// Stays are CONFIRMED only (auto=false AND NOT dismissed — the
	// ListConfirmedAccommodationsByTrip rule; drafts churn with sync).
	StayTotal    *int `json:"stay_total,omitempty"`
	StayBooked   *int `json:"stay_booked,omitempty"`
	PackingTotal *int `json:"packing_total,omitempty"`
	PackingDone  *int `json:"packing_done,omitempty"`
	// Budget semantics match buildBudgetResponse: single currency, USD
	// default when no budget row exists.
	BudgetTarget   *float64 `json:"budget_target,omitempty"`   // nil = no target set
	BudgetSpent    *float64 `json:"budget_spent,omitempty"`    // nil = not a list row; 0 = nothing spent
	BudgetCurrency *string  `json:"budget_currency,omitempty"` // "USD" when no budget row
	// NextTransportDepart is YYYY-MM-DD, the earliest unbooked future
	// transport depart date (the booking-urgency nudge); absent when
	// nothing qualifies.
	NextTransportDepart *string `json:"next_transport_depart,omitempty"`
	// CityPins are the located hub cities in first-appearance order — a
	// subset of Cities: a hub whose items all carry the (0,0) no-location
	// sentinel is listed in Cities but never pinned.
	CityPins []CityPinResponse `json:"city_pins,omitempty"`
	// Legs is the server-computed city-leg view (specs/server-leg-dates):
	// the rendered date span per contiguous city run, from computeTripLegs —
	// the one derivation. Attached only on the full trip views (GET
	// /trips/{id} and the shared view), never on list/stub responses whose
	// partial data would yield anchor-less legs. Old clients ignore it.
	Legs []TripLegResponse `json:"legs,omitempty"`
}

// CityPinResponse is one located hub city on a list row (the travel-
// footprint map, specs/trips-page-insights). The coordinate is the hub's
// first item by position with non-(0,0) coords — computed inside the
// ListLatestTripsByOwner city lateral, the one derivation. A pin without
// coordinates is never emitted.
type CityPinResponse struct {
	City string  `json:"city"`
	Lat  float64 `json:"lat"`
	Lng  float64 `json:"lng"`
}

// TripLegResponse is one rendered city leg. Dates are YYYY-MM-DD; absent
// when the leg has no calendar span. See RenderLeg (trip_render_legs.go)
// for the field semantics.
type TripLegResponse struct {
	Key        string   `json:"key"`
	Label      string   `json:"label"`
	Hub        *string  `json:"hub,omitempty"`
	StartDate  *string  `json:"start_date,omitempty"`
	EndDate    *string  `json:"end_date,omitempty"`
	DateSource string   `json:"date_source,omitempty"`
	ZeroNight  bool     `json:"zero_night,omitempty"`
	FirstPos   int32    `json:"first_position"`
	LastPos    int32    `json:"last_position"`
	Lat        *float64 `json:"lat,omitempty"`
	Lng        *float64 `json:"lng,omitempty"`
}

// tripLegsResponse computes the legs payload for a full trip view.
func tripLegsResponse(t store.Trip, items []store.ItineraryItem, stays []store.Accommodation) []TripLegResponse {
	legs := computeTripLegs(t, items, stays)
	out := make([]TripLegResponse, 0, len(legs))
	for _, l := range legs {
		r := TripLegResponse{
			Key: l.Key, Label: l.Label, Hub: l.Hub,
			DateSource: l.DateSource, ZeroNight: l.ZeroNight,
			FirstPos: l.FirstPos, LastPos: l.LastPos,
			Lat: l.Lat, Lng: l.Lng,
		}
		if l.Start != nil {
			s := l.Start.Format(dateLayout)
			r.StartDate = &s
		}
		if l.End != nil {
			e := l.End.Format(dateLayout)
			r.EndDate = &e
		}
		out = append(out, r)
	}
	return out
}

// TripStatusResponse is the freshness-poll payload for shared trips.
type TripStatusResponse struct {
	UpdatedAt     time.Time `json:"updated_at"`
	UpdatedBy     *string   `json:"updated_by,omitempty"`
	UpdatedByName *string   `json:"updated_by_name,omitempty"`
}

// PatchTripRequest deliberately has no Status field: the draft/planned label
// is retired (specs/retire-trip-status). Stale clients that still send
// {"status": ...} are tolerated — the decoder ignores unknown keys.
type PatchTripRequest struct {
	Title     *string `json:"title"`
	StartDate *string `json:"start_date"`
	EndDate   *string `json:"end_date"`
	// TravelMode cannot be cleared back to NULL over PATCH (COALESCE update);
	// 'mixed' is the effective unset.
	TravelMode *string `json:"travel_mode"`
}

// allowedTravelModes are the trip-level travel_mode values: the segment modes
// (minus 'other') plus 'mixed' for genuinely multi-mode trips. NULL/unset
// keeps the legacy flight-default behavior in drafts, todos, and Trip Health.
var allowedTravelModes = map[string]bool{
	"flight": true, "car": true, "train": true, "bus": true, "ferry": true, "mixed": true,
}

// --- helpers ---

func dateToPtr(d pgtype.Date) *string {
	if !d.Valid {
		return nil
	}
	s := d.Time.Format(dateLayout)
	return &s
}

func int32PtrToIntPtr(p *int32) *int {
	if p == nil {
		return nil
	}
	v := int(*p)
	return &v
}

func pgUUIDToStringPtr(u pgtype.UUID) *string {
	if !u.Valid {
		return nil
	}
	s := uuid.UUID(u.Bytes).String()
	return &s
}

func toItineraryItemResponse(it store.ItineraryItem) ItineraryItemResponse {
	return ItineraryItemResponse{
		ID:                    it.ID.String(),
		Position:              int(it.Position),
		Name:                  it.Name,
		PlaceID:               it.PlaceID,
		Address:               it.Address,
		Latitude:              it.Latitude,
		Longitude:             it.Longitude,
		Category:              it.Category,
		TimeOfDay:             it.TimeOfDay,
		City:                  it.City,
		DayTripFrom:           it.DayTripFrom,
		Day:                   int32PtrToIntPtr(it.Day),
		LocalSourceName:       it.LocalSourceName,
		LocalRecommendationID: pgUUIDToStringPtr(it.LocalRecommendationID),
	}
}

// touchedBy builds TouchTrip params attributing a content edit to the
// request's signed-in user (the "Updated by X" line on shared trips). Only
// use on real user edits — see the TouchTrip query invariant.
//
// This is also the single choke point for the "a collaborator edited a shared
// trip" notification: every HTTP content mutation (itinerary items, budget,
// checklist, accommodations, segments, booking to-dos) stamps attribution
// through here, so a fire-and-forget notifyCollabEdit here covers all of them
// in one place. The write is self-gated in SQL — it no-ops for owner and solo
// edits and throttles per (trip, actor) — so firing it on every edit is safe
// and cheap. Firing here (as the params are built, just before the TouchTrip
// executes) is best-effort by design: a rare rolled-back edit could still
// notify, which is acceptable for an in-app signal.
func touchedBy(tripID uuid.UUID, r *http.Request) store.TouchTripParams {
	user, _ := userFromContext(r.Context())
	safeGo("notifyCollabEdit", func() { notifyCollabEdit(tripID, user.ID) })
	return store.TouchTripParams{ID: tripID, UpdatedBy: pgtype.UUID{Bytes: user.ID, Valid: true}}
}

func toTripResponse(t store.Trip, items []store.ItineraryItem, accommodations []store.Accommodation, segments []store.TripSegment, bookingTodos []store.BookingTodo) TripResponse {
	resp := TripResponse{
		ID:         t.ID.String(),
		Title:      t.Title,
		Summary:    t.Summary,
		StartDate:  dateToPtr(t.StartDate),
		EndDate:    dateToPtr(t.EndDate),
		ChatID:     t.ChatID,
		TravelMode: t.TravelMode,
		CreatedAt:  t.CreatedAt,
		UpdatedAt:  t.UpdatedAt,
	}
	for _, it := range items {
		resp.Items = append(resp.Items, toItineraryItemResponse(it))
	}
	for _, a := range accommodations {
		resp.Accommodations = append(resp.Accommodations, toAccommodationResponse(a))
	}
	for _, s := range segments {
		resp.Segments = append(resp.Segments, toSegmentResponse(s))
	}
	for _, bt := range bookingTodos {
		resp.BookingTodos = append(resp.BookingTodos, toBookingTodoResponse(bt))
	}
	return resp
}

// persistTrip saves a finalized itinerary as a Trip owned by userID, in a single
// transaction. Called from the agent's create_itinerary step for signed-in users.
// chatID stamps the trip with its conversation so My Trips can collapse repeated
// refinements to the latest version; an empty chatID is stored as NULL.
//
// newLineage reports whether this save started a brand-new trip lineage (as
// opposed to adding a version to an existing chat lineage). The caller uses
// it to gate the free-cap active_trips crossing signal, which a version save
// must never emit (specs/free-cap-instrumentation).
func persistTrip(ctx context.Context, userID uuid.UUID, chatID, title, summary, startDate, endDate, travelMode string, locations []map[string]any) (tripID string, newLineage bool, err error) {
	tx, err := dbPool.Begin(ctx)
	if err != nil {
		return "", false, err
	}
	defer tx.Rollback(ctx)
	q := store.New(tx)

	summaryText := strings.TrimSpace(summary)
	finalTitle := strings.TrimSpace(title)
	if finalTitle == "" {
		// Fall back to the first line of the summary, then the first location.
		if summaryText != "" {
			finalTitle = strings.TrimSpace(strings.SplitN(summaryText, "\n", 2)[0])
		}
		if finalTitle == "" && len(locations) > 0 {
			if n, ok := locations[0]["name"].(string); ok && n != "" {
				finalTitle = "Trip to " + n
			}
		}
		if finalTitle == "" {
			finalTitle = "Untitled trip"
		}
	}

	var summaryPtr *string
	if summaryText != "" {
		summaryPtr = &summaryText
	}
	var chatPtr *string
	if c := strings.TrimSpace(chatID); c != "" {
		chatPtr = &c
	}

	// Detect new-lineage vs version save inside the same transaction as the
	// insert (a chat-less save always stands alone, i.e. a new lineage).
	// Fail-open: if the check errors, treat the lineage as existing so the
	// free-cap signal is skipped rather than over-emitted.
	newLineage = true
	if chatPtr != nil {
		exists, lerr := q.TripLineageExists(ctx, store.TripLineageExistsParams{UserID: userID, ChatID: chatPtr})
		switch {
		case lerr != nil:
			log.Printf("trip lineage check failed (treating as existing lineage): %v", lerr)
			newLineage = false
		case exists:
			newLineage = false
		}
	}

	// Runaway guard: a brand-new lineage counts against the per-user trip cap.
	// Version saves of an existing lineage are exempt (they don't grow the
	// lineage count). Generous by default — a normal user never hits it.
	if newLineage {
		if n, cerr := q.CountActiveTripLineagesByOwner(ctx, userID); cerr == nil && int(n) >= maxTripsPerUser() {
			return "", false, fmt.Errorf("trip limit reached (%d trips) — delete an old trip first", maxTripsPerUser())
		}
	}

	var modePtr *string
	if m := strings.TrimSpace(travelMode); m != "" && allowedTravelModes[m] {
		modePtr = &m
	}

	trip, err := q.CreateTrip(ctx, store.CreateTripParams{UserID: userID, Title: finalTitle, ChatID: chatPtr, Summary: summaryPtr, TravelMode: modePtr})
	if err != nil {
		return "", false, err
	}

	// Bulk insert (COPY) instead of a round trip per item — the per-row
	// results were always discarded. maxDay stays computed in Go.
	maxDay := 1
	rows := make([]store.CreateItineraryItemsParams, 0, len(locations))
	for i, loc := range locations {
		params := itemParamsFromLocation(trip.ID, int32(i), loc)
		if params.Day != nil && int(*params.Day) > maxDay {
			maxDay = int(*params.Day)
		}
		rows = append(rows, store.CreateItineraryItemsParams(params))
	}
	if len(rows) > 0 {
		if _, err := q.CreateItineraryItems(ctx, rows); err != nil {
			return "", false, err
		}
	}

	// Save the trip's date span when the agent supplied a start date. A missing
	// end date is derived from the start plus the itinerary's day span.
	if start := strings.TrimSpace(startDate); start != "" {
		end := strings.TrimSpace(endDate)
		if end == "" {
			if t, perr := time.Parse("2006-01-02", start); perr == nil {
				end = t.AddDate(0, 0, maxDay-1).Format("2006-01-02")
			}
		}
		startD, serr := parseDateParam(&start)
		endD, eerr := parseDateParam(&end)
		if serr == nil && eerr == nil {
			if _, err := q.UpdateTrip(ctx, store.UpdateTripParams{
				ID:        trip.ID,
				UserID:    userID,
				StartDate: startD,
				EndDate:   endD,
			}); err != nil {
				return "", false, err
			}
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return "", false, err
	}
	return trip.ID.String(), newLineage, nil
}

func tripIDFromPath(r *http.Request) (uuid.UUID, bool) {
	id, err := uuid.Parse(mux.Vars(r)["id"])
	if err != nil {
		return uuid.UUID{}, false
	}
	return id, true
}

// --- handlers (all behind authMiddleware) ---

// listTripsHandler returns one trip per chat group (the latest version), each
// carrying version_count so admins can surface the older versions.
func listTripsHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	trips, err := store.New(dbPool).ListLatestTripsByOwner(r.Context(), user.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load trips")
		return
	}
	out := make([]TripResponse, 0, len(trips))
	for _, t := range trips {
		resp := toTripResponse(store.Trip{
			ID:        t.ID,
			UserID:    t.UserID,
			CreatedAt: t.CreatedAt,
			UpdatedAt: t.UpdatedAt,
			Title:     t.Title,
			StartDate: t.StartDate,
			EndDate:   t.EndDate,
			ChatID:    t.ChatID,
			Summary:   t.Summary,
		}, nil, nil, nil, nil)
		resp.VersionCount = int(t.VersionCount)
		resp.Cities = t.Cities
		// Explicit-zero pointers: a real 0 must survive omitempty (only
		// full views / old servers / shared rows leave these nil).
		itemCount, bookingTotal, bookingBooked :=
			int(t.ItemCount), int(t.BookingTotal), int(t.BookingBooked)
		resp.ItemCount = &itemCount
		resp.BookingTotal = &bookingTotal
		resp.BookingBooked = &bookingBooked
		stayTotal, stayBooked := int(t.StayTotal), int(t.StayBooked)
		resp.StayTotal = &stayTotal
		resp.StayBooked = &stayBooked
		packingTotal, packingDone := int(t.PackingTotal), int(t.PackingDone)
		resp.PackingTotal = &packingTotal
		resp.PackingDone = &packingDone
		resp.BudgetTarget = t.BudgetTarget
		budgetSpent, budgetCurrency := t.BudgetSpent, t.BudgetCurrency
		resp.BudgetSpent = &budgetSpent
		resp.BudgetCurrency = &budgetCurrency
		resp.NextTransportDepart = dateToPtr(t.NextTransportDepart)
		// jsonb → []byte (the notifications Payload precedent). The query
		// COALESCEs to '[]', which unmarshals empty and omitempty drops.
		if len(t.CityPins) > 0 {
			var pins []CityPinResponse
			if err := json.Unmarshal(t.CityPins, &pins); err != nil {
				log.Printf("listTrips: bad city_pins for trip %s: %v", t.ID, err)
			} else {
				resp.CityPins = pins
			}
		}
		resp.Shared = t.Shared
		out = append(out, resp)
	}
	writeJSON(w, http.StatusOK, out)
}

// listTripVersionsHandler returns every trip in a chat group (newest first).
// Admin-only — registered behind adminMiddleware; used to inspect the
// itinerary versions a single chat produced.
func listTripVersionsHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	chatID := strings.TrimSpace(r.URL.Query().Get("chat_id"))
	if chatID == "" {
		writeJSONError(w, http.StatusBadRequest, "chat_id is required")
		return
	}
	trips, err := store.New(dbPool).ListTripVersionsByChat(r.Context(), store.ListTripVersionsByChatParams{
		UserID: user.ID, ChatID: &chatID,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load trip versions")
		return
	}
	out := make([]TripResponse, 0, len(trips))
	for _, t := range trips {
		out = append(out, toTripResponse(t, nil, nil, nil, nil))
	}
	writeJSON(w, http.StatusOK, out)
}

func getTripHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	// Owner, editor co-planner, or viewer follow may read; mutations stay
	// behind editableTrip.
	row, ok := viewableTrip(w, r)
	if !ok {
		return
	}
	trip := store.Trip{
		ID: row.ID, UserID: row.UserID, CreatedAt: row.CreatedAt,
		UpdatedAt: row.UpdatedAt, Title: row.Title, StartDate: row.StartDate,
		EndDate: row.EndDate, ChatID: row.ChatID,
		Summary: row.Summary, UpdatedBy: row.UpdatedBy, TravelMode: row.TravelMode,
	}
	q := store.New(dbPool)
	// The reads below are independent of each other — fan them out on the
	// pool (pgxpool handles concurrent acquires) instead of paying serial
	// round-trip latency. Every permission branch is unchanged; only the
	// scheduling differs. Each goroutine writes its own variable, so there
	// is no shared mutable state until g.Wait() returns.
	g, ctx := errgroup.WithContext(r.Context())
	var (
		items          []store.ItineraryItem
		accommodations []store.Accommodation
		segments       []store.TripSegment
		bookingTodos   []store.BookingTodo
		ownerName      *string
		updatedByName  *string
		shared         bool
	)
	g.Go(func() error {
		var err error
		items, err = q.GetItineraryItemsByTrip(ctx, trip.ID)
		if err != nil {
			return errors.New("could not load itinerary")
		}
		return nil
	})
	// Suggested booking drafts (auto=true) are editor-facing working state;
	// viewer follows get confirmed rows only, matching the public share view.
	g.Go(func() error {
		var err error
		if row.Access == "viewer" {
			accommodations, err = q.ListConfirmedAccommodationsByTrip(ctx, trip.ID)
		} else {
			accommodations, err = q.ListAccommodationsByTrip(ctx, trip.ID)
		}
		if err != nil {
			return errors.New("could not load accommodations")
		}
		return nil
	})
	g.Go(func() error {
		var err error
		if row.Access == "viewer" {
			segments, err = q.ListConfirmedSegmentsByTrip(ctx, trip.ID)
		} else {
			segments, err = q.ListSegmentsByTrip(ctx, trip.ID)
		}
		if err != nil {
			return errors.New("could not load segments")
		}
		return nil
	})
	// Booking todos encode the owner's booking state and prices — viewer
	// follows don't get them, matching the public share view's boundary.
	if row.Access != "viewer" {
		g.Go(func() error {
			var err error
			bookingTodos, err = q.ListBookingTodosByTrip(ctx, trip.ID)
			if err != nil {
				return errors.New("could not load booking todos")
			}
			return nil
		})
	}
	// Display-name attribution: owner name (for collaborators) and last-editor
	// name resolve from ONE batch lookup. Best-effort like the old per-id
	// GetUserByID calls — a lookup failure just omits the names.
	needOwnerName := row.Access != "owner"
	needEditorName := trip.UpdatedBy.Valid && trip.UpdatedBy.Bytes != user.ID
	if needOwnerName || needEditorName {
		g.Go(func() error {
			ids := make([]uuid.UUID, 0, 2)
			if needOwnerName {
				ids = append(ids, trip.UserID)
			}
			if needEditorName {
				ids = append(ids, trip.UpdatedBy.Bytes)
			}
			rows, err := q.GetUserDisplayNames(ctx, ids)
			if err != nil {
				return nil // best-effort
			}
			names := make(map[uuid.UUID]*string, len(rows))
			for _, u := range rows {
				names[u.ID] = u.DisplayName
			}
			if needOwnerName {
				if n := names[trip.UserID]; n != nil && *n != "" {
					ownerName = n
				}
			}
			if needEditorName {
				if n := names[trip.UpdatedBy.Bytes]; n != nil && *n != "" {
					updatedByName = n
				}
			}
			return nil
		})
	}
	// Tell the owner's client this trip has co-planners (worth polling for
	// freshness). Editors know to poll from access alone. Best-effort.
	if trip.UserID == user.ID && trip.ChatID != nil {
		chatID := *trip.ChatID
		g.Go(func() error {
			if s, err := q.HasActiveCollaborators(ctx, store.HasActiveCollaboratorsParams{
				OwnerID: trip.UserID, ChatID: chatID,
			}); err == nil {
				shared = s
			}
			return nil
		})
	}
	if err := g.Wait(); err != nil {
		writeJSONError(w, http.StatusInternalServerError, err.Error())
		return
	}
	resp := toTripResponse(trip, items, accommodations, segments, bookingTodos)
	resp.Legs = tripLegsResponse(trip, items, accommodations)
	resp.Access = row.Access
	if row.Access != "owner" {
		// The chat_id keys the OWNER's plan sessions; a collaborator seeding a
		// freeform /plan chat with it would fork the lineage under their own
		// account. Refine binds by trip_id, so members never need it.
		resp.ChatID = nil
		resp.OwnerName = ownerName
	}
	// "Updated by X" attribution — omitted for the caller's own edits.
	resp.UpdatedByName = updatedByName
	resp.Shared = shared
	writeJSON(w, http.StatusOK, resp)
}

// tripStatusHandler is the cheap freshness poll for shared trips: one row,
// owner or any active collaborator. Registered on the default rate-limit
// tier on purpose — clients hit it every ~25s.
func tripStatusHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	tripID, ok := tripIDFromPath(r)
	if !ok {
		writeJSONError(w, http.StatusNotFound, "trip not found")
		return
	}
	row, err := store.New(dbPool).GetTripStatusByID(r.Context(),
		store.GetTripStatusByIDParams{ID: tripID, UserID: user.ID})
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "trip not found")
		return
	}
	resp := TripStatusResponse{UpdatedAt: row.UpdatedAt}
	if row.UpdatedBy.Valid {
		id := uuid.UUID(row.UpdatedBy.Bytes).String()
		resp.UpdatedBy = &id
		if row.UpdatedByName != "" {
			name := row.UpdatedByName
			resp.UpdatedByName = &name
		}
	}
	writeJSON(w, http.StatusOK, resp)
}

// refineTripHandler returns the chat_id to reopen a saved trip in the AI agent,
// assigning one to legacy (NULL chat_id) trips so the agent's new itineraries
// append as versions of this same trip instead of spawning a duplicate card.
func refineTripHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	id, ok := tripIDFromPath(r)
	if !ok {
		writeJSONError(w, http.StatusNotFound, "trip not found")
		return
	}
	q := store.New(dbPool)
	trip, err := q.GetTripByIDAndOwner(r.Context(), store.GetTripByIDAndOwnerParams{ID: id, UserID: user.ID})
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "trip not found")
		return
	}

	chatID := trip.ChatID
	if chatID == nil {
		token, err := generateSessionToken()
		if err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not start refine session")
			return
		}
		newID := "chat-" + token
		updated, err := q.UpdateTrip(r.Context(), store.UpdateTripParams{
			ChatID: &newID, ID: id, UserID: user.ID,
		})
		if err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not start refine session")
			return
		}
		chatID = updated.ChatID
	}

	writeJSON(w, http.StatusOK, map[string]string{"chat_id": *chatID})
}

func patchTripHandler(w http.ResponseWriter, r *http.Request) {
	// Editors may adjust title/dates too. UpdateTrip's WHERE user_id
	// stays owner-scoped — satisfied by the OWNER's id off the authorized row.
	authorized, ok := editableTrip(w, r)
	if !ok {
		return
	}
	id := authorized.ID
	var req PatchTripRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}

	if req.TravelMode != nil && !allowedTravelModes[*req.TravelMode] {
		writeJSONError(w, http.StatusBadRequest, "travel_mode must be one of: flight, car, train, bus, ferry, mixed")
		return
	}
	if req.Title != nil {
		t := strings.TrimSpace(*req.Title)
		if t == "" {
			writeJSONError(w, http.StatusBadRequest, "title cannot be empty")
			return
		}
		if _, err := boundedString("title", t, maxNameLen); err != nil {
			writeJSONError(w, http.StatusBadRequest, err.Error())
			return
		}
		req.Title = &t
	}

	start, err := parseDateParam(req.StartDate)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "start_date must be YYYY-MM-DD")
		return
	}
	end, err := parseDateParam(req.EndDate)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "end_date must be YYYY-MM-DD")
		return
	}
	if start.Valid && end.Valid && end.Time.Before(start.Time) {
		writeJSONError(w, http.StatusBadRequest, "end_date must not be before start_date")
		return
	}

	q := store.New(dbPool)
	trip, err := q.UpdateTrip(r.Context(), store.UpdateTripParams{
		Title:      req.Title,
		StartDate:  start,
		EndDate:    end,
		TravelMode: req.TravelMode,
		ID:         id,
		UserID:     authorized.UserID,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		writeJSONError(w, http.StatusNotFound, "trip not found")
		return
	}
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not update trip")
		return
	}
	// Best-effort attribution: the patch itself already committed.
	_ = q.TouchTrip(r.Context(), touchedBy(trip.ID, r))
	items, err := q.GetItineraryItemsByTrip(r.Context(), trip.ID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load itinerary")
		return
	}
	writeJSON(w, http.StatusOK, toTripResponse(trip, items, nil, nil, nil))
}

func deleteTripHandler(w http.ResponseWriter, r *http.Request) {
	user, _ := userFromContext(r.Context())
	id, ok := tripIDFromPath(r)
	if !ok {
		writeJSONError(w, http.StatusNotFound, "trip not found")
		return
	}
	rows, err := store.New(dbPool).DeleteTrip(r.Context(), store.DeleteTripParams{ID: id, UserID: user.ID})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not delete trip")
		return
	}
	if rows == 0 {
		writeJSONError(w, http.StatusNotFound, "trip not found")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// parseDateParam turns an optional "YYYY-MM-DD" string into a pgtype.Date.
// A nil input yields an invalid (NULL) date, which UpdateTrip's COALESCE leaves unchanged.
func parseDateParam(s *string) (pgtype.Date, error) {
	if s == nil || strings.TrimSpace(*s) == "" {
		return pgtype.Date{}, nil
	}
	t, err := time.Parse(dateLayout, *s)
	if err != nil {
		return pgtype.Date{}, err
	}
	return pgtype.Date{Time: t, Valid: true}, nil
}
