package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"slices"
	"strings"
	"unicode/utf8"

	anthropic "github.com/anthropics/anthropic-sdk-go"
	"github.com/google/uuid"

	"travel-route-planner/store"
)

// plan_tool_registry.go — the /plan agent's tool table. Every tool the agent
// can call is ONE entry in planToolRegistry: the anthropic tool definition,
// an optional availability gate, and a dispatcher. plan_handler.go generates
// the tools slice sent to the API from this registry and dispatches tool_use
// blocks through it; adding a tool means adding one entry here.
//
// ORDER MATTERS: planToolRegistry is an ordered slice, not a map, because the
// tools array is part of the prompt-cache prefix (the system-prompt cache
// breakpoint covers tools + system — see the Wave-6 moving-cache-breakpoint
// work in plan_handler.go). Registry order is the serialization order; keep
// it byte-stable so cache hits survive across iterations and sessions.

// planSession carries the per-request state a tool dispatcher may need:
// which caller this is, what trip (if any) the session is bound to, the SSE
// writer for side events, and the mutable outcomes the handler reads back
// (persisted trip id, whether the profile distiller already fired).
type planSession struct {
	ctx    context.Context
	w      http.ResponseWriter
	req    PlanRequest
	client anthropic.Client

	authed      bool
	uid         uuid.UUID
	boundTripID *uuid.UUID
	// boundTripOwnerID is the lineage owner of the bound trip (zero when
	// unbound); differs from uid when an editor collaborator is refining.
	boundTripOwnerID uuid.UUID

	// tripID is the trip this session persisted or refined (nil if none);
	// the handler's completion instrumentation reads it.
	tripID *uuid.UUID
	// distilled guards the once-per-session background profile distillation.
	distilled bool
	// connectivityCalls counts check_flight_connectivity uses, capped per
	// session to bound Duffel spend.
	connectivityCalls int
	// travelMode is the traveler's stated mode for this trip (set_travel_mode);
	// create_itinerary persists it onto the trip. Empty = never stated.
	travelMode string
	// itineraryEmitted is set once this turn streamed `done` or
	// `trip_updated`; suggest_replies refuses after it (the itinerary banner
	// owns the turn — specs/chat-quick-replies). Not s.tripID: that stays nil
	// for anonymous create_itinerary, which still streams `done`.
	itineraryEmitted bool
}

// planTool is one registry entry.
type planTool struct {
	def anthropic.ToolParam
	// enabled gates whether the tool is offered to the model for this
	// session; nil means always offered.
	enabled func(s *planSession) bool
	// run executes the tool and returns (resultText, isError) — the payload
	// of the tool_result block sent back to the model. Side events (done,
	// flights, stays, ...) are emitted inside run, before the generic
	// tool_result event.
	run func(s *planSession, input json.RawMessage) (string, bool)
	// noResultEvent suppresses the generic tool_result SSE event
	// (create_itinerary emits done instead).
	noResultEvent bool
}

func authedOnly(s *planSession) bool { return s.authed }

// planToolRegistry lists every agent tool in serialization order. The
// conditional slots keep today's order: the trip-bound section tool replaces
// create_itinerary (a refinement can never spawn a new trip version), and the
// personalization tools are signed-in only.
var planToolRegistry = []planTool{
	{def: searchPlacesTool, run: runSearchPlacesTool},
	{def: suggestStaysTool, run: runSuggestStaysTool},
	{def: suggestTransportTool, run: runSuggestTransportTool},
	{def: suggestFerriesTool, run: runSuggestFerriesTool},
	{def: searchFlightsTool, run: runSearchFlightsTool},
	{def: checkFlightConnectivityTool, run: runCheckFlightConnectivityTool},
	{def: searchEventsTool, run: runSearchEventsTool},
	{def: searchLocalRecsTool, run: runSearchLocalRecsTool},
	{def: getWeatherTool, run: func(s *planSession, input json.RawMessage) (string, bool) {
		return runGetWeatherTool(s.ctx, input)
	}},
	{def: updateSectionTool, enabled: func(s *planSession) bool { return s.boundTripID != nil },
		run: runUpdateItinerarySectionTool},
	{def: createItineraryTool, enabled: func(s *planSession) bool { return s.boundTripID == nil },
		run: runCreateItineraryTool, noResultEvent: true},
	{def: savePrefsTool, enabled: authedOnly, run: runSavePreferencesTool},
	{def: getTripTool, enabled: authedOnly, run: func(s *planSession, input json.RawMessage) (string, bool) {
		return runGetTripTool(s.ctx, s.authed, s.uid, s.boundTripID, input)
	}},
	{def: addBookingTodoTool, enabled: authedOnly, run: runAddBookingTodoTool},
	{def: updateBookingTodoTool, enabled: authedOnly, run: runUpdateBookingTodoTool},
	{def: removeBookingTodoTool, enabled: authedOnly, run: runRemoveBookingTodoTool},
	{def: addPackingItemTool, enabled: authedOnly, run: runAddPackingItemTool},
	{def: reviewTripTool, enabled: func(s *planSession) bool { return s.authed && s.boundTripID != nil },
		run: runReviewTripTool},
	{def: addAccommodationTool, enabled: func(s *planSession) bool { return s.authed && s.boundTripID != nil },
		run: runAddAccommodationTool},
	{def: addTransportSegmentTool, enabled: func(s *planSession) bool { return s.authed && s.boundTripID != nil },
		run: runAddTransportSegmentTool},
	{def: moveItineraryItemTool, enabled: func(s *planSession) bool { return s.authed && s.boundTripID != nil },
		run: runMoveItineraryItemTool},
	// No enabled gate: anonymous/unbound sessions record the mode on the
	// session so the plan itself avoids the wrong transport.
	{def: setTravelModeTool, run: runSetTravelModeTool},
	// Meta-tool: renders one-tap reply chips client-side (suggest_replies SSE
	// event, specs/chat-quick-replies). No gate — useful in every session
	// shape, and gate-free keeps each shape's tools array a pure append
	// (prompt-cache prefix rule).
	{def: suggestRepliesTool, run: runSuggestRepliesTool},
	// Location-biased place search for "what's near me" sessions. No gate, and
	// tail-appended: the tools array is part of the prompt-cache prefix (see
	// header comment) — never insert mid-list.
	{def: searchNearbyTool, run: runSearchNearbyTool},
	// Free/cheap parking near beaches (specs/find-parking-near-beach). No gate
	// (pure append across session shapes), and tail-appended per the
	// prompt-cache rule above.
	{def: findParkingTool, run: runFindParkingTool},
	// Move/set a saved trip's dates (specs/set-trip-dates). Signed-in only —
	// anonymous sessions have no saved trip to move; authed never flips
	// mid-conversation, so each session shape's tools array stays fixed.
	// Which trip it targets is resolved at call time in the handler (bound
	// trip, this request's persisted trip, or the chat lineage's newest
	// version). Tail-appended per the prompt-cache rule above.
	{def: setTripDatesTool, enabled: authedOnly, run: runSetTripDatesTool},
	// Change ONE city leg's dates without moving the rest of the trip
	// (specs/set-leg-dates) — endpoint-anchored, unlike set_trip_dates'
	// whole-trip delta. Signed-in only for the same stability reason as
	// set_trip_dates; target-trip resolution shares resolveDateShiftTrip.
	// Tail-appended per the prompt-cache rule above.
	{def: setLegDatesTool, enabled: authedOnly, run: runSetLegDatesTool},
}

// planToolByName dispatches tool_use blocks; derived from the registry so the
// two can never drift.
var planToolByName = func() map[string]*planTool {
	m := make(map[string]*planTool, len(planToolRegistry))
	for i := range planToolRegistry {
		m[planToolRegistry[i].def.Name] = &planToolRegistry[i]
	}
	return m
}()

// planSessionTools generates the tools slice sent to the API, in registry
// order, filtered to what this session may use.
func planSessionTools(s *planSession) []anthropic.ToolUnionParam {
	tools := make([]anthropic.ToolUnionParam, 0, len(planToolRegistry))
	for i := range planToolRegistry {
		pt := &planToolRegistry[i]
		if pt.enabled == nil || pt.enabled(s) {
			tools = append(tools, anthropic.ToolUnionParam{OfTool: &pt.def})
		}
	}
	return tools
}

// --- tool definitions ---------------------------------------------------------

var searchPlacesTool = anthropic.ToolParam{
	Name:        "search_places",
	Description: anthropic.String("Search for travel destinations, attractions, restaurants, or points of interest by name or description."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"query": map[string]any{
				"type":        "string",
				"description": "Search query, e.g. 'Eiffel Tower Paris' or 'best museums in Rome'",
			},
		},
		Required: []string{"query"},
	},
}

var searchNearbyTool = anthropic.ToolParam{
	Name:        "search_nearby",
	Description: anthropic.String("Search for places near specific GPS coordinates — use this INSTEAD of search_places whenever the traveler shares their current location or asks what's around them right now. Results are biased to within a short walk or ride of the coordinates; prefer the closest good options and mention rough distances. The result addresses tell you which city the traveler is in — once you know it, also call search_local_recommendations with that city for curated local picks."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"query": map[string]any{
				"type":        "string",
				"description": "What to look for, e.g. 'restaurants', 'coffee', 'things to do', 'live music tonight'",
			},
			"latitude": map[string]any{
				"type":        "number",
				"description": "Latitude in decimal degrees, e.g. 37.9838",
			},
			"longitude": map[string]any{
				"type":        "number",
				"description": "Longitude in decimal degrees, e.g. 23.7276",
			},
		},
		Required: []string{"query", "latitude", "longitude"},
	},
}

var findParkingTool = anthropic.ToolParam{
	Name:        "find_parking",
	Description: anthropic.String("Find parking near a beach for travelers who will have a car, surfacing options that appear free or cheap. The free_listed flag is a heuristic read of the place listing, NOT verified pricing — always present flagged spots as 'listed as free — verify locally', never as guaranteed. Pass the beach's coordinates if you already know them from an earlier search; omit them and the tool looks the beach up by name."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"beach_name": map[string]any{
				"type":        "string",
				"description": "Beach name with city/island for disambiguation, e.g. 'Barceloneta Beach Barcelona'",
			},
			"latitude": map[string]any{
				"type":        "number",
				"description": "Beach latitude in decimal degrees, if already known",
			},
			"longitude": map[string]any{
				"type":        "number",
				"description": "Beach longitude in decimal degrees, if already known",
			},
		},
		Required: []string{"beach_name"},
	},
}

var createItineraryTool = anthropic.ToolParam{
	Name:        "create_itinerary",
	Description: anthropic.String("Finalize the itinerary with the chosen list of locations to visit. Call this when you have identified all the places for the trip."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"locations": map[string]any{
				"type":        "array",
				"description": "Ordered list of locations to visit",
				"items":       itineraryLocationSchema,
			},
			"title": map[string]any{
				"type":        "string",
				"description": "A short, human-friendly trip name, 3–6 words (e.g. 'Luxury Paris Weekend'). Distinct from the longer summary.",
			},
			"summary": map[string]any{
				"type":        "string",
				"description": "A 1–2 sentence overview of the trip to show the user (the per-day breakdown already appears in the itinerary list, so keep this brief).",
			},
			"start_date": map[string]any{
				"type":        "string",
				"description": "The trip's first day as YYYY-MM-DD (day 1). Include it whenever the traveler has given or agreed to travel dates.",
			},
			"end_date": map[string]any{
				"type":        "string",
				"description": "The trip's last day as YYYY-MM-DD. Optional — if omitted it's derived from start_date plus the number of days in the itinerary.",
			},
		},
		Required: []string{"locations"},
	},
}

var savePrefsTool = anthropic.ToolParam{
	Name:        "save_preferences",
	Description: anthropic.String("Save what you learn about the traveler so future trips are personalized. Call this when the user reveals a budget level, trip pace, interests, which airport they fly from, or any other durable fact about how they travel. Only include fields you actually learned."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"budget": map[string]any{
				"type":        "string",
				"enum":        []string{"budget", "mid", "luxury"},
				"description": "Overall spending level",
			},
			"pace": map[string]any{
				"type":        "string",
				"enum":        []string{"relaxed", "balanced", "packed"},
				"description": "How packed the days should be",
			},
			"interests": map[string]any{
				"type":        "array",
				"items":       map[string]any{"type": "string"},
				"description": "Theme tags, e.g. museums, food, nightlife, nature",
			},
			"home_airport": map[string]any{
				"type":        "string",
				"description": "The traveler's home/departure airport as an IATA code, e.g. BOS — save it when they mention where they usually fly from",
			},
			"profile_notes": map[string]any{
				"type":        "string",
				"description": "The COMPLETE updated traveler profile as short bullet lines — your current notes (shown in the system prompt) merged with the new fact, de-duplicated, max ~15 lines. Never send only the new fact; always send the full rewritten profile.",
			},
		},
	},
}

var suggestStaysTool = anthropic.ToolParam{
	Name:        "suggest_stays",
	Description: anthropic.String("Give the traveler links to browse accommodations on Airbnb and Booking.com for a destination. Call this when they want lodging suggestions."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"destination": map[string]any{"type": "string", "description": "City or area, e.g. 'Paris'"},
			"check_in":    map[string]any{"type": "string", "description": "Optional YYYY-MM-DD"},
			"check_out":   map[string]any{"type": "string", "description": "Optional YYYY-MM-DD"},
			"guests":      map[string]any{"type": "integer", "description": "Optional number of guests"},
		},
		Required: []string{"destination"},
	},
}

var suggestTransportTool = anthropic.ToolParam{
	Name:        "suggest_transport",
	Description: anthropic.String("Give the traveler links to browse transport options. Call this when they need to get to or between destinations. Mode 'flight' returns Google Flights + Kayak; mode 'ground' returns Rome2Rio (covers trains, buses, cars, ferries). For travel between Greek islands, prefer suggest_ferries instead."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"mode":        map[string]any{"type": "string", "enum": []string{"flight", "ground"}, "description": "flight or ground (multimodal)"},
			"origin":      map[string]any{"type": "string", "description": "Origin city or airport, e.g. 'NYC' or 'Paris'"},
			"destination": map[string]any{"type": "string", "description": "Destination city or airport"},
			"depart_date": map[string]any{"type": "string", "description": "Optional YYYY-MM-DD"},
			"return_date": map[string]any{"type": "string", "description": "Optional YYYY-MM-DD (flights only)"},
			"passengers":  map[string]any{"type": "integer", "description": "Optional passenger count"},
		},
		Required: []string{"mode", "origin", "destination"},
	},
}

var suggestFerriesTool = anthropic.ToolParam{
	Name:        "suggest_ferries",
	Description: anthropic.String("Give the traveler a ferry booking link for a route between two ports/islands — use this for Greek island-hopping (e.g. Santorini→Naxos) and other ferry legs. Backed by Ferryhopper, which aggregates the major Greek operators (Blue Star, SeaJets, etc.)."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"origin":      map[string]any{"type": "string", "description": "Departure port or island, e.g. 'Santorini' or 'Piraeus'"},
			"destination": map[string]any{"type": "string", "description": "Arrival port or island, e.g. 'Naxos'"},
			"date":        map[string]any{"type": "string", "description": "Optional YYYY-MM-DD travel date"},
			"passengers":  map[string]any{"type": "integer", "description": "Optional passenger count"},
		},
		Required: []string{"origin", "destination"},
	},
}

var suggestRepliesTool = anthropic.ToolParam{
	Name: "suggest_replies",
	Description: anthropic.String("Show the traveler 2-4 one-tap quick-reply buttons answering the question you just asked. " +
		"Call this at the very END of a reply that asks the traveler a question or offers a choice, after your text is complete. " +
		"Each reply is a short standalone answer in the traveler's voice, in the language of your reply."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"replies": map[string]any{
				"type":        "array",
				"items":       map[string]any{"type": "string"},
				"minItems":    2,
				"maxItems":    4,
				"description": "2-4 tappable answers, each under 60 characters, first-person from the traveler (e.g. 'Mid-range budget', 'More food, fewer museums', 'Yes, add it'). Each must make sense sent as a chat message on its own.",
			},
		},
		Required: []string{"replies"},
	},
}

var searchFlightsTool = anthropic.ToolParam{
	Name: "search_flights",
	Description: anthropic.String("Search real flight options between two places for given dates and present a few good ones (ranked by overall desirability). " +
		"Ask the traveler for their departure city/airport and travel dates first if you don't know them. " +
		"origin/destination may be city names or IATA codes. Choose optimize_for from the traveler's budget: budget→'cost', luxury→'time', otherwise 'balanced'. " +
		"To compare several candidate destinations' connectivity before recommending one, use check_flight_connectivity instead of multiple searches."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"origin":       map[string]any{"type": "string", "description": "Departure city or IATA code, e.g. 'Boston' or 'BOS'"},
			"destination":  map[string]any{"type": "string", "description": "Arrival city or IATA code"},
			"depart_date":  map[string]any{"type": "string", "description": "YYYY-MM-DD"},
			"return_date":  map[string]any{"type": "string", "description": "Optional YYYY-MM-DD for round trips"},
			"adults":       map[string]any{"type": "integer", "description": "Optional, defaults to 1"},
			"child_ages":   map[string]any{"type": "array", "items": map[string]any{"type": "integer"}, "description": "Optional ages of child travelers (one per child, 0-17) — include when the traveler mentions kids"},
			"cabin_class":  map[string]any{"type": "string", "enum": []string{"economy", "premium_economy", "business", "first"}, "description": "Optional cabin, defaults to economy — set when the traveler asks for a specific class"},
			"optimize_for": map[string]any{"type": "string", "enum": []string{"cost", "time", "balanced"}, "description": "Ranking emphasis"},
			"baggage":      map[string]any{"type": "string", "enum": []string{"personal_item", "carry_on", "checked"}, "description": "Biggest bag the traveler needs; set carry_on or checked whenever they mention luggage — offers are then ranked by the effective total including that bag, not the bare fare"},
		},
		Required: []string{"origin", "destination", "depart_date"},
	},
}

var searchEventsTool = anthropic.ToolParam{
	Name: "search_events",
	Description: anthropic.String("Find local events (concerts, sports, festivals, theatre/shows) happening in a city during specific dates, so the itinerary can account for what's on while the traveler is there. " +
		"Use the city and the dates the traveler is in that city; you already know the trip's cities and dates from the itinerary. " +
		"Present a few that fit the traveler's interests."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"city":       map[string]any{"type": "string", "description": "City name, e.g. 'Paris'"},
			"start_date": map[string]any{"type": "string", "description": "First day to look from, YYYY-MM-DD (when the traveler arrives in the city)"},
			"end_date":   map[string]any{"type": "string", "description": "Last day to look through, YYYY-MM-DD (when the traveler leaves the city)"},
			"category":   map[string]any{"type": "string", "enum": []string{"music", "sports", "arts", "film", "miscellaneous"}, "description": "Optional event category filter"},
		},
		Required: []string{"city", "start_date", "end_date"},
	},
}

var searchLocalRecsTool = anthropic.ToolParam{
	Name: "search_local_recommendations",
	Description: anthropic.String("Find hand-curated recommendations from real locals for a city — vetted spots you can't get by googling. " +
		"ALWAYS call this FIRST for each city, before search_places. Prefer these picks over generic search results, and when you use one, cite the local by name in your reply (their name is in 'source_name'). " +
		"When you pass a local pick into create_itinerary, copy its 'id' into local_recommendation_id and its 'source_name' into local_source_name so the saved trip credits them."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"city":     map[string]any{"type": "string", "description": "City name, e.g. 'Lisbon'"},
			"category": map[string]any{"type": "string", "enum": []string{"attraction", "restaurant"}, "description": "Optional filter to only sights or only places to eat"},
		},
		Required: []string{"city"},
	},
}

var updateSectionTool = anthropic.ToolParam{
	Name:        "update_itinerary_section",
	Description: anthropic.String("Replace one section of the traveler's saved itinerary in place. Pass the COMPLETE updated list of places for the targeted section, in visit order — places you omit are removed from that section. Places outside the section are untouched. Use scope 'day' for a single trip day, 'city' for one city/hub and its day trips, or 'trip' for the whole itinerary."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"scope": map[string]any{
				"type":        "string",
				"enum":        []string{"day", "city", "trip"},
				"description": "Which slice of the itinerary to replace.",
			},
			"day": map[string]any{
				"type":        "integer",
				"description": "Required when scope is 'day': the 1-based trip day being replaced.",
			},
			"city": map[string]any{
				"type":        "string",
				"description": "Required when scope is 'city' (the hub city whose items are replaced); optional with scope 'day' to disambiguate when day numbers repeat across cities.",
			},
			"items": map[string]any{
				"type":        "array",
				"description": "The full replacement list for the section, in visit order. Include unchanged places with their existing coordinates and tags so they aren't lost.",
				"items":       itineraryLocationSchema,
			},
		},
		Required: []string{"scope", "items"},
	},
}

// --- dispatchers ----------------------------------------------------------------

// planPlacesCardCap bounds the `places` SSE payload; the model still gets the
// full result list in its tool_result.
const planPlacesCardCap = 8

// placeCard is the client-facing shape of one photo card in the `places` SSE
// event — a wire struct separate from PlaceSearchResult so photo refs reach
// the client but never the model (PhotoRef is json:"-" there). Carries what
// the card needs for Add-to-trip and a Google Maps link.
type placeCard struct {
	Name             string   `json:"name"`
	PlaceID          string   `json:"place_id"`
	Address          string   `json:"address"`
	Latitude         float64  `json:"lat"`
	Longitude        float64  `json:"lng"`
	Rating           *float64 `json:"rating,omitempty"`
	PriceLevel       *int     `json:"price_level,omitempty"`
	Category         string   `json:"category,omitempty"`
	PhotoRef         string   `json:"photo_ref,omitempty"`
	PhotoAttribution string   `json:"photo_attribution,omitempty"`
	// FreeListed rides only the `parking` event's cards; omitempty keeps the
	// `places`/`local_recs` payloads byte-identical to before it existed.
	FreeListed bool `json:"free_listed,omitempty"`
}

// placeCards converts up to max results into cards and registers each emitted
// photo ref with the /places/photo known-ref gate — registration at emit time
// means the gate covers exactly what a client was shown, including
// cache-served searches.
func placeCards(results []PlaceSearchResult, max int) []placeCard {
	if len(results) > max {
		results = results[:max]
	}
	cards := make([]placeCard, len(results))
	for i, r := range results {
		cards[i] = placeCard{
			Name:             r.Name,
			PlaceID:          r.PlaceID,
			Address:          r.Address,
			Latitude:         r.Latitude,
			Longitude:        r.Longitude,
			Rating:           r.Rating,
			PriceLevel:       r.PriceLevel,
			Category:         MapGoogleTypeToCategory(r.Types),
			PhotoRef:         r.PhotoRef,
			PhotoAttribution: r.PhotoAttribution,
		}
		placesService.allowPhotoRef(r.PhotoRef)
	}
	return cards
}

func runSearchPlacesTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		Query string `json:"query"`
	}
	json.Unmarshal(input, &in)

	results, err := placesService.SearchPlaces(s.ctx, in.Query)
	if err != nil {
		return fmt.Sprintf("Error searching places: %v", err), true
	}
	// Photo cards for the chat window; the model's tool_result below is
	// unchanged (photo fields are json:"-" on PlaceSearchResult).
	if len(results) > 0 {
		sendSSE(s.w, "places", map[string]any{
			"query":  in.Query,
			"places": placeCards(results, planPlacesCardCap),
		})
	}
	b, _ := json.Marshal(results)
	return string(b), false
}

func runSearchNearbyTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		Query     string  `json:"query"`
		Latitude  float64 `json:"latitude"`
		Longitude float64 `json:"longitude"`
	}
	json.Unmarshal(input, &in)

	// (0,0) is the null island a zero-valued unmarshal produces, never a real
	// traveler position — reject it along with out-of-range values before
	// spending a Google call.
	if in.Latitude < -90 || in.Latitude > 90 || in.Longitude < -180 || in.Longitude > 180 ||
		(in.Latitude == 0 && in.Longitude == 0) {
		return "Invalid coordinates; ask the traveler where they are instead.", true
	}

	results, err := placesService.SearchPlacesNearby(s.ctx, in.Query, in.Latitude, in.Longitude)
	if err != nil {
		return fmt.Sprintf("Error searching nearby: %v", err), true
	}
	// Same `places` SSE side event as search_places, so the client photo strip
	// renders nearby results with zero changes.
	if len(results) > 0 {
		sendSSE(s.w, "places", map[string]any{
			"query":  in.Query,
			"places": placeCards(results, planPlacesCardCap),
		})
	}
	b, _ := json.Marshal(results)
	return string(b), false
}

// parkingCards is placeCards for ranked parking results: same photo-ref gate
// registration, plus the free_listed flag and a hardcoded "parking" category
// (MapGoogleTypeToCategory has no parking entry and feeds other surfaces).
func parkingCards(results []parkingResult, max int) []placeCard {
	if len(results) > max {
		results = results[:max]
	}
	cards := make([]placeCard, len(results))
	for i, r := range results {
		cards[i] = placeCard{
			Name:             r.Name,
			PlaceID:          r.PlaceID,
			Address:          r.Address,
			Latitude:         r.Latitude,
			Longitude:        r.Longitude,
			Rating:           r.Rating,
			PriceLevel:       r.PriceLevel,
			Category:         "parking",
			PhotoRef:         r.PhotoRef,
			PhotoAttribution: r.PhotoAttribution,
			FreeListed:       r.FreeListed,
		}
		placesService.allowPhotoRef(r.PhotoRef)
	}
	return cards
}

func runFindParkingTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		BeachName string  `json:"beach_name"`
		Latitude  float64 `json:"latitude"`
		Longitude float64 `json:"longitude"`
	}
	json.Unmarshal(input, &in)

	beach := strings.TrimSpace(in.BeachName)
	if beach == "" {
		return "Missing beach_name; ask the traveler which beach they mean.", true
	}

	// Same predicate as runSearchNearbyTool: (0,0)/out-of-range means "not
	// provided" — but here it degrades to a geocode instead of erroring, so
	// the model never has to invent coordinates.
	lat, lng := in.Latitude, in.Longitude
	if lat < -90 || lat > 90 || lng < -180 || lng > 180 || (lat == 0 && lng == 0) {
		geo, err := placesService.SearchPlaces(s.ctx, beach)
		if err != nil || len(geo) == 0 {
			return "Couldn't locate that beach; ask the traveler to confirm the beach name and city.", true
		}
		lat, lng = geo[0].Latitude, geo[0].Longitude
	}

	results, err := findParkingNearBeach(s.ctx, beach, lat, lng)
	if err != nil {
		return fmt.Sprintf("Error searching for parking: %v", err), true
	}
	if len(results) == 0 {
		return "No parking found within about 2 km of " + beach + "; suggest the traveler check side streets or arrive early.", false
	}
	sendSSE(s.w, "parking", map[string]any{
		"beach": beach,
		"spots": parkingCards(results, planPlacesCardCap),
	})
	b, _ := json.Marshal(results)
	return "Parking near " + beach + " (free_listed is a heuristic from the listing — present it as 'listed as free, verify locally'): " + string(b), false
}

func runCreateItineraryTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		Locations []map[string]any `json:"locations"`
		Title     string           `json:"title"`
		Summary   string           `json:"summary"`
		StartDate string           `json:"start_date"`
		EndDate   string           `json:"end_date"`
	}
	json.Unmarshal(input, &in)

	// Distance-optimize the walking order within each day/time-of-day
	// block, leaving Claude's day and time-of-day assignments intact.
	in.Locations = reorderItineraryByDistance(in.Locations)

	donePayload := map[string]any{"locations": in.Locations, "summary": in.Summary}
	// Persist the trip only for signed-in callers; anonymous sessions
	// stay ephemeral (no trip_id in the done event).
	if s.authed {
		if tripID, newLineage, err := persistTrip(s.ctx, s.uid, s.req.ChatID, in.Title, in.Summary, in.StartDate, in.EndDate, s.travelMode, in.Locations); err != nil {
			log.Printf("failed to persist trip: %v", err)
		} else {
			donePayload["trip_id"] = tripID
			if parsed, err := uuid.Parse(tripID); err == nil {
				s.tripID = &parsed
				safeGo("recordEvent", func() {
					recordEvent(s.uid, "trip_created", &parsed, map[string]any{
						"item_count": len(in.Locations),
					})
				})
				// Free-cap active_trips crossing signal — only a
				// brand-new lineage can move the lineage count; a
				// version save of an existing chat lineage leaves
				// it unchanged and must never emit
				// (specs/free-cap-instrumentation).
				if newLineage {
					safeGo("recordActiveTripsCapSignal", func() { recordActiveTripsCapSignal(s.uid, parsed) })
				}
			}
			// Distill what this conversation revealed about the traveler
			// in the background — it must never delay or fail the trip.
			// context.Background(): the request ctx dies with the handler.
			if !s.distilled {
				s.distilled = true
				safeGo("distillTravelerProfile", func() {
					distillTravelerProfile(context.Background(), s.client, s.uid, s.req.Messages)
				})
			}
		}
	}
	sendSSE(s.w, "done", donePayload)
	s.itineraryEmitted = true
	return "Itinerary created successfully.", false
}

func runUpdateItinerarySectionTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		Scope string           `json:"scope"`
		Day   *int             `json:"day"`
		City  string           `json:"city"`
		Items []map[string]any `json:"items"`
	}
	json.Unmarshal(input, &in)

	if s.boundTripID == nil {
		return "This session is not bound to a saved trip; update_itinerary_section is unavailable.", true
	}
	// Same in-block walking-distance cleanup create_itinerary gets.
	in.Items = reorderItineraryByDistance(in.Items)
	if err := replaceTripSection(s.ctx, *s.boundTripID, s.uid, sectionSelector{Scope: in.Scope, Day: in.Day, City: in.City}, in.Items); err != nil {
		return fmt.Sprintf("Could not update the section: %v", err), true
	}
	sendSSE(s.w, "trip_updated", map[string]string{"trip_id": s.boundTripID.String()})
	s.itineraryEmitted = true
	s.tripID = s.boundTripID
	safeGo("recordEvent", func() {
		recordEvent(s.uid, "trip_refined", s.boundTripID, map[string]any{
			"scope":           in.Scope,
			"is_collaborator": s.uid != s.boundTripOwnerID,
		})
	})
	// A collaborator refining the owner's trip in place is the canonical
	// agent collaborator-edit path. replaceTripSection's TouchTrip doesn't run
	// through touchedBy, so notify here; the SQL self-gates for owner refines.
	if s.uid != s.boundTripOwnerID {
		safeGo("notifyCollabEdit", func() { notifyCollabEdit(*s.boundTripID, s.uid) })
	}
	// Echo the post-state the traveler will SEE. A rewrite's day numbers are
	// positional, so a model with a wrong day→date mental model can "succeed"
	// indefinitely while the page never shows what it narrates (the Sep-24-27
	// loop of 2026-08-06); the rendered ranges make that falsifiable in the
	// same tool result. Best-effort: any read error degrades to the plain
	// confirmation rather than failing a write that already committed.
	result := "Section updated — the traveler's trip page has refreshed."
	if legs := sectionLegsRender(s); legs != "" {
		result += " The page now renders these city legs:\n" + legs +
			"A city's LAST item day is its departure day; each leg renders from the previous city's departure through its own last day. If these ranges don't match what the traveler asked for, do NOT resend the list with recomputed day numbers — use set_leg_dates (one city's dates) or set_trip_dates (the whole trip) with calendar dates."
	}
	return result, false
}

// sectionLegsRender re-reads the bound trip after a section rewrite and
// returns legsRenderSummary for it — "" when the trip has no start date, no
// dated legs, or any read fails (the write already committed; visibility is
// best-effort).
func sectionLegsRender(s *planSession) string {
	q := store.New(dbPool)
	trip, err := q.GetEditableTripByID(s.ctx, store.GetEditableTripByIDParams{ID: *s.boundTripID, UserID: s.uid})
	if err != nil || !trip.StartDate.Valid {
		return ""
	}
	items, err := q.GetItineraryItemsByTrip(s.ctx, *s.boundTripID)
	if err != nil {
		return ""
	}
	stays, err := q.ListAccommodationsByTrip(s.ctx, *s.boundTripID)
	if err != nil {
		return ""
	}
	return legsRenderSummary(items, stays, trip.StartDate.Time)
}

func runSavePreferencesTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		Budget       *string  `json:"budget"`
		Pace         *string  `json:"pace"`
		Interests    []string `json:"interests"`
		HomeAirport  *string  `json:"home_airport"`
		ProfileNotes *string  `json:"profile_notes"`
	}
	json.Unmarshal(input, &in)

	budget, _ := normalizeChoice(in.Budget, allowedBudgets, "budget")
	pace, _ := normalizeChoice(in.Pace, allowedPaces, "pace")
	homeAirport, _ := normalizeAirportCode(in.HomeAirport)
	var interestsArg interface{}
	if in.Interests != nil {
		interestsArg = normalizeInterests(in.Interests)
	}
	notes := normalizeNotes(in.ProfileNotes)
	if notes != nil && *notes == "" {
		// The agent can never wipe notes; only the user (PUT) can clear.
		notes = nil
	}
	_, err := store.New(dbPool).UpsertPreferences(s.ctx, store.UpsertPreferencesParams{
		UserID: s.uid, Budget: budget, Pace: pace, Interests: interestsArg, HomeAirport: homeAirport, ProfileNotes: notes,
	})
	if err != nil {
		return fmt.Sprintf("Could not save preferences: %v", err), true
	}
	var changed []string
	if budget != nil {
		changed = append(changed, "budget")
	}
	if pace != nil {
		changed = append(changed, "pace")
	}
	if interestsArg != nil {
		changed = append(changed, "interests")
	}
	if homeAirport != nil {
		changed = append(changed, "home_airport")
	}
	if notes != nil {
		changed = append(changed, "profile_notes")
	}
	if len(changed) > 0 {
		sendSSE(s.w, "profile_updated", map[string]any{
			"fields": changed, "notes_preview": notesPreview(notes),
		})
	}
	return "Preferences saved.", false
}

func runSuggestStaysTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		Destination string `json:"destination"`
		CheckIn     string `json:"check_in"`
		CheckOut    string `json:"check_out"`
		Guests      int    `json:"guests"`
	}
	json.Unmarshal(input, &in)
	links := providerLinks(AccommodationQuery{
		Destination: in.Destination, CheckIn: in.CheckIn, CheckOut: in.CheckOut, Guests: in.Guests,
	})
	sendSSE(s.w, "stays", map[string]any{"destination": in.Destination, "links": links})
	b, _ := json.Marshal(links)
	return "Provided browse links: " + string(b), false
}

func runSuggestTransportTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		Mode        string `json:"mode"`
		Origin      string `json:"origin"`
		Destination string `json:"destination"`
		DepartDate  string `json:"depart_date"`
		ReturnDate  string `json:"return_date"`
		Passengers  int    `json:"passengers"`
	}
	json.Unmarshal(input, &in)
	links := transportLinks(TransportQuery{
		Mode: in.Mode, Origin: in.Origin, Destination: in.Destination,
		DepartDate: in.DepartDate, ReturnDate: in.ReturnDate, Passengers: in.Passengers,
	})
	sendSSE(s.w, "transport", map[string]any{
		"mode": in.Mode, "origin": in.Origin, "destination": in.Destination, "links": links,
	})
	b, _ := json.Marshal(links)
	return "Provided browse links: " + string(b), false
}

func runSuggestFerriesTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		Origin      string `json:"origin"`
		Destination string `json:"destination"`
		Date        string `json:"date"`
		Passengers  int    `json:"passengers"`
	}
	json.Unmarshal(input, &in)
	options := ferryService.SearchFerries(FerryQuery{
		Origin: in.Origin, Destination: in.Destination,
		Date: in.Date, Passengers: in.Passengers,
	})
	sendSSE(s.w, "ferries", map[string]any{
		"origin": in.Origin, "destination": in.Destination, "options": options,
	})
	b, _ := json.Marshal(options)
	return "Provided ferry booking link(s): " + string(b), false
}

// runSuggestRepliesTool is a pure client-side emit (the suggest_stays
// template): no DB, no gate — sanitize, stream the side event, and tell the
// model to end its turn. The Flutter client stores the list and renders
// tappable chips once the stream closes; older clients ignore the event.
func runSuggestRepliesTool(s *planSession, input json.RawMessage) (string, bool) {
	if s.itineraryEmitted {
		return "This turn produced an itinerary — the itinerary banner owns the turn; quick replies were not shown.", true
	}
	var in struct {
		Replies []string `json:"replies"`
	}
	json.Unmarshal(input, &in)

	// A single surviving chip would read as the app pre-answering the
	// question, so fewer than two usable replies shows nothing.
	replies := sanitizeQuickReplies(in.Replies)
	if len(replies) < 2 {
		return "Fewer than 2 usable replies (2-4 short distinct strings required); none were shown.", true
	}
	sendSSE(s.w, "suggest_replies", map[string]any{"replies": replies})
	return "Quick replies are now shown to the traveler as tap buttons. End your turn now — do not repeat the options in text.", false
}

// sanitizeQuickReplies trims, drops empties/duplicates/oversized entries, and
// caps the list at 4. The 80-rune hard cap is looser than the schema's <60
// guidance so mildly-long valid replies survive; oversized ones are dropped,
// never truncated — a truncated reply sent verbatim would read as garbage in
// the traveler's transcript.
func sanitizeQuickReplies(raw []string) []string {
	replies := make([]string, 0, 4)
	for _, r := range raw {
		r = strings.TrimSpace(r)
		if r == "" || utf8.RuneCountInString(r) > 80 || slices.Contains(replies, r) {
			continue
		}
		replies = append(replies, r)
		if len(replies) == 4 {
			break
		}
	}
	return replies
}

func runSearchFlightsTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		Origin      string `json:"origin"`
		Destination string `json:"destination"`
		DepartDate  string `json:"depart_date"`
		ReturnDate  string `json:"return_date"`
		Adults      int    `json:"adults"`
		ChildAges   []int  `json:"child_ages"`
		CabinClass  string `json:"cabin_class"`
		OptimizeFor string `json:"optimize_for"`
		Baggage     string `json:"baggage"`
	}
	json.Unmarshal(input, &in)

	originIata := resolveIATA(s.ctx, in.Origin)
	destIata := resolveIATA(s.ctx, in.Destination)
	if originIata == "" || destIata == "" {
		return fmt.Sprintf("Could not resolve %q or %q to an airport. Ask the traveler to clarify the city or airport.", in.Origin, in.Destination), true
	}

	adults := in.Adults
	if adults < 1 {
		adults = 1
	}
	bestN, err := searchFlightsWithBaggage(s.ctx, duffelService, FlightSearchRequest{
		Origin: originIata, Destination: destIata, DepartDate: in.DepartDate,
		ReturnDate: in.ReturnDate, Adults: adults, ChildAges: in.ChildAges,
		CabinClass: in.CabinClass, OptimizeFor: in.OptimizeFor, Baggage: in.Baggage,
	})
	if err != nil {
		// Temporary-provider degrade: a working Google Flights deep link beats
		// a dead end (success-with-links idiom, like the Greek event_links
		// fallback below). Tool text only — the event_links chip is labeled
		// "Event sources" client-side, so reusing that SSE event would
		// mislabel a flights link. isError=false and an explicit no-retry
		// instruction: there is no per-tool retry guard, only
		// planMaxIterations, and a dead provider would burn the whole turn.
		// The raw err is deliberately not echoed (upstream bodies and
		// transport errors must never reach the model).
		if serpapiFlights.Active() {
			link := flightBookingURL("", "", originIata, destIata, in.DepartDate, in.ReturnDate)
			return fmt.Sprintf("Flight search is temporarily unavailable. Share this Google Flights link for %s→%s with the traveler and continue planning — do not call search_flights again this turn: %s", originIata, destIata, link), false
		}
		return fmt.Sprintf("Error searching flights: %v", err), true
	}
	if len(bestN) > 4 {
		bestN = bestN[:4]
	}
	attachBookingURLs(bestN, FlightSearchRequest{
		Origin: originIata, Destination: destIata,
		DepartDate: in.DepartDate, ReturnDate: in.ReturnDate, Adults: adults,
	})
	if len(bestN) > 0 {
		sendSSE(s.w, "flights", map[string]any{
			"origin": originIata, "destination": destIata,
			"depart_date": in.DepartDate, "optimize_for": normalizeOptimizeFor(in.OptimizeFor),
			"baggage": normalizeBaggage(in.Baggage),
			"offers":  bestN,
		})
	}
	return summarizeOffers(originIata, destIata, bestN), false
}

func runSearchEventsTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		City      string  `json:"city"`
		StartDate string  `json:"start_date"`
		EndDate   string  `json:"end_date"`
		Category  *string `json:"category"`
	}
	json.Unmarshal(input, &in)

	events, err := eventsService.SearchEvents(s.ctx, in.City, in.StartDate, in.EndDate, in.Category)
	if len(events) > 0 {
		sendSSE(s.w, "events", map[string]any{
			"city":       in.City,
			"start_date": in.StartDate,
			"end_date":   in.EndDate,
			"events":     events,
		})
	}

	// Greece has no usable events API, so when the structured lookup
	// comes back empty (or errors, e.g. no key) for a Greek city, fall
	// back to curated Greek source links instead of nothing.
	summary := summarizeEvents(in.City, events)
	if len(events) == 0 && isGreekLocation(in.City) {
		links := greekEventLinks(in.City, in.StartDate, in.EndDate)
		sendSSE(s.w, "event_links", map[string]any{"city": in.City, "links": links})
		b, _ := json.Marshal(links)
		summary = "No ticketed listings via the events provider for " + in.City +
			". Provided Greek event-discovery links: " + string(b)
	} else if err != nil {
		summary = fmt.Sprintf("Error searching events: %v", err)
	}

	return summary, err != nil && len(events) == 0 && !isGreekLocation(in.City)
}

func runSearchLocalRecsTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		City     string `json:"city"`
		Category string `json:"category"`
	}
	json.Unmarshal(input, &in)

	recs, err := localRecsService.SearchByCity(s.ctx, in.City, in.Category)
	if len(recs) > 0 {
		enrichLocalRecPhotos(s.ctx, recs)
		sendSSE(s.w, "local_recs", map[string]any{"city": in.City, "recommendations": recs})
	}
	summary := summarizeLocalRecs(in.City, recs)
	if err != nil {
		summary = fmt.Sprintf("Error searching local recommendations: %v", err)
	}
	return summary, err != nil
}
