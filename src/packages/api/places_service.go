package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// Google Places API base URLs. Package vars (not consts) so tests can point the
// client at an httptest server — matching the seam other provider services use.
var (
	placesTextSearchURL   = "https://maps.googleapis.com/maps/api/place/textsearch/json"
	placesAutocompleteURL = "https://maps.googleapis.com/maps/api/place/autocomplete/json"
	placesDetailsURL      = "https://maps.googleapis.com/maps/api/place/details/json"
	placesPhotoURL        = "https://maps.googleapis.com/maps/api/place/photo"
)

// upstreamCallCounters tracks billable upstream calls vs cache hits for one
// endpoint class of a provider service. PROCESS-LIFETIME: counters start at
// zero on boot and reset on every restart/deploy — they are telemetry for
// directional spend visibility, not audited, window-scoped analytics (nothing
// here is persisted). Atomic adds only, so the hot path takes no locks and
// gains no contention.
type upstreamCallCounters struct {
	upstream  atomic.Int64
	cacheHits atomic.Int64
}

// UpstreamCallCounts is the JSON snapshot of one counter pair, as exposed by
// the admin metrics endpoint.
type UpstreamCallCounts struct {
	Upstream  int64 `json:"upstream"`
	CacheHits int64 `json:"cache_hits"`
}

// snapshot reads both counters. The two loads are not a single atomic unit,
// which is fine for a dashboard tile.
func (c *upstreamCallCounters) snapshot() UpstreamCallCounts {
	return UpstreamCallCounts{Upstream: c.upstream.Load(), CacheHits: c.cacheHits.Load()}
}

// redactTransportError strips the request URL from transport-level HTTP
// errors before they enter an error chain. http.Client failures come back as
// *url.Error, whose Error() embeds the FULL request URL — including secret
// query parameters like key=/apikey= (Go redacts only userinfo passwords,
// never the query string). Wrapping ue.Err instead keeps the useful cause
// (DNS failure, timeout, connection refused) while guaranteeing the secret
// can never reach handler responses or the /plan agent's tool results.
// Defense-in-depth: handlers additionally return generic messages and log
// the detail server-side.
func redactTransportError(err error) error {
	var ue *url.Error
	if errors.As(err, &ue) {
		return ue.Err
	}
	return err
}

// GooglePlacesService handles Google Places API interactions
type GooglePlacesService struct {
	APIKey string
	Client *http.Client

	// PhotoClient mirrors Client but stops at the first redirect
	// (CheckRedirect: ErrUseLastResponse) so ResolvePhotoURL can capture the
	// Place Photo API's 302 Location header instead of downloading the image
	// bytes.
	PhotoClient *http.Client

	// Every Google call is billable; identical lookups within the TTL are
	// served from memory. Autocomplete/details cache long (place data is
	// stable), text search shorter (result sets shift more).
	searchCache       *ttlCache[[]PlaceSearchResult]
	autocompleteCache *ttlCache[[]PlaceAutocompleteResult]
	detailsCache      *ttlCache[*PlaceDetailsResult]

	// photoRefCache: place_id → first photo ref + stripped attribution, from
	// fields=photo details lookups (local-rec venue enrichment). Empty results
	// are cached too, so photo-less venues cost one call per TTL, not one per
	// chat turn. photoURLCache: "ref|width" → googleusercontent URL captured
	// from the Place Photo 302; those URLs carry signed tokens with no
	// documented lifetime, so the TTL stays conservative. knownPhotoRefs is
	// the anti-abuse gate: /places/photo only serves refs this process itself
	// handed to a client (SSE place cards / rec enrichment) — unknown ref →
	// 404 with zero Google spend, so the endpoint can't be used as an open
	// photo proxy billed to us.
	photoRefCache  *ttlCache[placePhotoRef]
	photoURLCache  *ttlCache[string]
	knownPhotoRefs *ttlCache[struct{}]

	// Process-lifetime call counters per endpoint class (see
	// upstreamCallCounters — reset on restart, atomic, never persisted).
	// "upstream" increments at the exact point an HTTP request to Google is
	// issued (the billable moment); "cacheHits" where the TTL cache
	// short-circuits. Snapshotted by the admin metrics endpoint for
	// directional Places-spend visibility.
	searchCalls       upstreamCallCounters
	autocompleteCalls upstreamCallCounters
	detailsCalls      upstreamCallCounters
	photoLookupCalls  upstreamCallCounters
	photoCalls        upstreamCallCounters
}

// placePhotoRef is one cached venue-photo lookup; both fields empty means the
// venue has no photo (negative results are cached deliberately).
type placePhotoRef struct {
	Ref         string
	Attribution string
}

// PlaceSearchResult represents a place from Google Places API
type PlaceSearchResult struct {
	PlaceID    string   `json:"place_id"`
	Name       string   `json:"name"`
	Address    string   `json:"formatted_address"`
	Latitude   float64  `json:"lat"`
	Longitude  float64  `json:"lng"`
	Types      []string `json:"types"`
	Rating     *float64 `json:"rating,omitempty"`
	PriceLevel *int     `json:"price_level,omitempty"`

	// PhotoRef/PhotoAttribution are json:"-" on purpose: they ride the struct
	// into the SSE `places` cards but must never serialize into the
	// model-facing tool_result (refs are ~150 opaque chars of token bloat) or
	// the public /places/search response.
	PhotoRef         string `json:"-"`
	PhotoAttribution string `json:"-"`

	// UserRatingsTotal rides along for SearchLodging, where "4.8 from 6,749
	// reviews" and "4.8 from 3" are very different recommendations. json:"-"
	// for the same reason as the photo fields: adding a key would change both
	// the model-facing tool_result and the public /places/search JSON, and
	// nothing else asked for it.
	UserRatingsTotal *int `json:"-"`
}

// PlaceAutocompleteResult represents autocomplete suggestions
type PlaceAutocompleteResult struct {
	PlaceID     string   `json:"place_id"`
	Description string   `json:"description"`
	Types       []string `json:"types"`
}

// PlaceDetailsResult represents detailed place information
type PlaceDetailsResult struct {
	PlaceID      string              `json:"place_id"`
	Name         string              `json:"name"`
	Address      string              `json:"formatted_address"`
	Latitude     float64             `json:"lat"`
	Longitude    float64             `json:"lng"`
	Types        []string            `json:"types"`
	Rating       *float64            `json:"rating,omitempty"`
	PriceLevel   *int                `json:"price_level,omitempty"`
	OpeningHours *GoogleOpeningHours `json:"opening_hours,omitempty"`
	Website      *string             `json:"website,omitempty"`
	PhoneNumber  *string             `json:"formatted_phone_number,omitempty"`
}

// GoogleOpeningHours represents Google's opening hours format
type GoogleOpeningHours struct {
	OpenNow     bool     `json:"open_now"`
	WeekdayText []string `json:"weekday_text"`
}

// NewGooglePlacesService creates a new Google Places service
func NewGooglePlacesService() *GooglePlacesService {
	apiKey := os.Getenv("GOOGLE_PLACES_API_KEY")
	if apiKey == "" {
		fmt.Println("Warning: GOOGLE_PLACES_API_KEY environment variable not set")
	}

	return &GooglePlacesService{
		APIKey: apiKey,
		// An explicit timeout is essential: SearchPlaces/GetPlaceDetails run
		// synchronously inside the /plan agent loop, so a hung Google socket
		// with a zero-value (no-timeout) client would stall the whole SSE
		// stream forever. This is a hard backstop on top of the per-call
		// context deadline threaded through each method.
		Client: newUpstreamClient(15 * time.Second),
		PhotoClient: &http.Client{
			Timeout:   15 * time.Second,
			Transport: sharedTransport, // pool shared with Client; CheckRedirect is per-client
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
		searchCache:       newTTLCache[[]PlaceSearchResult](1*time.Hour, 2000),
		autocompleteCache: newTTLCache[[]PlaceAutocompleteResult](24*time.Hour, 5000),
		detailsCache:      newTTLCache[*PlaceDetailsResult](24*time.Hour, 5000),
		photoRefCache:     newTTLCache[placePhotoRef](24*time.Hour, 5000),
		photoURLCache:     newTTLCache[string](12*time.Hour, 5000),
		knownPhotoRefs:    newTTLCache[struct{}](24*time.Hour, 10000),
	}
}

// doGet issues a context-aware GET so the caller's deadline/cancellation aborts
// a slow Google call. Paired with the client's Timeout, this guarantees a
// Places lookup can never block the synchronous /plan agent loop indefinitely.
func (gps *GooglePlacesService) doGet(ctx context.Context, fullURL string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, fullURL, nil)
	if err != nil {
		return nil, err
	}
	return gps.Client.Do(req)
}

// placesService is a process-wide singleton reused across requests, matching
// duffelService/eventsService/weatherService. Constructing it once is what
// makes the TTL caches above effective — a per-request instance would discard
// them and re-bill Google on every call. A missing GOOGLE_PLACES_API_KEY stays
// a soft failure (one boot-time warning; each method returns a clear error),
// so degraded mode keeps working.
var placesService = NewGooglePlacesService()

// SearchPlaces searches for places by text query. The context bounds the
// upstream HTTP call so a caller cancelling (or a request deadline) aborts a
// slow Google lookup instead of blocking — critical on the synchronous /plan
// agent path.
func (gps *GooglePlacesService) SearchPlaces(ctx context.Context, query string) ([]PlaceSearchResult, error) {
	cacheKey := strings.ToLower(strings.TrimSpace(query))
	return gps.textSearch(ctx, cacheKey, query, nil)
}

// nearbySearchRadiusMeters is the location-bias radius sent with
// SearchPlacesNearby. Text Search treats location+radius as a bias, not a hard
// filter — Google may still return farther results for sparse queries.
const nearbySearchRadiusMeters = 3000

// SearchPlacesNearby is SearchPlaces with a location bias, for "what's near
// me" lookups. Coordinates are rounded to 4 decimals (~11 m) before both the
// request and the cache key, so jittery client GPS fixes share cache entries
// and precise positions never reach the URL.
func (gps *GooglePlacesService) SearchPlacesNearby(ctx context.Context, query string, lat, lng float64) ([]PlaceSearchResult, error) {
	loc := fmt.Sprintf("%.4f,%.4f", lat, lng)
	// The "|lat,lng|radius" suffix keeps biased entries disjoint from plain
	// SearchPlaces keys in the shared cache.
	cacheKey := fmt.Sprintf("%s|%s|%d", strings.ToLower(strings.TrimSpace(query)), loc, nearbySearchRadiusMeters)
	return gps.textSearch(ctx, cacheKey, query, func(params url.Values) {
		params.Add("location", loc)
		params.Add("radius", strconv.Itoa(nearbySearchRadiusMeters))
	})
}

// parkingSearchRadiusMeters is the location-bias radius for
// SearchParkingNearby — tighter than nearbySearchRadiusMeters because parking
// is only useful within a short walk of the target. Like all Text Search
// biases it is not a hard filter; callers post-filter by distance.
const parkingSearchRadiusMeters = 2000

// SearchParkingNearby is SearchPlacesNearby tuned for parking lookups
// (specs/find-parking-near-beach): same coordinate rounding, a tighter
// radius, and Google's type=parking bias. The "parking|" cache-key prefix
// keeps entries disjoint from the other Text Search variants in the shared
// cache.
func (gps *GooglePlacesService) SearchParkingNearby(ctx context.Context, query string, lat, lng float64) ([]PlaceSearchResult, error) {
	loc := fmt.Sprintf("%.4f,%.4f", lat, lng)
	cacheKey := fmt.Sprintf("parking|%s|%s|%d", strings.ToLower(strings.TrimSpace(query)), loc, parkingSearchRadiusMeters)
	return gps.textSearch(ctx, cacheKey, query, func(params url.Values) {
		params.Add("location", loc)
		params.Add("radius", strconv.Itoa(parkingSearchRadiusMeters))
		params.Add("type", "parking")
	})
}

// SearchLodging is SearchPlaces tuned for stays (specs/hotel-search): the
// same Text Search with Google's type=lodging filter, and its own "lodging|"
// cache-key prefix so entries stay disjoint from the other variants sharing
// the cache. Same shape as SearchParkingNearby, minus the location bias — a
// lodging query is city-wide by nature.
//
// This is the DISCOVERY tier and can never be the rates tier: Google returns
// price_level null for lodging in practice, so nothing here carries a price.
func (gps *GooglePlacesService) SearchLodging(ctx context.Context, query string) ([]PlaceSearchResult, error) {
	cacheKey := "lodging|" + strings.ToLower(strings.TrimSpace(query))
	return gps.textSearch(ctx, cacheKey, query, func(params url.Values) {
		params.Add("type", "lodging")
	})
}

// textSearch is the shared Text Search body behind SearchPlaces and
// SearchPlacesNearby: cache check, request, decode. extraParams (optional)
// appends variant-specific query parameters.
func (gps *GooglePlacesService) textSearch(ctx context.Context, cacheKey, query string, extraParams func(url.Values)) ([]PlaceSearchResult, error) {
	if gps.APIKey == "" {
		return nil, fmt.Errorf("Google Places API key not configured")
	}

	if cached, ok := gps.searchCache.get(cacheKey); ok {
		gps.searchCalls.cacheHits.Add(1)
		return cached, nil
	}

	// Use Text Search API
	params := url.Values{}
	params.Add("query", query)
	params.Add("key", gps.APIKey)
	// Ask the provider for the traveler's language so place names and addresses
	// come back localized (specs/i18n-spanish). Falls back to "en" outside a
	// request, which is what background callers want anyway.
	params.Add("language", requestLocale(ctx))
	if extraParams != nil {
		extraParams(params)
	}

	gps.searchCalls.upstream.Add(1)
	resp, err := gps.doGet(ctx, placesTextSearchURL+"?"+params.Encode())
	if err != nil {
		return nil, fmt.Errorf("failed to search places: %w", redactTransportError(err))
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	var result struct {
		Results []struct {
			PlaceID          string `json:"place_id"`
			Name             string `json:"name"`
			FormattedAddress string `json:"formatted_address"`
			Geometry         struct {
				Location struct {
					Lat float64 `json:"lat"`
					Lng float64 `json:"lng"`
				} `json:"location"`
			} `json:"geometry"`
			Types            []string `json:"types"`
			Rating           *float64 `json:"rating"`
			PriceLevel       *int     `json:"price_level"`
			UserRatingsTotal *int     `json:"user_ratings_total"`
			Photos           []struct {
				PhotoReference   string   `json:"photo_reference"`
				HTMLAttributions []string `json:"html_attributions"`
			} `json:"photos"`
		} `json:"results"`
		Status string `json:"status"`
	}

	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}

	if result.Status != "OK" {
		return nil, fmt.Errorf("Google Places API error: %s", result.Status)
	}

	places := make([]PlaceSearchResult, len(result.Results))
	for i, place := range result.Results {
		places[i] = PlaceSearchResult{
			PlaceID:          place.PlaceID,
			Name:             place.Name,
			Address:          place.FormattedAddress,
			Latitude:         place.Geometry.Location.Lat,
			Longitude:        place.Geometry.Location.Lng,
			Types:            place.Types,
			Rating:           place.Rating,
			PriceLevel:       place.PriceLevel,
			UserRatingsTotal: place.UserRatingsTotal,
		}
		if len(place.Photos) > 0 {
			places[i].PhotoRef = place.Photos[0].PhotoReference
			if len(place.Photos[0].HTMLAttributions) > 0 {
				places[i].PhotoAttribution = stripHTMLTags(place.Photos[0].HTMLAttributions[0])
			}
		}
	}

	gps.searchCache.set(cacheKey, places)
	return places, nil
}

// GetPlaceAutocomplete gets autocomplete suggestions for a query
func (gps *GooglePlacesService) GetPlaceAutocomplete(ctx context.Context, input string) ([]PlaceAutocompleteResult, error) {
	if gps.APIKey == "" {
		return nil, fmt.Errorf("Google Places API key not configured")
	}

	cacheKey := strings.ToLower(strings.TrimSpace(input))
	if cached, ok := gps.autocompleteCache.get(cacheKey); ok {
		gps.autocompleteCalls.cacheHits.Add(1)
		return cached, nil
	}

	params := url.Values{}
	params.Add("input", input)
	params.Add("key", gps.APIKey)
	// Ask the provider for the traveler's language so place names and addresses
	// come back localized (specs/i18n-spanish). Falls back to "en" outside a
	// request, which is what background callers want anyway.
	params.Add("language", requestLocale(ctx))

	gps.autocompleteCalls.upstream.Add(1)
	resp, err := gps.doGet(ctx, placesAutocompleteURL+"?"+params.Encode())
	if err != nil {
		return nil, fmt.Errorf("failed to get autocomplete: %w", redactTransportError(err))
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	var result struct {
		Predictions []struct {
			PlaceID     string   `json:"place_id"`
			Description string   `json:"description"`
			Types       []string `json:"types"`
		} `json:"predictions"`
		Status string `json:"status"`
	}

	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}

	if result.Status != "OK" {
		return nil, fmt.Errorf("Google Places API error: %s", result.Status)
	}

	suggestions := make([]PlaceAutocompleteResult, len(result.Predictions))
	for i, pred := range result.Predictions {
		suggestions[i] = PlaceAutocompleteResult{
			PlaceID:     pred.PlaceID,
			Description: pred.Description,
			Types:       pred.Types,
		}
	}

	gps.autocompleteCache.set(cacheKey, suggestions)
	return suggestions, nil
}

// GetPlaceDetails gets detailed information about a place by Place ID
func (gps *GooglePlacesService) GetPlaceDetails(ctx context.Context, placeID string) (*PlaceDetailsResult, error) {
	if gps.APIKey == "" {
		return nil, fmt.Errorf("Google Places API key not configured")
	}

	if cached, ok := gps.detailsCache.get(placeID); ok {
		gps.detailsCalls.cacheHits.Add(1)
		return cached, nil
	}

	params := url.Values{}
	params.Add("place_id", placeID)
	params.Add("fields", "place_id,name,formatted_address,geometry,types,rating,price_level,opening_hours,website,formatted_phone_number")
	params.Add("key", gps.APIKey)
	// Ask the provider for the traveler's language so place names and addresses
	// come back localized (specs/i18n-spanish). Falls back to "en" outside a
	// request, which is what background callers want anyway.
	params.Add("language", requestLocale(ctx))

	gps.detailsCalls.upstream.Add(1)
	resp, err := gps.doGet(ctx, placesDetailsURL+"?"+params.Encode())
	if err != nil {
		return nil, fmt.Errorf("failed to get place details: %w", redactTransportError(err))
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	var result struct {
		Result struct {
			PlaceID          string `json:"place_id"`
			Name             string `json:"name"`
			FormattedAddress string `json:"formatted_address"`
			Geometry         struct {
				Location struct {
					Lat float64 `json:"lat"`
					Lng float64 `json:"lng"`
				} `json:"location"`
			} `json:"geometry"`
			Types                []string            `json:"types"`
			Rating               *float64            `json:"rating"`
			PriceLevel           *int                `json:"price_level"`
			OpeningHours         *GoogleOpeningHours `json:"opening_hours"`
			Website              *string             `json:"website"`
			FormattedPhoneNumber *string             `json:"formatted_phone_number"`
		} `json:"result"`
		Status string `json:"status"`
	}

	if err := json.Unmarshal(body, &result); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}

	if result.Status != "OK" {
		return nil, fmt.Errorf("Google Places API error: %s", result.Status)
	}

	place := &PlaceDetailsResult{
		PlaceID:      result.Result.PlaceID,
		Name:         result.Result.Name,
		Address:      result.Result.FormattedAddress,
		Latitude:     result.Result.Geometry.Location.Lat,
		Longitude:    result.Result.Geometry.Location.Lng,
		Types:        result.Result.Types,
		Rating:       result.Result.Rating,
		PriceLevel:   result.Result.PriceLevel,
		OpeningHours: result.Result.OpeningHours,
		Website:      result.Result.Website,
		PhoneNumber:  result.Result.FormattedPhoneNumber,
	}

	gps.detailsCache.set(placeID, place)
	return place, nil
}

// errPhotoNotFound marks a photo_reference Google refused to resolve (invalid,
// expired, or denied). The handler maps it to 404 — to the client it just
// means "no image", indistinguishable from the known-ref gate's 404.
var errPhotoNotFound = errors.New("photo not found upstream")

// allowPhotoRef marks a photo_reference as servable by /places/photo for the
// gate TTL. Called at the two points a ref is handed to a client: SSE place
// cards and local-rec venue enrichment.
func (gps *GooglePlacesService) allowPhotoRef(ref string) {
	if ref != "" {
		gps.knownPhotoRefs.set(ref, struct{}{})
	}
}

// photoRefAllowed reports whether /places/photo may serve this ref.
func (gps *GooglePlacesService) photoRefAllowed(ref string) bool {
	_, ok := gps.knownPhotoRefs.get(ref)
	return ok
}

// GetPlacePhotoRef resolves place_id → (photoRef, attribution) via a legacy
// Place Details call restricted to fields=photo — Basic Data, the cheapest
// details SKU. Deliberately separate from GetPlaceDetails: widening that
// call's field mask would change its billing class, and its cache is shared
// with other callers. No language param — photos aren't localized, so the
// cache stays locale-free. Empty ref + nil error means the venue has no
// photo; that negative result is cached so photo-less venues bill once per
// TTL, not once per chat turn.
func (gps *GooglePlacesService) GetPlacePhotoRef(ctx context.Context, placeID string) (string, string, error) {
	if gps.APIKey == "" {
		return "", "", fmt.Errorf("Google Places API key not configured")
	}

	if cached, ok := gps.photoRefCache.get(placeID); ok {
		gps.photoLookupCalls.cacheHits.Add(1)
		// Re-arm the serving gate on every hand-out, not just the original
		// lookup: the gate cache can evict entries independently (capacity),
		// and a ref we're about to emit must stay servable.
		gps.allowPhotoRef(cached.Ref)
		return cached.Ref, cached.Attribution, nil
	}

	params := url.Values{}
	params.Add("place_id", placeID)
	params.Add("fields", "photo")
	params.Add("key", gps.APIKey)

	gps.photoLookupCalls.upstream.Add(1)
	resp, err := gps.doGet(ctx, placesDetailsURL+"?"+params.Encode())
	if err != nil {
		return "", "", fmt.Errorf("failed to get place photo: %w", redactTransportError(err))
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", "", fmt.Errorf("failed to read response: %w", err)
	}

	var result struct {
		Result struct {
			Photos []struct {
				PhotoReference   string   `json:"photo_reference"`
				HTMLAttributions []string `json:"html_attributions"`
			} `json:"photos"`
		} `json:"result"`
		Status string `json:"status"`
	}

	if err := json.Unmarshal(body, &result); err != nil {
		return "", "", fmt.Errorf("failed to parse response: %w", err)
	}

	switch result.Status {
	case "OK":
		// fall through to the photo extraction below
	case "NOT_FOUND", "ZERO_RESULTS", "INVALID_REQUEST":
		// Deterministic dead ends (retired/invalid place_id): cache the empty
		// result like a photo-less venue, or every chat turn re-bills the same
		// doomed Details call. Transient statuses (OVER_QUERY_LIMIT etc.) stay
		// uncached so they retry.
		gps.photoRefCache.set(placeID, placePhotoRef{})
		return "", "", nil
	default:
		return "", "", fmt.Errorf("Google Places API error: %s", result.Status)
	}

	var entry placePhotoRef
	if len(result.Result.Photos) > 0 {
		entry.Ref = result.Result.Photos[0].PhotoReference
		if len(result.Result.Photos[0].HTMLAttributions) > 0 {
			entry.Attribution = stripHTMLTags(result.Result.Photos[0].HTMLAttributions[0])
		}
	}
	gps.photoRefCache.set(placeID, entry)
	gps.allowPhotoRef(entry.Ref)
	return entry.Ref, entry.Attribution, nil
}

// ResolvePhotoURL exchanges a photo_reference for the googleusercontent image
// URL by capturing the Place Photo API's 302 Location — image bytes never
// transit this server. maxWidth must already be clamped by the caller. Two
// simultaneous resolutions of the same uncached ref can double-bill one photo
// call; not worth singleflight at this traffic.
func (gps *GooglePlacesService) ResolvePhotoURL(ctx context.Context, photoRef string, maxWidth int) (string, error) {
	if gps.APIKey == "" {
		return "", fmt.Errorf("Google Places API key not configured")
	}

	cacheKey := photoRef + "|" + strconv.Itoa(maxWidth)
	if cached, ok := gps.photoURLCache.get(cacheKey); ok {
		gps.photoCalls.cacheHits.Add(1)
		return cached, nil
	}

	params := url.Values{}
	params.Add("maxwidth", strconv.Itoa(maxWidth))
	params.Add("photo_reference", photoRef)
	params.Add("key", gps.APIKey)

	gps.photoCalls.upstream.Add(1)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, placesPhotoURL+"?"+params.Encode(), nil)
	if err != nil {
		return "", err
	}
	resp, err := gps.PhotoClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to resolve photo: %w", redactTransportError(err))
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)

	switch {
	case resp.StatusCode >= 300 && resp.StatusCode < 400:
		loc := resp.Header.Get("Location")
		if loc == "" {
			return "", fmt.Errorf("photo redirect missing Location")
		}
		gps.photoURLCache.set(cacheKey, loc)
		return loc, nil
	case resp.StatusCode == http.StatusBadRequest,
		resp.StatusCode == http.StatusForbidden,
		resp.StatusCode == http.StatusNotFound:
		return "", errPhotoNotFound
	default:
		return "", fmt.Errorf("unexpected photo response status %d", resp.StatusCode)
	}
}

// stripHTMLTags reduces Google's html_attributions entries
// (`<a href="...">Photographer</a>`) to their text content. Dependency-free
// single pass; not a general HTML sanitizer — Google's attribution strings
// are simple anchor tags.
func stripHTMLTags(s string) string {
	var b strings.Builder
	inTag := false
	for _, r := range s {
		switch {
		case r == '<':
			inTag = true
		case r == '>':
			inTag = false
		case !inTag:
			b.WriteRune(r)
		}
	}
	return strings.TrimSpace(b.String())
}

// ConvertGoogleHoursToOperatingHours converts Google's opening hours to our format
func ConvertGoogleHoursToOperatingHours(googleHours *GoogleOpeningHours) *OperatingHours {
	if googleHours == nil || len(googleHours.WeekdayText) == 0 {
		return nil
	}

	hours := &OperatingHours{}

	// Google returns weekday_text as ["Monday: 9:00 AM – 5:00 PM", ...]
	for _, dayText := range googleHours.WeekdayText {
		parts := strings.SplitN(dayText, ": ", 2)
		if len(parts) != 2 {
			continue
		}

		day := strings.ToLower(parts[0])
		timeRange := parts[1]

		// Convert "9:00 AM – 5:00 PM" to "09:00-17:00"
		hoursStr := convertGoogleTimeRange(timeRange)

		switch day {
		case "monday":
			hours.Monday = hoursStr
		case "tuesday":
			hours.Tuesday = hoursStr
		case "wednesday":
			hours.Wednesday = hoursStr
		case "thursday":
			hours.Thursday = hoursStr
		case "friday":
			hours.Friday = hoursStr
		case "saturday":
			hours.Saturday = hoursStr
		case "sunday":
			hours.Sunday = hoursStr
		}
	}

	return hours
}

// convertGoogleTimeRange converts "9:00 AM – 5:00 PM" to "09:00-17:00"
func convertGoogleTimeRange(timeRange string) string {
	if strings.Contains(strings.ToLower(timeRange), "closed") {
		return "closed"
	}

	// Simple conversion - this could be more robust
	timeRange = strings.ReplaceAll(timeRange, "–", "-")
	timeRange = strings.ReplaceAll(timeRange, " AM", "")
	timeRange = strings.ReplaceAll(timeRange, " PM", "")

	// This is a simplified conversion - for production, you'd want more robust time parsing
	return timeRange
}

// MapGoogleTypeToCategory maps Google place types to our categories
func MapGoogleTypeToCategory(types []string) string {
	if len(types) == 0 {
		return ""
	}

	// Priority mapping - check most specific types first
	typeMap := map[string]string{
		"restaurant":         "restaurant",
		"food":               "restaurant",
		"meal_takeaway":      "restaurant",
		"cafe":               "coffee_shop",
		"coffee_shop":        "coffee_shop",
		"museum":             "museum",
		"tourist_attraction": "attraction",
		"amusement_park":     "attraction",
		"zoo":                "attraction",
		"park":               "park",
		"shopping_mall":      "shopping",
		"store":              "shopping",
		"hospital":           "medical",
		"pharmacy":           "medical",
		"gas_station":        "gas_station",
		"lodging":            "hotel",
		"movie_theater":      "entertainment",
		"night_club":         "entertainment",
		"gym":                "fitness",
		"church":             "religious",
		"school":             "education",
		"university":         "education",
	}

	for _, gType := range types {
		if category, exists := typeMap[gType]; exists {
			return category
		}
	}

	// Default to the first type if no mapping found
	return types[0]
}
