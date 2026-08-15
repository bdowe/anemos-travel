package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"travel-route-planner/store"
)

// mcp_tools.go: what ChatGPT/claude.ai can actually do with a linked
// Anemos account (specs/mcp-connector). Deliberately small — the connector's
// job is to write trips the user planned in their AI chat, and to put the
// local-recommendations moat inside that chat.
//
// Every handler closes over the caller resolved by mcpAuthMiddleware, so
// there is no path to another user's data. Tool errors are returned as
// IsError results (the model can read and act on them), never Go errors,
// which the SDK would surface as protocol failures.

const (
	// Bounds the Places spend of a single create_trip call.
	mcpMaxTripLocations = 60
	mcpMaxRecResults    = 50
)

// mcpTripLocation mirrors itineraryLocationSchema minus the fields the server
// derives (coordinates, place_id, address) — the AI supplies names, we resolve
// them.
type mcpTripLocation struct {
	Name        string `json:"name" jsonschema:"the place's name, as it would be searched on a map"`
	City        string `json:"city" jsonschema:"the municipality the place is in — 'Versailles', not 'Paris'"`
	DayTripFrom string `json:"day_trip_from,omitempty" jsonschema:"hub city when this is a same-day trip from where the traveler stays"`
	Category    string `json:"category,omitempty" jsonschema:"'attraction' or 'restaurant'"`
	TimeOfDay   string `json:"time_of_day,omitempty" jsonschema:"'morning', 'afternoon' or 'evening'"`
	Day         int    `json:"day,omitempty" jsonschema:"trip day, 1-based and chronological across the whole trip"`
}

type createTripInput struct {
	Title      string            `json:"title" jsonschema:"short trip name, e.g. 'Lisbon & Porto'"`
	Summary    string            `json:"summary,omitempty" jsonschema:"2-3 sentence summary of the trip"`
	StartDate  string            `json:"start_date,omitempty" jsonschema:"YYYY-MM-DD, only if the traveler stated dates"`
	EndDate    string            `json:"end_date,omitempty" jsonschema:"YYYY-MM-DD, only if the traveler stated dates"`
	TravelMode string            `json:"travel_mode,omitempty" jsonschema:"how they move between cities: flight, car, train, bus, ferry or mixed"`
	Origin     string            `json:"origin,omitempty" jsonschema:"where the traveler sets out from, as they said it, e.g. 'Lake George, NY' — only if they stated it; omitted means their saved home airport is assumed"`
	Locations  []mcpTripLocation `json:"locations" jsonschema:"the itinerary's places, in order"`
}

type createTripOutput struct {
	TripID   string   `json:"trip_id"`
	URL      string   `json:"url"`
	Resolved int      `json:"resolved"`
	Dropped  []string `json:"dropped"`
}

type searchRecsInput struct {
	City     string `json:"city" jsonschema:"city to search, e.g. 'Lisbon'"`
	Category string `json:"category,omitempty" jsonschema:"'attraction' or 'restaurant' to narrow the results"`
}

type listTripsInput struct{}

type mcpTripSummary struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	StartDate string `json:"start_date,omitempty"`
	EndDate   string `json:"end_date,omitempty"`
	URL       string `json:"url"`
}

type listTripsOutput struct {
	Trips []mcpTripSummary `json:"trips"`
}

// boolPtr exists because ToolAnnotations.DestructiveHint and .OpenWorldHint are
// *bool with `omitempty` and a documented default of TRUE. Leaving one nil is
// not "no opinion" — it ships absent and the client assumes the dangerous
// reading. Every hint below is therefore stated outright, and the annotations
// are pinned by mcp_server_integration_test.go so a nil can't creep back in.
func boolPtr(b bool) *bool { return &b }

// registerMCPTools declares the three tools plus the annotations both connector
// directories require: OpenAI wants readOnlyHint/openWorldHint/destructiveHint
// on every tool, Anthropic wants a title and the applicable hints. Missing or
// wrong annotations are a named rejection cause on both.
func registerMCPTools(s *mcp.Server, caller mcpCaller) {
	mcp.AddTool(s, &mcp.Tool{
		Name:  "create_trip",
		Title: "Save trip to Anemos",
		Description: "Save an itinerary to the traveler's Anemos account. " +
			"Supply the places by name and city — Anemos resolves map coordinates itself. " +
			"Use this once the traveler has agreed on a plan; the reply includes a link to the saved trip.",
		// Writes, but only ever adds: a new trip in the traveler's own private
		// account. It overwrites nothing, deletes nothing, and publishes nothing
		// to the open internet — hence destructive/openWorld false. Not
		// idempotent: calling twice saves the trip twice.
		Annotations: &mcp.ToolAnnotations{
			Title:           "Save trip to Anemos",
			ReadOnlyHint:    false,
			DestructiveHint: boolPtr(false),
			OpenWorldHint:   boolPtr(false),
			IdempotentHint:  false,
		},
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in createTripInput) (*mcp.CallToolResult, createTripOutput, error) {
		return mcpCreateTrip(ctx, caller, in)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:  "search_local_recommendations",
		Title: "Search local recommendations",
		Description: "Search Anemos's recommendations from real locals for a city — places you can't find by " +
			"searching the web, with the local's own tip and a quote. Call this FIRST when recommending places in a " +
			"city, and credit the local by name when you use one.",
		// Reads Anemos's own published pins. Closed world: no third-party call,
		// no external state.
		Annotations: &mcp.ToolAnnotations{
			Title:           "Search local recommendations",
			ReadOnlyHint:    true,
			DestructiveHint: boolPtr(false),
			OpenWorldHint:   boolPtr(false),
			IdempotentHint:  true,
		},
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in searchRecsInput) (*mcp.CallToolResult, any, error) {
		return mcpSearchLocalRecs(ctx, caller, in)
	})

	mcp.AddTool(s, &mcp.Tool{
		Name:        "list_trips",
		Title:       "List saved trips",
		Description: "List the traveler's saved Anemos trips, so you can refer to or link an existing trip.",
		Annotations: &mcp.ToolAnnotations{
			Title:           "List saved trips",
			ReadOnlyHint:    true,
			DestructiveHint: boolPtr(false),
			OpenWorldHint:   boolPtr(false),
			IdempotentHint:  true,
		},
	}, func(ctx context.Context, _ *mcp.CallToolRequest, _ listTripsInput) (*mcp.CallToolResult, listTripsOutput, error) {
		return mcpListTrips(ctx, caller)
	})
}

func mcpCreateTrip(ctx context.Context, caller mcpCaller, in createTripInput) (*mcp.CallToolResult, createTripOutput, error) {
	var zero createTripOutput
	if !scopeGranted(caller.scope, oauthScopeTripsWrite) {
		return toolError("This connection isn't allowed to create trips."), zero, nil
	}
	if len(in.Locations) == 0 {
		return toolError("No places were supplied — include the itinerary's places with their cities."), zero, nil
	}
	// Bounds the paid Places lookups one call can trigger.
	if len(in.Locations) > mcpMaxTripLocations {
		in.Locations = in.Locations[:mcpMaxTripLocations]
	}
	if mcpCreateCounter.incr(caller.grantID.String(), time.Now()) > mcpCreateTripsPerDay {
		log.Printf("mcp create_trip daily cap grant=%s", caller.grantID)
		return toolError("This connection has reached today's limit for creating trips. Try again tomorrow."), zero, nil
	}

	// Resolve coordinates the same way the paste-import path does: Google is
	// authoritative, unresolved places are dropped but always NAMED so the
	// model can tell the traveler rather than silently losing them.
	locs := make([]ImportedLocation, 0, len(in.Locations))
	for _, l := range in.Locations {
		locs = append(locs, ImportedLocation{
			Name:        l.Name,
			City:        l.City,
			DayTripFrom: l.DayTripFrom,
			Category:    l.Category,
			TimeOfDay:   l.TimeOfDay,
			Day:         l.Day,
			SearchHint:  strings.TrimSpace(l.Name + ", " + l.City),
		})
	}
	resolved, stats, _ := resolveImportedLocations(ctx, locs)
	var dropped []string
	if stats.Dropped > 0 {
		kept := map[string]bool{}
		for _, r := range resolved {
			if n, ok := r["name"].(string); ok {
				kept[n] = true
			}
		}
		for _, l := range in.Locations {
			if !kept[strings.TrimSpace(l.Name)] {
				dropped = append(dropped, l.Name)
			}
		}
	}
	if len(resolved) == 0 {
		if stats.LookupFailures > 0 {
			return toolError("Anemos couldn't reach its map provider just now — ask the traveler to try again in a few minutes."), zero, nil
		}
		return toolError("None of those places could be located on a map. Check the place names and cities and try again."), zero, nil
	}

	resolved = reorderItineraryByDistance(resolved)
	chatToken, err := generateSessionToken()
	if err != nil {
		return toolError("Anemos couldn't save the trip just now."), zero, nil
	}
	tripID, newLineage, err := persistTrip(ctx, caller.userID, "chat-"+chatToken,
		in.Title, in.Summary, in.StartDate, in.EndDate, in.TravelMode, tripEndpoints{Origin: in.Origin}, resolved)
	if err != nil {
		// persistTrip's cap message is written for people — pass it through.
		if strings.Contains(err.Error(), "trip limit reached") {
			return toolError(err.Error()), zero, nil
		}
		ctxLog(ctx).Error("mcp create_trip: persist failed", "error", err)
		return toolError("Anemos couldn't save the trip just now."), zero, nil
	}

	out := createTripOutput{
		TripID:   tripID,
		URL:      publicAppURL("trip/", tripID),
		Resolved: stats.Resolved + stats.Approximate,
		Dropped:  dropped,
	}
	if out.Dropped == nil {
		out.Dropped = []string{}
	}

	if parsed, perr := uuid.Parse(tripID); perr == nil {
		safeGo("recordEvent", func() {
			recordEvent(caller.userID, "trip_created", &parsed, map[string]any{
				"item_count": len(resolved),
				"source":     "mcp",
			})
		})
		if newLineage {
			safeGo("recordActiveTripsCapSignal", func() { recordActiveTripsCapSignal(caller.userID, parsed) })
		}
	}

	msg := fmt.Sprintf("Saved %q with %d places to the traveler's Anemos account: %s",
		in.Title, len(resolved), out.URL)
	if len(dropped) > 0 {
		msg += fmt.Sprintf("\n\nCouldn't locate on a map (not saved): %s. Tell the traveler so they can add them by hand.",
			strings.Join(dropped, ", "))
	}
	return toolText(msg), out, nil
}

func mcpSearchLocalRecs(ctx context.Context, caller mcpCaller, in searchRecsInput) (*mcp.CallToolResult, any, error) {
	if !scopeGranted(caller.scope, oauthScopeRecsRead) {
		return toolError("This connection isn't allowed to read recommendations."), nil, nil
	}
	city := strings.TrimSpace(in.City)
	if city == "" {
		return toolError("Which city? Supply a city name."), nil, nil
	}
	recs, err := localRecsService.SearchByCity(ctx, city, strings.TrimSpace(in.Category))
	if err != nil {
		ctxLog(ctx).Error("mcp search_local_recommendations failed", "error", err, "city", city)
		return toolError("Anemos couldn't search recommendations just now."), nil, nil
	}
	if len(recs) == 0 {
		return toolText(fmt.Sprintf("No local recommendations for %s yet.", city)), nil, nil
	}
	if len(recs) > mcpMaxRecResults {
		recs = recs[:mcpMaxRecResults]
	}
	b, err := json.Marshal(recs)
	if err != nil {
		return toolError("Anemos couldn't format the recommendations."), nil, nil
	}
	return toolText(string(b)), nil, nil
}

func mcpListTrips(ctx context.Context, caller mcpCaller) (*mcp.CallToolResult, listTripsOutput, error) {
	out := listTripsOutput{Trips: []mcpTripSummary{}}
	if !scopeGranted(caller.scope, oauthScopeTripsWrite) {
		return toolError("This connection isn't allowed to read trips."), out, nil
	}
	// One row per chat lineage (latest version) — what "My Trips" shows.
	rows, err := store.New(dbPool).ListLatestTripsByOwner(ctx, caller.userID)
	if err != nil {
		ctxLog(ctx).Error("mcp list_trips failed", "error", err)
		return toolError("Anemos couldn't list trips just now."), out, nil
	}
	for _, t := range rows {
		s := mcpTripSummary{
			ID:    t.ID.String(),
			Title: t.Title,
			URL:   publicAppURL("trip/", t.ID.String()),
		}
		if t.StartDate.Valid {
			s.StartDate = t.StartDate.Time.Format("2006-01-02")
		}
		if t.EndDate.Valid {
			s.EndDate = t.EndDate.Time.Format("2006-01-02")
		}
		out.Trips = append(out.Trips, s)
	}
	if len(out.Trips) == 0 {
		return toolText("No saved trips yet."), out, nil
	}
	b, _ := json.Marshal(out.Trips)
	return toolText(string(b)), out, nil
}
