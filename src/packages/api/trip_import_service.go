package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	anthropic "github.com/anthropics/anthropic-sdk-go"
	"github.com/google/uuid"

	"travel-route-planner/store"
)

// trip_import_service.go turns a pasted external-AI conversation (ChatGPT,
// Claude, …) into a persisted trip: one forced-tool extraction call (the
// local_extraction_service.go pattern), a Google Places pass to resolve
// coordinates (the ingestLocalHandler pattern), then the existing persistTrip
// primitive. importTripCore is deliberately handler-free so the future MCP
// connector's create_trip tool (specs/mcp-connector) can call it directly.

const (
	importToolName = "import_trip"
	// The extraction emits up to importMaxLocations structured places, so it
	// needs more room than local ingest's 90s / 4k tokens.
	importTimeout      = 120 * time.Second
	importMaxTokens    = 8192
	importMaxChars     = 60000
	importHeadChars    = 10000
	importMaxLocations = 80
	// Each unresolved place costs one Places Text Search (~$0.032). The cap
	// bounds worst-case spend per import; places past it fall back to the
	// model-coordinate tier below rather than being dropped outright.
	importMaxPlaceLookups = 50
	importSystemPrompt    = "You extract a travel itinerary from a pasted AI-chat conversation or trip summary. " +
		"Call import_trip exactly once. " +
		"STRICT RULES: Use ONLY places actually named in the provided text — never invent or pad with your own suggestions. " +
		"If several itinerary drafts appear, extract the FINAL agreed version. " +
		"`search_hint` is the best short string to find the exact place on a map (place name + city). " +
		"`city` is the actual municipality the place is in (e.g. 'Versailles', not 'Paris'); use `day_trip_from` for the hub city when the place is a same-day trip from where the traveler stays. " +
		"`day` starts at 1 and increases chronologically across the whole trip; all places on the same day share the number. " +
		"Spread `time_of_day` sensibly (sights across morning-afternoon, meals at their natural times) when the text implies an order. " +
		"`category` is 'restaurant' for places you eat or drink, otherwise 'attraction'. " +
		"Only set start_date/end_date when actual dates are stated in the text (YYYY-MM-DD). " +
		"Only set latitude/longitude when you are confident of the approximate coordinates; they are a fallback, never required. " +
		"If the text contains no recognizable trip, return an empty locations array."
)

// errImportNoTrip: the model found no itinerary in the text.
// errImportNothingLocated: an itinerary was found but no place survived
// coordinate resolution. Both surface as 422s, with different copy.
var (
	errImportNoTrip         = errors.New("no trip found in text")
	errImportNothingLocated = errors.New("no places could be located")
	// errImportPlacesUnavailable: nothing could be kept because Places lookups
	// were FAILING (outage/quota), not because the places don't exist — a
	// retryable condition, never the user's fault.
	errImportPlacesUnavailable = errors.New("place lookups unavailable")
	// errImportTripLimit: the per-user trip-lineage cap, checked before any
	// model/Places spend (persistTrip re-checks transactionally).
	errImportTripLimit = errors.New("trip limit reached")
)

// isPlacesZeroResults distinguishes a genuine "Google found nothing" from an
// outage/quota/transport failure. SearchPlaces folds both into an error;
// ZERO_RESULTS is the one non-OK status that means the query itself came up
// empty (places_service.go returns "Google Places API error: <status>").
func isPlacesZeroResults(err error) bool {
	return err != nil && strings.Contains(err.Error(), "ZERO_RESULTS")
}

// importPhaseError tags a failure with the pipeline phase so the handler can
// map extraction problems to 502 and persistence problems to 500/422 without
// string-sniffing the whole chain.
type importPhaseError struct {
	phase string // "extract" | "persist"
	err   error
}

func (e *importPhaseError) Error() string { return e.err.Error() }
func (e *importPhaseError) Unwrap() error { return e.err }

// ImportedLocation is one place as the model proposes it — coordinates are an
// optional model-confidence fallback; the authoritative ones come from Google.
type ImportedLocation struct {
	Name        string   `json:"name"`
	City        string   `json:"city"`
	DayTripFrom string   `json:"day_trip_from"`
	Category    string   `json:"category"`
	TimeOfDay   string   `json:"time_of_day"`
	Day         int      `json:"day"`
	SearchHint  string   `json:"search_hint"`
	Latitude    *float64 `json:"latitude"`
	Longitude   *float64 `json:"longitude"`
}

type ImportedTrip struct {
	Title      string             `json:"title"`
	Summary    string             `json:"summary"`
	StartDate  string             `json:"start_date"`
	EndDate    string             `json:"end_date"`
	TravelMode string             `json:"travel_mode"`
	Locations  []ImportedLocation `json:"locations"`
}

// importStats feeds the trip_imported analytics event and the response warnings.
type importStats struct {
	Resolved    int
	Approximate int
	Dropped     int
	// LookupFailures counts Places calls that errored for reasons other than
	// ZERO_RESULTS (outage, quota, transport) — places affected by these ride
	// the approximate/dropped tiers under one aggregate warning instead of
	// per-place "couldn't be located" blame.
	LookupFailures int
	// Omitted counts extracted places cut by the importMaxLocations cap.
	Omitted int
}

type importResult struct {
	TripID    string
	Title     string
	ItemCount int
	Warnings  []string
}

// truncateForImport keeps the head and tail of an oversized paste. Unlike the
// head-only truncation in local ingest, a chat transcript's two load-bearing
// regions are its start (destination, dates) and its end (the final agreed
// itinerary) — the middle back-and-forth is the expendable part. Rune-based so
// we never split a UTF-8 sequence.
func truncateForImport(s string) string {
	r := []rune(s)
	if len(r) <= importMaxChars {
		return s
	}
	const marker = "\n[... middle of conversation truncated ...]\n"
	tail := importMaxChars - importHeadChars
	return string(r[:importHeadChars]) + marker + string(r[len(r)-tail:])
}

// plausibleCoords reports whether a model-supplied coordinate pair is usable
// as a flagged fallback: both present, in range, and not the (0,0) null-island
// filler models emit when guessing.
func plausibleCoords(lat, lng *float64) bool {
	if lat == nil || lng == nil {
		return false
	}
	if *lat < -90 || *lat > 90 || *lng < -180 || *lng > 180 {
		return false
	}
	return *lat != 0 || *lng != 0
}

// extractImportedTrip runs the single forced-tool call and returns the parsed
// itinerary proposal.
func extractImportedTrip(ctx context.Context, client anthropic.Client, rawText string) (ImportedTrip, error) {
	ctx, cancel := context.WithTimeout(ctx, importTimeout)
	defer cancel()

	rawText = truncateForImport(rawText)

	tool := anthropic.ToolParam{
		Name:        importToolName,
		Description: anthropic.String("Record the structured trip itinerary extracted from the pasted conversation or summary."),
		InputSchema: anthropic.ToolInputSchemaParam{
			Properties: map[string]any{
				"title":      map[string]any{"type": "string", "description": "Short trip name, e.g. 'Lisbon & Porto'"},
				"summary":    map[string]any{"type": "string", "description": "2-3 sentence trip summary"},
				"start_date": map[string]any{"type": "string", "description": "YYYY-MM-DD, only if stated in the text"},
				"end_date":   map[string]any{"type": "string", "description": "YYYY-MM-DD, only if stated in the text"},
				"travel_mode": map[string]any{
					"type": "string",
					"enum": []string{"flight", "car", "train", "bus", "ferry", "mixed"},
				},
				"locations": map[string]any{
					"type": "array",
					"items": map[string]any{
						"type": "object",
						"properties": map[string]any{
							"name": map[string]any{"type": "string"},
							"city": map[string]any{
								"type":        "string",
								"description": "The municipality the place is physically in — 'Versailles', not 'Paris'.",
							},
							"day_trip_from": map[string]any{
								"type":        "string",
								"description": "Hub city when this place is a same-day trip from where the traveler stays.",
							},
							"category":    map[string]any{"type": "string", "enum": []string{"attraction", "restaurant"}},
							"time_of_day": map[string]any{"type": "string", "enum": []string{"morning", "afternoon", "evening"}},
							"day":         map[string]any{"type": "integer", "description": "Trip day, 1-based, chronological across the whole trip"},
							"search_hint": map[string]any{"type": "string", "description": "Best string to locate the place on a map"},
							"latitude":    map[string]any{"type": "number", "description": "Approximate, only if confident"},
							"longitude":   map[string]any{"type": "number", "description": "Approximate, only if confident"},
						},
						"required": []string{"name", "city", "search_hint"},
					},
				},
			},
			Required: []string{"title", "locations"},
		},
	}

	// The heavy model, not the light one: a one-shot user-visible result with
	// no chat loop to repair it, and the live /plan agent already produces
	// this exact location shape on the same model — the schema conventions
	// are battle-tested against it.
	resp, err := client.Messages.New(ctx, anthropic.MessageNewParams{
		Model:      aiModel(),
		MaxTokens:  importMaxTokens,
		System:     []anthropic.TextBlockParam{{Text: importSystemPrompt}},
		Tools:      []anthropic.ToolUnionParam{{OfTool: &tool}},
		ToolChoice: anthropic.ToolChoiceParamOfTool(importToolName),
		Thinking:   forcedToolThinking(),
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock(
				"Pasted conversation or trip summary:\n\n" + rawText)),
		},
	})
	if err != nil {
		return ImportedTrip{}, fmt.Errorf("import model call: %w", err)
	}

	for _, block := range resp.Content {
		if variant, ok := block.AsAny().(anthropic.ToolUseBlock); ok && variant.Name == importToolName {
			var out ImportedTrip
			if err := json.Unmarshal(variant.Input, &out); err != nil {
				return ImportedTrip{}, fmt.Errorf("parse import: %w", err)
			}
			return out, nil
		}
	}
	return ImportedTrip{}, fmt.Errorf("model did not return %s", importToolName)
}

// resolveImportedLocations verifies each extracted place against Google Places
// and returns persistTrip-shaped location maps plus user-facing warnings.
// Coordinate tiers: Google hit (authoritative) > plausible model coordinates
// (kept, flagged approximate) > neither (dropped, named in a warning).
// itinerary_items.latitude/longitude are NOT NULL and a (0,0) pin ruins the
// map — but unlike the local-content publish gate, this is the user's own
// private trip, so approximate-and-flagged beats failing the import.
func resolveImportedLocations(ctx context.Context, locs []ImportedLocation) ([]map[string]any, importStats, []string) {
	locale := requestLocale(ctx)
	var (
		out      []map[string]any
		stats    importStats
		warnings []string
		lookups  int
	)

	// Degraded mode: no Places key means every lookup would error identically.
	// Skip the loop's per-place noise and emit one aggregate warning instead.
	placesAvailable := placesService.APIKey != ""
	if !placesAvailable {
		warnings = append(warnings, tr(locale, "import.warning.unverified"))
	}

	for _, l := range locs {
		name := strings.TrimSpace(l.Name)
		if name == "" {
			continue
		}
		loc := map[string]any{"name": name}
		if c := strings.TrimSpace(l.City); c != "" {
			loc["city"] = c
		}
		if d := strings.TrimSpace(l.DayTripFrom); d != "" {
			loc["day_trip_from"] = d
		}
		if l.Category != "" {
			loc["category"] = l.Category
		}
		if l.TimeOfDay != "" {
			loc["time_of_day"] = l.TimeOfDay
		}
		if l.Day >= 1 {
			// JSON numbers decode as float64; itemParamsFromLocation expects
			// that shape (see locationFromItem).
			loc["day"] = float64(l.Day)
		}

		resolved := false
		lookupFailed := false
		if placesAvailable && lookups < importMaxPlaceLookups {
			lookups++
			hits, lerr := placesService.SearchPlaces(ctx, placeQuery(l.SearchHint, name, l.City))
			switch {
			case lerr == nil && len(hits) > 0:
				hit := hits[0]
				loc["latitude"] = hit.Latitude
				loc["longitude"] = hit.Longitude
				if hit.PlaceID != "" {
					loc["place_id"] = hit.PlaceID
				}
				if hit.Address != "" {
					loc["address"] = hit.Address
				}
				resolved = true
				stats.Resolved++
			case lerr != nil && !isPlacesZeroResults(lerr):
				// Outage/quota/transport — NOT evidence the place doesn't
				// exist. Log the first occurrence; affected places fall to the
				// tiers below without per-place "couldn't be located" blame.
				if stats.LookupFailures == 0 {
					ctxLog(ctx).Error("trip import: place lookup failed", "error", lerr)
				}
				stats.LookupFailures++
				lookupFailed = true
			}
		}
		if !resolved {
			if plausibleCoords(l.Latitude, l.Longitude) {
				loc["latitude"] = *l.Latitude
				loc["longitude"] = *l.Longitude
				stats.Approximate++
				if placesAvailable && !lookupFailed {
					warnings = append(warnings, tr(locale, "import.warning.approximate", name))
				}
			} else {
				stats.Dropped++
				// Name every dropped place EXCEPT ones a failing lookup
				// touched (the aggregate outage warning covers those — a
				// place we never searched earned no "couldn't be located").
				if !lookupFailed {
					warnings = append(warnings, tr(locale, "import.warning.dropped", name))
				}
				continue
			}
		}
		out = append(out, loc)
	}
	// One aggregate notice covers every place a failing lookup touched — same
	// copy as the no-key degraded mode, since the user-visible effect matches.
	if stats.LookupFailures > 0 {
		warnings = append(warnings, tr(locale, "import.warning.unverified"))
	}
	return out, stats, warnings
}

// importTripCore is the reusable extract -> resolve -> persist pipeline behind
// POST /trips/import (and, later, the MCP connector's create_trip tool).
func importTripCore(ctx context.Context, client anthropic.Client, userID uuid.UUID, rawText, source string) (importResult, error) {
	// Trip-lineage cap BEFORE any model/Places spend: an import always mints a
	// new lineage, so a capped user's request would only burn upstream dollars
	// to fail inside persistTrip. Fail-open on a check error — persistTrip
	// re-checks transactionally.
	if n, err := store.New(dbPool).CountActiveTripLineagesByOwner(ctx, userID); err == nil && int(n) >= maxTripsPerUser() {
		return importResult{}, errImportTripLimit
	}

	extracted, err := extractImportedTrip(ctx, client, rawText)
	if err != nil {
		return importResult{}, &importPhaseError{phase: "extract", err: err}
	}
	if len(extracted.Locations) == 0 {
		return importResult{}, errImportNoTrip
	}
	omitted := 0
	if len(extracted.Locations) > importMaxLocations {
		omitted = len(extracted.Locations) - importMaxLocations
		extracted.Locations = extracted.Locations[:importMaxLocations]
	}

	locations, stats, warnings := resolveImportedLocations(ctx, extracted.Locations)
	stats.Omitted = omitted
	if omitted > 0 {
		// Never silently lose places the user's conversation named — the cap
		// must be visible (spec: "dropped and named in a warning" applies in
		// spirit; at this volume we name the count, not 10+ places).
		warnings = append(warnings, tr(requestLocale(ctx), "import.warning.capped", importMaxLocations, omitted))
	}
	if len(locations) == 0 {
		if stats.LookupFailures > 0 {
			return importResult{}, errImportPlacesUnavailable
		}
		return importResult{}, errImportNothingLocated
	}

	// Same walking-order optimization the in-app agent applies: reorder within
	// each day/time-of-day block by distance, keeping the day structure intact.
	locations = reorderItineraryByDistance(locations)

	chatToken, err := generateSessionToken()
	if err != nil {
		return importResult{}, &importPhaseError{phase: "persist", err: err}
	}
	chatID := "chat-" + chatToken

	tripID, newLineage, err := persistTrip(ctx, userID, chatID,
		extracted.Title, extracted.Summary, extracted.StartDate, extracted.EndDate,
		extracted.TravelMode, locations)
	if err != nil {
		return importResult{}, &importPhaseError{phase: "persist", err: err}
	}

	res := importResult{TripID: tripID, Title: strings.TrimSpace(extracted.Title), ItemCount: len(locations), Warnings: warnings}
	if res.Warnings == nil {
		res.Warnings = []string{}
	}

	parsed, perr := uuid.Parse(tripID)
	if perr == nil {
		// Report the title persistTrip actually stored (it applies fallback
		// chains the extraction title may have skipped).
		if trip, terr := store.New(dbPool).GetTripByIDAndOwner(ctx, store.GetTripByIDAndOwnerParams{ID: parsed, UserID: userID}); terr == nil {
			res.Title = trip.Title
		}
		safeGo("recordEvent", func() {
			recordEvent(userID, "trip_created", &parsed, map[string]any{
				"item_count": res.ItemCount,
				"source":     "import",
			})
			recordEvent(userID, "trip_imported", &parsed, map[string]any{
				"item_count":      res.ItemCount,
				"resolved":        stats.Resolved,
				"approximate":     stats.Approximate,
				"dropped":         stats.Dropped,
				"omitted":         stats.Omitted,
				"lookup_failures": stats.LookupFailures,
				"provider":        source,
			})
		})
		// Free-cap active_trips crossing signal — imports always mint a fresh
		// chat lineage, but keep the guard so a future caller reusing a lineage
		// can't over-emit (specs/free-cap-instrumentation).
		if newLineage {
			safeGo("recordActiveTripsCapSignal", func() { recordActiveTripsCapSignal(userID, parsed) })
		}
	}
	return res, nil
}
