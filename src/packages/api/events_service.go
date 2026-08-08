package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// EventsService handles local-events lookups via the Ticketmaster Discovery
// API. Like Duffel, it authenticates with a static key (passed as an `apikey`
// query param), so the service just attaches the key and decodes the response.
// The provider is isolated behind the Event type so it can be swapped without
// touching the handler, the plan agent, or the Flutter app.
type EventsService struct {
	APIKey  string
	BaseURL string
	Client  *http.Client

	// The free Ticketmaster key allows 5 req/s and 5k calls/day, and a plan
	// session can re-ask for the same city/window several times, so identical
	// searches within the TTL are served from memory (same pattern as the
	// Duffel airport cache). Short TTL: event inventory shifts.
	cache *ttlCache[[]Event]

	// Process-lifetime upstream-vs-cache-hit counters (reset on restart,
	// atomic — see upstreamCallCounters in places_service.go). No cost
	// estimate: the Ticketmaster key is free tier; this is quota/cache
	// visibility only.
	calls upstreamCallCounters
}

// Event is a normalized local event (concert, sport, festival, show) used by
// both the REST endpoint and the /plan agent's search_events tool.
type Event struct {
	ID        string  `json:"id"`
	Name      string  `json:"name"`
	Category  string  `json:"category"`             // e.g. "Music", "Sports", "Arts & Theatre"
	Venue     string  `json:"venue,omitempty"`      // venue name
	City      string  `json:"city,omitempty"`       // venue city
	StartDate string  `json:"start_date"`           // YYYY-MM-DD (local)
	StartTime string  `json:"start_time,omitempty"` // HH:MM (local), empty for all-day
	Latitude  float64 `json:"latitude,omitempty"`
	Longitude float64 `json:"longitude,omitempty"`
	URL       string  `json:"url,omitempty"`
	ImageURL  string  `json:"image_url,omitempty"`
}

// maxEvents caps how many events we return, to bound response size. fetchSize
// is the wider page we request from Ticketmaster before post-filtering to the
// trip window (its date filter is loose, so we ask for more and trim).
const (
	maxEvents = 30
	fetchSize = 100
)

// eventsCacheTTL bounds how long an events search result is reused.
const eventsCacheTTL = 20 * time.Minute

// NewEventsService creates a new events service, reading the Ticketmaster key
// from the environment. A missing key is a soft failure (a warning, like the
// Google/Duffel keys) so the rest of the API stays healthy; calls fail clearly.
func NewEventsService() *EventsService {
	apiKey := os.Getenv("TICKETMASTER_API_KEY")
	if apiKey == "" {
		fmt.Println("Warning: TICKETMASTER_API_KEY not set; events lookup disabled")
	}

	baseURL := os.Getenv("TICKETMASTER_BASE_URL")
	if baseURL == "" {
		baseURL = "https://app.ticketmaster.com/discovery/v2"
	}

	return &EventsService{
		APIKey:  apiKey,
		BaseURL: strings.TrimRight(baseURL, "/"),
		Client:  newUpstreamClient(30 * time.Second),
		cache:   newTTLCache[[]Event](eventsCacheTTL, 1000),
	}
}

// SearchEvents returns events in a city between startDate and endDate
// (inclusive, YYYY-MM-DD). category is optional and maps to Ticketmaster's
// classificationName (e.g. "music", "sports", "arts"). Returns a clear error
// when the key is missing or the dates are malformed.
func (s *EventsService) SearchEvents(ctx context.Context, city, startDate, endDate string, category *string) ([]Event, error) {
	if s.APIKey == "" {
		return nil, fmt.Errorf("Ticketmaster API key not configured")
	}
	startDT, err := toTicketmasterDateTime(startDate, false)
	if err != nil {
		return nil, fmt.Errorf("invalid start_date: %w", err)
	}
	endDT, err := toTicketmasterDateTime(endDate, true)
	if err != nil {
		return nil, fmt.Errorf("invalid end_date: %w", err)
	}

	// Cache identical searches for the TTL. Key covers every input that
	// changes the result set: city, window, and optional category.
	cat := ""
	if category != nil {
		cat = strings.ToLower(strings.TrimSpace(*category))
	}
	cacheKey := strings.ToLower(strings.TrimSpace(city)) + "|" + strings.TrimSpace(startDate) + "|" + strings.TrimSpace(endDate) + "|" + cat
	if cached, ok := s.cache.get(cacheKey); ok {
		s.calls.cacheHits.Add(1)
		return cached, nil
	}

	params := url.Values{}
	params.Set("apikey", s.APIKey)
	params.Set("city", city)
	params.Set("startDateTime", startDT)
	params.Set("endDateTime", endDT)
	params.Set("sort", "date,asc")
	// Ticketmaster returns localized names/descriptions where it has them; it
	// falls back to the source language on its own, so a thin Spanish catalog
	// degrades rather than emptying results (specs/i18n-spanish).
	params.Set("locale", requestLocale(ctx)+",*")
	// Over-fetch: Ticketmaster's date filter is loose and surfaces ongoing/flex
	// runs whose start date predates the window, so we fetch a wider page and
	// post-filter to the trip window below before capping at maxEvents.
	params.Set("size", strconv.Itoa(fetchSize))
	if category != nil {
		if c := strings.TrimSpace(*category); c != "" {
			params.Set("classificationName", c)
		}
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.BaseURL+"/events.json?"+params.Encode(), nil)
	if err != nil {
		return nil, fmt.Errorf("failed to build request: %w", err)
	}
	req.Header.Set("Accept", "application/json")

	s.calls.upstream.Add(1)
	resp, err := s.Client.Do(req)
	if err != nil {
		// redactTransportError: a *url.Error would embed the request URL,
		// apikey= included, into the error chain (and from there into
		// responses/tool results).
		return nil, fmt.Errorf("request failed: %w", redactTransportError(err))
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("Ticketmaster API error (%d): %s", resp.StatusCode, string(body))
	}

	var result struct {
		Embedded struct {
			Events []struct {
				ID    string `json:"id"`
				Name  string `json:"name"`
				URL   string `json:"url"`
				Dates struct {
					Start struct {
						LocalDate string `json:"localDate"`
						LocalTime string `json:"localTime"`
					} `json:"start"`
				} `json:"dates"`
				Images []struct {
					URL   string `json:"url"`
					Width int    `json:"width"`
				} `json:"images"`
				Classifications []struct {
					Segment struct {
						Name string `json:"name"`
					} `json:"segment"`
				} `json:"classifications"`
				Embedded struct {
					Venues []struct {
						Name string `json:"name"`
						City struct {
							Name string `json:"name"`
						} `json:"city"`
						Location struct {
							Latitude  string `json:"latitude"`
							Longitude string `json:"longitude"`
						} `json:"location"`
					} `json:"venues"`
				} `json:"_embedded"`
			} `json:"events"`
		} `json:"_embedded"`
	}
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("failed to parse events response: %w", err)
	}

	// Trip window bounds (YYYY-MM-DD) for post-filtering. Lexicographic compares
	// are correct for zero-padded ISO dates.
	winStart := strings.TrimSpace(startDate)
	winEnd := strings.TrimSpace(endDate)

	events := make([]Event, 0, len(result.Embedded.Events))
	// Collapse near-duplicates: timed-entry attractions list the same event at
	// many slots (every 15 min), so we keep one card per name (the earliest,
	// since results are sorted date,asc) and let distinct events through.
	seen := map[string]bool{}
	for _, e := range result.Embedded.Events {
		// Keep only events whose local start date falls within the trip window.
		// Ticketmaster also returns ongoing/flex runs whose start date predates
		// the window (with a misleading single date), which we drop here.
		sd := e.Dates.Start.LocalDate
		if sd == "" || sd < winStart || sd > winEnd {
			continue
		}
		nameKey := strings.ToLower(strings.TrimSpace(e.Name))
		if seen[nameKey] {
			continue
		}
		seen[nameKey] = true
		ev := Event{
			ID:        e.ID,
			Name:      e.Name,
			URL:       e.URL,
			StartDate: e.Dates.Start.LocalDate,
			StartTime: trimSeconds(e.Dates.Start.LocalTime),
			ImageURL:  pickImage(e.Images),
		}
		if len(e.Classifications) > 0 {
			ev.Category = e.Classifications[0].Segment.Name
		}
		if len(e.Embedded.Venues) > 0 {
			v := e.Embedded.Venues[0]
			ev.Venue = v.Name
			ev.City = v.City.Name
			ev.Latitude, _ = strconv.ParseFloat(v.Location.Latitude, 64)
			ev.Longitude, _ = strconv.ParseFloat(v.Location.Longitude, 64)
		}
		events = append(events, ev)
		if len(events) >= maxEvents {
			break
		}
	}
	s.cache.set(cacheKey, events)
	return events, nil
}

// toTicketmasterDateTime converts a YYYY-MM-DD date into the ISO-8601 UTC
// instant Ticketmaster expects (no millis, trailing Z). endOfDay picks the
// inclusive end of the window.
func toTicketmasterDateTime(date string, endOfDay bool) (string, error) {
	t, err := time.Parse("2006-01-02", strings.TrimSpace(date))
	if err != nil {
		return "", fmt.Errorf("expected YYYY-MM-DD: %w", err)
	}
	if endOfDay {
		return t.Format("2006-01-02") + "T23:59:59Z", nil
	}
	return t.Format("2006-01-02") + "T00:00:00Z", nil
}

// trimSeconds normalizes Ticketmaster's "HH:MM:SS" local time to "HH:MM".
func trimSeconds(t string) string {
	if len(t) >= 5 {
		return t[:5]
	}
	return t
}

// pickImage returns the widest image URL, falling back to the first.
func pickImage(images []struct {
	URL   string `json:"url"`
	Width int    `json:"width"`
}) string {
	best := ""
	bestW := -1
	for _, img := range images {
		if img.Width > bestW {
			bestW = img.Width
			best = img.URL
		}
	}
	return best
}

// eventsService is a process-wide singleton reused across requests (the HTTP
// client and config are shared; auth is a static key).
var eventsService = NewEventsService()

// eventsSearchHandler handles local-events search requests for a city + date
// window. Mirrors placesSearchHandler's response shape.
func eventsSearchHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	q := r.URL.Query()
	city := strings.TrimSpace(q.Get("city"))
	startDate := strings.TrimSpace(q.Get("start_date"))
	endDate := strings.TrimSpace(q.Get("end_date"))
	if city == "" || startDate == "" || endDate == "" {
		http.Error(w, "Missing required query parameters 'city', 'start_date', and 'end_date'", http.StatusBadRequest)
		return
	}

	var category *string
	if c := strings.TrimSpace(q.Get("category")); c != "" {
		category = &c
	}

	events, err := eventsService.SearchEvents(r.Context(), city, startDate, endDate, category)
	if err != nil {
		// Log the detail server-side; clients get a generic message so
		// provider/internal error strings never reach an unauthenticated
		// caller.
		ctxLog(r.Context()).Error("events search failed", "error", err)
		http.Error(w, "Failed to search events", http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"events": events,
		"status": "success",
	})
}
