package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/getsentry/sentry-go"
	"github.com/gorilla/mux"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Response represents a standard API response
type Response struct {
	Message string `json:"message"`
	Status  string `json:"status"`
}

// HealthResponse represents a health check response
type HealthResponse struct {
	Status    string    `json:"status"`
	Timestamp time.Time `json:"timestamp"`
	Service   string    `json:"service"`
	Database  string    `json:"database"`
	// Release is the git SHA this build was made from (SENTRY_RELEASE,
	// baked into the image by CI) — lets "what's live?" be one curl.
	Release string `json:"release,omitempty"`
}

// corsMiddleware adds CORS headers for origins listed in ALLOWED_ORIGINS
// (comma-separated). The production path is same-origin through the nginx
// gateway, where no CORS headers are needed at all — so an empty/unset
// ALLOWED_ORIGINS emits none. Local `make flutter-run` development (Flutter on
// its own port hitting :8080 directly) needs the localhost origins listed.
func corsMiddleware(next http.Handler) http.Handler {
	allowed := map[string]bool{}
	for _, o := range strings.Split(os.Getenv("ALLOWED_ORIGINS"), ",") {
		if o = strings.TrimSpace(o); o != "" {
			allowed[o] = true
		}
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if allowed[origin] {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")
			// Mcp-* headers are what browser-based MCP clients (the MCP
			// Inspector) send; without them /mcp preflight fails there.
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, Accept, Mcp-Session-Id, Mcp-Protocol-Version")
			w.Header().Set("Access-Control-Expose-Headers", "Mcp-Session-Id, WWW-Authenticate")
			w.Header().Add("Vary", "Origin")
		}

		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next.ServeHTTP(w, r)
	})
}

// helloHandler handles the hello world endpoint
func helloHandler(w http.ResponseWriter, r *http.Request) {
	response := Response{
		Message: "Hello, World! Welcome to the Travel Route Planner API!",
		Status:  "success",
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(response)
}

// healthHandler handles health check endpoint
func healthHandler(w http.ResponseWriter, r *http.Request) {
	status := "healthy"
	database := "ok"
	httpStatus := http.StatusOK

	if !pingDB(r.Context()) {
		status = "degraded"
		httpStatus = http.StatusServiceUnavailable
		switch {
		case dbPool == nil && !dbConfigured:
			database = "not configured"
		default:
			database = "unreachable"
		}
	}

	response := HealthResponse{
		Status:    status,
		Timestamp: time.Now(),
		Service:   "travel-route-planner-api",
		Database:  database,
		Release:   os.Getenv("SENTRY_RELEASE"),
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(httpStatus)
	json.NewEncoder(w).Encode(response)
}

// optimizeRouteHandler handles route optimization requests
func optimizeRouteHandler(w http.ResponseWriter, r *http.Request) {
	var request RouteRequest

	// Parse JSON request body
	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		// Parse detail (which can echo raw request bytes) goes to the log only.
		ctxLog(r.Context()).Error("invalid JSON request body", "error", err)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(Response{
			Message: "Invalid JSON in request body",
			Status:  "error",
		})
		return
	}

	// Validate input
	if len(request.Locations) == 0 {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(Response{
			Message: "At least one location is required",
			Status:  "error",
		})
		return
	}

	if len(request.Locations) > 50 {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(Response{
			Message: "Maximum 50 locations supported",
			Status:  "error",
		})
		return
	}

	// Validate location data
	for i, location := range request.Locations {
		if location.ID == "" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(Response{
				Message: fmt.Sprintf("Location %d missing required 'id' field", i),
				Status:  "error",
			})
			return
		}
		// Only validate coordinates if they are provided (not using place name resolution)
		if location.Latitude != nil && (*location.Latitude < -90 || *location.Latitude > 90) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(Response{
				Message: fmt.Sprintf("Location %d has invalid latitude: %f", i, *location.Latitude),
				Status:  "error",
			})
			return
		}
		if location.Longitude != nil && (*location.Longitude < -180 || *location.Longitude > 180) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(Response{
				Message: fmt.Sprintf("Location %d has invalid longitude: %f", i, *location.Longitude),
				Status:  "error",
			})
			return
		}
	}

	// Validate start index if provided
	if request.StartIndex != nil {
		if *request.StartIndex < 0 || *request.StartIndex >= len(request.Locations) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			json.NewEncoder(w).Encode(Response{
				Message: fmt.Sprintf("Invalid start_index: %d. Must be between 0 and %d", *request.StartIndex, len(request.Locations)-1),
				Status:  "error",
			})
			return
		}
	}

	// Create optimizer and process request
	optimizer := NewRouteOptimizer(request.Locations)
	result := optimizer.OptimizeRoute(r.Context(), request)

	// Return result
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(result)
}

// placesSearchHandler handles place search requests
func placesSearchHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	query := r.URL.Query().Get("q")
	if query == "" {
		http.Error(w, "Missing query parameter 'q'", http.StatusBadRequest)
		return
	}

	results, err := placesService.SearchPlaces(r.Context(), query)
	if err != nil {
		// Detail goes to the server log only: provider/internal error strings
		// must never reach an unauthenticated caller.
		ctxLog(r.Context()).Error("places search failed", "error", err)
		http.Error(w, "Failed to search places", http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"results": results,
		"status":  "success",
	})
}

// placesAutocompleteHandler handles place autocomplete requests
func placesAutocompleteHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	input := r.URL.Query().Get("input")
	if input == "" {
		http.Error(w, "Missing query parameter 'input'", http.StatusBadRequest)
		return
	}

	results, err := placesService.GetPlaceAutocomplete(r.Context(), input)
	if err != nil {
		ctxLog(r.Context()).Error("places autocomplete failed", "error", err)
		http.Error(w, "Failed to get autocomplete", http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"predictions": results,
		"status":      "success",
	})
}

// placesDetailsHandler handles place details requests
func placesDetailsHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	placeID := r.URL.Query().Get("place_id")
	if placeID == "" {
		http.Error(w, "Missing query parameter 'place_id'", http.StatusBadRequest)
		return
	}

	result, err := placesService.GetPlaceDetails(r.Context(), placeID)
	if err != nil {
		ctxLog(r.Context()).Error("place details failed", "error", err)
		http.Error(w, "Failed to get place details", http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"result": result,
		"status": "success",
	})
}

// FlightSearchResponse is the ranked result of a flight search.
type FlightSearchResponse struct {
	Offers      []FlightOffer `json:"offers"`
	BestOfferID string        `json:"best_offer_id,omitempty"`
	OptimizeFor string        `json:"optimize_for"`
	Baggage     string        `json:"baggage"`
	Count       int           `json:"count"`
	Status      string        `json:"status"`
}

// duffelService is a process-wide singleton reused across requests (the HTTP
// client and config are shared; auth is a static token).
var duffelService = NewDuffelService()

// airportsSearchHandler resolves airports/cities for autocomplete. It supports
// two modes: free-text (?q=) and geographic (?lat=&lng=, nearest-first) — the
// latter maps an itinerary coordinate to a bookable airport when the place name
// has no IATA match.
func airportsSearchHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	q := r.URL.Query()
	latStr, lngStr := q.Get("lat"), q.Get("lng")

	var results []Airport
	var err error
	switch {
	case latStr != "" && lngStr != "":
		lat, latErr := strconv.ParseFloat(latStr, 64)
		lng, lngErr := strconv.ParseFloat(lngStr, 64)
		if latErr != nil || lngErr != nil {
			http.Error(w, "Invalid 'lat'/'lng' parameters", http.StatusBadRequest)
			return
		}
		results, err = duffelService.NearbyAirports(r.Context(), lat, lng)
	case q.Get("q") != "":
		results, err = duffelService.SearchAirports(r.Context(), q.Get("q"))
	default:
		http.Error(w, "Missing query parameter: provide 'q' or 'lat'+'lng'", http.StatusBadRequest)
		return
	}
	if err != nil {
		// Duffel's key travels in a header (no URL leak), but its error
		// strings can echo upstream response bodies — same policy: log the
		// detail, answer generically.
		ctxLog(r.Context()).Error("airport search failed", "error", err)
		http.Error(w, "Failed to search airports", http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
		"results": results,
		"status":  "success",
	})
}

// flightsSearchHandler searches for flights and returns them ranked by the
// requested optimization preset (cost | time | balanced).
func flightsSearchHandler(w http.ResponseWriter, r *http.Request) {
	var request FlightSearchRequest

	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		// Parse detail (which can echo raw request bytes) goes to the log only.
		ctxLog(r.Context()).Error("invalid JSON request body", "error", err)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(Response{
			Message: "Invalid JSON in request body",
			Status:  "error",
		})
		return
	}

	// Validate input
	writeErr := func(msg string) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadRequest)
		json.NewEncoder(w).Encode(Response{Message: msg, Status: "error"})
	}
	if strings.TrimSpace(request.Origin) == "" {
		writeErr("origin (IATA code) is required")
		return
	}
	if strings.TrimSpace(request.Destination) == "" {
		writeErr("destination (IATA code) is required")
		return
	}
	if strings.TrimSpace(request.DepartDate) == "" {
		writeErr("depart_date (YYYY-MM-DD) is required")
		return
	}
	if request.Adults == 0 {
		request.Adults = 1
	}
	if request.Adults < 1 || request.Adults > 9 {
		writeErr("adults must be between 1 and 9")
		return
	}

	validOptimizations := map[string]bool{"cost": true, "time": true, "balanced": true, "": true}
	if !validOptimizations[strings.ToLower(request.OptimizeFor)] {
		writeErr("optimize_for must be one of: 'cost', 'time', 'balanced'")
		return
	}

	if cc := strings.ToLower(strings.TrimSpace(request.CabinClass)); cc != "" && !allowedCabinClasses[cc] {
		writeErr("cabin_class must be one of: 'economy', 'premium_economy', 'business', 'first'")
		return
	}
	if !allowedBaggageTiers[normalizeBaggage(request.Baggage)] {
		writeErr("baggage must be one of: 'personal_item', 'carry_on', 'checked'")
		return
	}
	if len(request.ChildAges) > 8 {
		writeErr("at most 8 children per search")
		return
	}
	for _, age := range request.ChildAges {
		if age < 0 || age > 17 {
			writeErr("child_ages entries must be between 0 and 17")
			return
		}
	}

	ranked, err := searchFlightsWithBaggage(r.Context(), duffelService, request)
	if err != nil {
		ctxLog(r.Context()).Error("flight search failed", "error", err)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		json.NewEncoder(w).Encode(Response{
			Message: "Failed to search flights",
			Status:  "error",
		})
		return
	}

	// Attach a per-airline booking link to each offer (airline site when known,
	// else airline-filtered Google Flights).
	attachBookingURLs(ranked, request)

	bestID := ""
	if len(ranked) > 0 {
		bestID = ranked[0].ID
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(FlightSearchResponse{
		Offers:      ranked,
		BestOfferID: bestID,
		OptimizeFor: normalizeOptimizeFor(request.OptimizeFor),
		Baggage:     normalizeBaggage(request.Baggage),
		Count:       len(ranked),
		Status:      "success",
	})
}

// sentryEnabled records whether sentry.Init succeeded. Every Sentry call site
// outside sentry_slog.go is guarded on it, so with SENTRY_DSN unset the
// binary takes the exact same code paths as before Sentry existed. (sentry-go
// is also internally safe uninitialized — Hub.Recover/Flush/CaptureEvent
// no-op when no client is bound — but the guard keeps the hot paths free of
// even those calls.)
var sentryEnabled bool

// initSentry configures Sentry error alerting from the environment:
//
//	SENTRY_DSN      — enables Sentry when set; unset => fully inert
//	GO_ENV          — Sentry environment tag (default "production")
//	SENTRY_RELEASE  — release tag (CI sets this to the git SHA; default empty)
//
// Following the repo convention, a bad DSN degrades to inert with a warning
// rather than failing startup. Returns whether Sentry is enabled.
func initSentry() bool {
	dsn := os.Getenv("SENTRY_DSN")
	if dsn == "" {
		slog.Info("sentry inert: SENTRY_DSN not set")
		return false
	}
	environment := os.Getenv("GO_ENV")
	if environment == "" {
		environment = "production"
	}
	release := os.Getenv("SENTRY_RELEASE")
	if err := sentry.Init(sentry.ClientOptions{
		Dsn:         dsn,
		Environment: environment,
		Release:     release,
	}); err != nil {
		slog.Warn("sentry inert: init failed", "error", err)
		return false
	}
	sentryEnabled = true
	slog.Info("sentry enabled", "environment", environment, "release", release)
	return true
}

// shouldWarnSigningSecrets reports whether the app is running in production with
// NO stable HMAC signing secret configured. In that state both export tokens and
// unsubscribe tokens fall back to a per-process random key (see export_token.go /
// unsubscribe_token.go), so every restart/deploy silently invalidates all
// outstanding one-click unsubscribe links (which RFC 8058 / CAN-SPAM require to
// stay honorable indefinitely) and 1h export links. Since UNSUBSCRIBE_SIGNING_SECRET
// falls back to EXPORT_SIGNING_SECRET, either one being set clears the warning.
// Pure (no env reads) so it unit-tests cleanly.
func shouldWarnSigningSecrets(goEnv, exportSecret, unsubSecret string) bool {
	return goEnv == "production" &&
		strings.TrimSpace(exportSecret) == "" &&
		strings.TrimSpace(unsubSecret) == ""
}

// warnIfSigningSecretsUnset logs at error level (never fatal — a soft launch
// shouldn't die on this, but error level routes it to Sentry so a misconfigured
// production deploy pages instead of scrolling past) when running in production
// without a stable signing secret. Reads the raw envs directly, which is
// non-invasive: the token files resolve their secret lazily via sync.Once, so
// this re-read does not force or perturb their initialization.
func warnIfSigningSecretsUnset() {
	if shouldWarnSigningSecrets(os.Getenv("GO_ENV"), os.Getenv("EXPORT_SIGNING_SECRET"), os.Getenv("UNSUBSCRIBE_SIGNING_SECRET")) {
		slog.Error("signing secrets unset — outstanding unsubscribe/export links will break on restart; set EXPORT_SIGNING_SECRET (openssl rand -hex 32) in production")
	}
}

func main() {
	// slog is the canonical logger; SetDefault also routes the stdlib log
	// package through the same handler, so existing log.Printf call sites
	// keep working and share the format.
	textHandler := slog.NewTextHandler(os.Stderr, nil)
	slog.SetDefault(slog.New(textHandler))

	// Sentry error alerting is opt-in via SENTRY_DSN (missing config =>
	// degraded mode, never fatal — here "degraded" is simply "inert": no
	// goroutines, no network, no wrapped log handler). When enabled, Error-
	// and-above slog records are teed to Sentry and recoveryMiddleware
	// reports panics.
	if initSentry() {
		slog.SetDefault(slog.New(newSentrySlogHandler(textHandler)))
		// Best-effort flush of buffered events on return from main. Note the
		// server has no graceful-shutdown hook today (startServer ends in
		// log.Fatal, which skips deferred calls), so the flush that matters
		// in practice is the one in recoveryMiddleware; this defer covers a
		// future graceful-shutdown path for free.
		defer sentry.Flush(2 * time.Second)
	}

	ctx := context.Background()
	dbURL := os.Getenv("DATABASE_URL")

	// `migrate` subcommand: apply migrations and exit (used by `make api-migrate`).
	if len(os.Args) > 1 && os.Args[1] == "migrate" {
		if dbURL == "" {
			log.Fatal("DATABASE_URL is required to run migrations")
		}
		if err := runMigrations(dbURL); err != nil {
			log.Fatalf("Migration failed: %v", err)
		}
		log.Println("Migrations applied successfully")
		return
	}

	// Connect to the database. Missing/unreachable DB -> degraded mode (the API
	// still serves stateless endpoints). A migration failure on a reachable DB is
	// a real error -> exit non-zero.
	//
	// The initial connect RETRIES for a bounded window rather than giving up on
	// the first failure: after a host power cycle Docker's restart policy starts
	// this container and Postgres concurrently (depends_on ordering only applies
	// to `compose up`), so the first attempts routinely lose the race. Without
	// the retry the API would sit in degraded mode forever on a box that heals
	// itself seconds later — on the self-hosted Pi that means every power blip
	// silently killed persistence until someone restarted the container.
	switch {
	case dbURL == "":
		log.Println("WARNING: DATABASE_URL not set - starting without a database; persistence features unavailable")
	default:
		dbConfigured = true
		const dbBootRetryWindow = 90 * time.Second
		deadline := time.Now().Add(dbBootRetryWindow)
		var pool *pgxpool.Pool
		var err error
		for {
			pool, err = initDB(ctx, dbURL)
			if err == nil || time.Now().After(deadline) {
				break
			}
			log.Printf("database not ready (%v) - retrying for up to %s", err, time.Until(deadline).Round(time.Second))
			time.Sleep(5 * time.Second)
		}
		if err != nil {
			log.Printf("WARNING: database unreachable (%v) - starting in degraded mode; persistence features unavailable", err)
			break
		}
		if err := runMigrations(dbURL); err != nil {
			pool.Close()
			log.Fatalf("Database migration failed: %v", err)
		}
		dbPool = pool
		defer dbPool.Close()
		log.Println("Connected to database; migrations applied")
	}

	// Loud production warning when no stable signing secret is configured: the
	// token files fall back to a per-process random key, which breaks every
	// outstanding unsubscribe/export link on restart. Non-fatal by design.
	warnIfSigningSecretsUnset()

	// Background price-alert checker (specs/price-alerts); no-ops in
	// degraded mode or without a Duffel token.
	startAlertChecker(ctx)

	// Background re-engagement checkers (Wave 16): trip reminders + weekly
	// planning nudge; no-op in degraded mode.
	startReengagementChecker(ctx)

	// Background health self-check (Observability): alerts on healthy<->degraded
	// transitions (DB reachability + backup freshness); no-op in degraded mode.
	startHealthMonitor(ctx)

	startServer(buildRouter())
}

// buildRouter wires all routes and middleware. It reads only package globals
// (dbPool, service singletons), so main() and the integration tests construct
// identical routers.
func buildRouter() *mux.Router {
	router := mux.NewRouter()

	// mux skips router.Use middleware when the request method matches no
	// route, which is exactly how CORS preflights (OPTIONS) arrive — route
	// them through corsMiddleware so cross-origin dev setups get an answer.
	router.MethodNotAllowedHandler = corsMiddleware(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		w.WriteHeader(http.StatusMethodNotAllowed)
	}))

	// Rate limiting: a general per-IP cap on everything, plus a strict tier
	// on the endpoints that are expensive (AI streaming) or brute-forceable
	// (credentials). Health checks stay exempt for container probes.
	generalLimiter := newIPRateLimiter(60, 30)
	strictLimiter := newIPRateLimiter(5, 3)
	strict := rateLimitMiddleware(strictLimiter)
	// Anonymous analytics gets its own bucket: sharing the strict one would let
	// a visitor's pre-signup pings (landing view + booking clicks) drain the
	// budget that /auth/register and /auth/login depend on, 429-ing the signup
	// at the exact conversion moment the events exist to measure.
	anonEventsLimiter := newIPRateLimiter(10, 5)
	anonEvents := rateLimitMiddleware(anonEventsLimiter)
	router.Use(requestIDMiddleware)
	router.Use(recoveryMiddleware)
	// Global concurrency ceiling (abuse_caps.go): a single Pi instance with
	// WriteTimeout:0 (needed for SSE) has no cap on concurrent in-flight
	// requests, so a burst could swamp it. Shed excess load early — right after
	// recovery/requestID — with a non-blocking 503 + Retry-After (/health is
	// exempt so probes still answer under saturation).
	router.Use(newConcurrencyLimiter(maxInflightRequests()).middleware)
	// metricsMiddleware sits right after recovery so it times the full handler
	// (recovered panics count as the 500 they return) and folds each request
	// into the in-process opsMetrics registry (ops_metrics.go).
	router.Use(metricsMiddleware)
	router.Use(corsMiddleware)
	// Negotiates the response language for every route, including the public
	// token-gated exports that have no session to read a stored locale from
	// (specs/i18n-spanish).
	router.Use(localeMiddleware)
	router.Use(bodyLimitMiddleware)
	router.Use(func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path == "/health" || r.URL.Path == "/api/v1/health" {
				next.ServeHTTP(w, r)
				return
			}
			rateLimitMiddleware(generalLimiter)(next).ServeHTTP(w, r)
		})
	})

	// Define routes
	router.HandleFunc("/", helloHandler).Methods("GET")
	router.HandleFunc("/hello", helloHandler).Methods("GET")
	router.HandleFunc("/health", healthHandler).Methods("GET", "HEAD")

	// MCP connector discovery documents (specs/mcp-connector) — root-level by
	// RFC requirement; every handler 404s until MCP_ENABLED=true.
	router.HandleFunc("/.well-known/oauth-protected-resource", oauthProtectedResourceHandler).Methods("GET")
	router.HandleFunc("/.well-known/oauth-protected-resource/mcp", oauthProtectedResourceHandler).Methods("GET")
	router.HandleFunc("/.well-known/oauth-authorization-server", oauthServerMetadataHandler).Methods("GET")
	router.HandleFunc("/.well-known/openid-configuration", oauthServerMetadataHandler).Methods("GET")

	// The MCP endpoint itself: Streamable HTTP, Bearer-authenticated with the
	// OAuth tokens above. Root-level because connector URLs are configured by
	// hand and /api/v1 would be noise; nginx proxies it like /api/.
	router.Handle("/mcp", newMCPHandler()).Methods("POST", "GET", "DELETE")

	// API versioning
	api := router.PathPrefix("/api/v1").Subrouter()
	api.HandleFunc("/hello", helloHandler).Methods("GET")
	api.HandleFunc("/health", healthHandler).Methods("GET", "HEAD")
	api.HandleFunc("/optimize-route", optimizeRouteHandler).Methods("POST")
	api.HandleFunc("/places/search", placesSearchHandler).Methods("GET")
	api.HandleFunc("/places/autocomplete", placesAutocompleteHandler).Methods("GET")
	api.HandleFunc("/places/details", placesDetailsHandler).Methods("GET")
	// Place-photo redirects fan out ~8 per chat recommendation strip, so they
	// get their own bucket (like /transcribe): sharing strict would starve
	// /plan, and image bursts shouldn't eat the general JSON-API budget.
	// Burst 20 absorbs two full card strips back-to-back.
	photoLimiter := newIPRateLimiter(40, 20)
	photo := rateLimitMiddleware(photoLimiter)
	api.Handle("/places/photo", photo(http.HandlerFunc(placesPhotoHandler))).Methods("GET")
	api.HandleFunc("/flights/search", flightsSearchHandler).Methods("POST")
	api.HandleFunc("/flights/airports", airportsSearchHandler).Methods("GET")
	api.HandleFunc("/events/search", eventsSearchHandler).Methods("GET")
	api.HandleFunc("/weather", weatherSearchHandler).Methods("GET")
	api.HandleFunc("/ferries/search", ferriesSearchHandler).Methods("GET")
	api.HandleFunc("/events/greece-links", greeceEventsLinksHandler).Methods("GET")
	api.Handle("/plan", strict(http.HandlerFunc(planHandler))).Methods("POST")
	// Voice dictation fallback (specs/voice-dictation). Unauthenticated to
	// match /plan, but on its own limiter bucket — sharing strict (5/min)
	// would starve /plan, since each fallback dictation+send costs two tokens.
	transcribeLimiter := newIPRateLimiter(10, 5)
	transcribe := rateLimitMiddleware(transcribeLimiter)
	api.Handle("/transcribe", transcribe(http.HandlerFunc(transcribeHandler))).Methods("POST")
	api.HandleFunc("/transcribe/availability", transcribeAvailabilityHandler).Methods("GET")
	api.Handle("/auth/register", strict(http.HandlerFunc(registerHandler))).Methods("POST")
	api.Handle("/auth/login", strict(http.HandlerFunc(loginHandler))).Methods("POST")
	// Reset/verify are unauthenticated and trigger email sends — strict tier.
	api.Handle("/auth/request-password-reset", strict(http.HandlerFunc(requestPasswordResetHandler))).Methods("POST")
	api.Handle("/auth/reset-password", strict(http.HandlerFunc(resetPasswordHandler))).Methods("POST")
	api.HandleFunc("/auth/verify-email", verifyEmailHandler).Methods("GET", "POST")
	api.Handle("/auth/request-verification", authMiddleware(http.HandlerFunc(requestVerificationHandler))).Methods("POST")
	api.Handle("/auth/logout", authMiddleware(http.HandlerFunc(logoutHandler))).Methods("POST")
	api.Handle("/auth/me", authMiddleware(http.HandlerFunc(meHandler))).Methods("GET")
	api.Handle("/auth/onboarding-complete", authMiddleware(http.HandlerFunc(completeOnboardingHandler))).Methods("POST")
	// Account self-service (specs/user-accounts follow-ups). Credential and
	// destructive routes re-verify the password and sit on the strict tier.
	api.Handle("/auth/account", authMiddleware(http.HandlerFunc(patchAccountHandler))).Methods("PATCH")
	api.Handle("/auth/account", strict(authMiddleware(http.HandlerFunc(deleteAccountHandler)))).Methods("DELETE")
	api.Handle("/auth/change-password", strict(authMiddleware(http.HandlerFunc(changePasswordHandler)))).Methods("POST")
	api.Handle("/auth/logout-all", authMiddleware(http.HandlerFunc(logoutAllHandler))).Methods("POST")
	api.Handle("/auth/email-preferences", authMiddleware(http.HandlerFunc(patchEmailPreferencesHandler))).Methods("PATCH")
	// Public, token-gated one-click unsubscribe — NO authMiddleware: the signed
	// token IS the capability. GET = human clicks the footer link; POST = RFC
	// 8058 List-Unsubscribe-Post one-click flow fired by the mail client.
	api.HandleFunc("/unsubscribe/{token}", unsubscribeHandler).Methods("GET", "POST")
	// Sign in with Google (specs/google-sso). Browser redirect flow + one-time
	// code exchange; unauthenticated, so the credential routes take the strict tier.
	api.HandleFunc("/auth/google/availability", googleAvailabilityHandler).Methods("GET")
	api.Handle("/auth/google", strict(http.HandlerFunc(googleStartHandler))).Methods("GET")
	api.Handle("/auth/google/callback", strict(http.HandlerFunc(googleCallbackHandler))).Methods("GET")
	// The exchange is provider-agnostic; /auth/google/exchange stays as an
	// alias for handoff codes in-flight across a deploy.
	api.Handle("/auth/sso/exchange", strict(http.HandlerFunc(ssoExchangeHandler))).Methods("POST")
	api.Handle("/auth/google/exchange", strict(http.HandlerFunc(ssoExchangeHandler))).Methods("POST")
	// Sign in with Apple (specs/apple-sso). Same flow, three deltas: POST
	// form_post callback, no PKCE, ES256 client-secret JWT.
	api.HandleFunc("/auth/apple/availability", appleAvailabilityHandler).Methods("GET")
	api.Handle("/auth/apple", strict(http.HandlerFunc(appleStartHandler))).Methods("GET")
	api.Handle("/auth/apple/callback", strict(http.HandlerFunc(appleCallbackHandler))).Methods("POST")

	// MCP connector OAuth provider (specs/mcp-connector): ChatGPT/claude.ai
	// register via DCR, the browser consents at the app's /connect/ screen,
	// tokens redeem here. All handlers gate on MCP_ENABLED.
	//
	// Its OWN bucket, not the strict (5/min) tier: linking an account is five
	// calls in a few seconds (register, authorize, context, decision, token),
	// and connector vendors egress from shared IPs — on the strict tier one
	// user's link would rate-limit the next user's, and could starve
	// login/reset for anyone behind the same address. 30/min burst 15 fits
	// several concurrent links while still bounding abuse; every endpoint
	// underneath is independently protected (PKCE, single-use codes, and
	// authMiddleware on the decision step).
	oauthLimiter := newIPRateLimiter(30, 15)
	oauthTier := rateLimitMiddleware(oauthLimiter)
	api.Handle("/oauth/register", oauthTier(http.HandlerFunc(oauthRegisterHandler))).Methods("POST")
	api.Handle("/oauth/authorize", oauthTier(http.HandlerFunc(oauthAuthorizeHandler))).Methods("GET")
	api.Handle("/oauth/authorize/context", oauthTier(http.HandlerFunc(oauthAuthorizeContextHandler))).Methods("POST")
	api.Handle("/oauth/authorize/decision", oauthTier(authMiddleware(http.HandlerFunc(oauthAuthorizeDecisionHandler)))).Methods("POST")
	api.Handle("/oauth/token", oauthTier(http.HandlerFunc(oauthTokenHandler))).Methods("POST")
	api.HandleFunc("/mcp/availability", mcpAvailabilityHandler).Methods("GET")
	// Connected apps: always reachable (even with MCP_ENABLED off) so a user
	// can always see and revoke a connection granted while it was on.
	api.Handle("/oauth/connections", authMiddleware(http.HandlerFunc(listOAuthConnectionsHandler))).Methods("GET")
	api.Handle("/oauth/connections/{id}", authMiddleware(http.HandlerFunc(revokeOAuthConnectionHandler))).Methods("DELETE")
	// admin composes the auth + admin gate; used for curation and version-history routes.
	admin := func(h http.HandlerFunc) http.Handler { return authMiddleware(adminMiddleware(h)) }
	api.Handle("/trips", authMiddleware(http.HandlerFunc(listTripsHandler))).Methods("GET")
	api.Handle("/trips/versions", admin(listTripVersionsHandler)).Methods("GET")
	// Literal routes must precede /trips/{id} or mux binds them as an id.
	// Import runs one Claude call + up to 50 Places lookups per request — same
	// 5/min budget as the strict tier but on its OWN bucket (like /transcribe),
	// so a paste-happy user can't lock their IP out of login/plan and vice
	// versa. A per-user daily cap in the handler bounds account-level spend
	// (specs/import-trip-from-ai-chat).
	importLimiter := newIPRateLimiter(5, 3)
	importTier := rateLimitMiddleware(importLimiter)
	api.Handle("/trips/import", importTier(authMiddleware(http.HandlerFunc(importTripHandler)))).Methods("POST")
	api.Handle("/trips/shared-with-me", authMiddleware(http.HandlerFunc(listSharedWithMeHandler))).Methods("GET")
	// Resumable plan conversations (specs/continue-where-you-left-off).
	api.Handle("/chats", authMiddleware(http.HandlerFunc(listChatSessionsHandler))).Methods("GET")
	api.Handle("/chats/{chatId}", authMiddleware(http.HandlerFunc(getChatSessionHandler))).Methods("GET")
	api.Handle("/chats/{chatId}", authMiddleware(http.HandlerFunc(deleteChatSessionHandler))).Methods("DELETE")
	api.Handle("/trips/{id}", authMiddleware(http.HandlerFunc(getTripHandler))).Methods("GET")
	api.Handle("/trips/{id}", authMiddleware(http.HandlerFunc(patchTripHandler))).Methods("PATCH")
	api.Handle("/trips/{id}", authMiddleware(http.HandlerFunc(deleteTripHandler))).Methods("DELETE")
	api.Handle("/trips/{id}/status", authMiddleware(http.HandlerFunc(tripStatusHandler))).Methods("GET")
	api.Handle("/trips/{id}/refine", strict(authMiddleware(http.HandlerFunc(refineTripHandler)))).Methods("POST")
	api.Handle("/trips/{id}/share", authMiddleware(http.HandlerFunc(createShareHandler))).Methods("POST")
	api.Handle("/trips/{id}/share", authMiddleware(http.HandlerFunc(revokeShareHandler))).Methods("DELETE")
	// Owner-private export: the authed owner/editor mints a short-lived signed
	// token, then the two PUBLIC token-gated GETs below render the full trip.
	api.Handle("/trips/{id}/export-token", authMiddleware(http.HandlerFunc(exportTokenHandler))).Methods("POST")
	// Public, token-gated export routes — NO authMiddleware: the signed export
	// token IS the authorization (a bad/expired token is a clean 404).
	api.HandleFunc("/export/{token}/print.html", printViewHandler).Methods("GET")
	api.HandleFunc("/export/{token}/calendar.ics", calendarHandler).Methods("GET")
	api.HandleFunc("/export/{token}/event/{kind}/{id}.ics", calendarEventHandler).Methods("GET")
	// Public share read sits behind the general per-IP limiter like everything
	// else; it is the one endpoint deliberately open to anonymous strangers.
	api.HandleFunc("/shared/{token}", sharedTripHandler).Methods("GET")
	api.Handle("/shared/{token}/duplicate", authMiddleware(http.HandlerFunc(duplicateSharedTripHandler))).Methods("POST")
	// Join writes membership — strict tier like refine.
	api.Handle("/shared/{token}/join", strict(authMiddleware(http.HandlerFunc(joinSharedTripHandler)))).Methods("POST")
	// Email invites (specs/invite-by-email): create sends mail and accept
	// writes membership — both strict tier; the preview is public like
	// /shared/{token}.
	api.Handle("/trips/{id}/invites", strict(authMiddleware(http.HandlerFunc(createTripInviteHandler)))).Methods("POST")
	api.Handle("/trips/{id}/invites", authMiddleware(http.HandlerFunc(listTripInvitesHandler))).Methods("GET")
	api.Handle("/trips/{id}/invites/{inviteId}", authMiddleware(http.HandlerFunc(revokeTripInviteHandler))).Methods("DELETE")
	api.HandleFunc("/invites/{token}", invitePreviewHandler).Methods("GET")
	api.Handle("/invites/{token}/accept", strict(authMiddleware(http.HandlerFunc(acceptInviteHandler)))).Methods("POST")
	api.Handle("/trips/{id}/collaborators", authMiddleware(http.HandlerFunc(listCollaboratorsHandler))).Methods("GET")
	api.Handle("/trips/{id}/collaborators/{userId}", authMiddleware(http.HandlerFunc(removeCollaboratorHandler))).Methods("DELETE")
	// OG link-preview page for crawlers; deployment nginx rewrites bot
	// requests for /app/share/* here.
	api.HandleFunc("/share-preview/{token}", sharePreviewHandler).Methods("GET")
	api.Handle("/trips/{id}/items", authMiddleware(http.HandlerFunc(addItineraryItemHandler))).Methods("POST")
	api.Handle("/trips/{id}/items/order", authMiddleware(http.HandlerFunc(reorderItineraryItemsHandler))).Methods("PUT")
	api.Handle("/trips/{id}/items/{itemId}", authMiddleware(http.HandlerFunc(patchItineraryItemHandler))).Methods("PATCH")
	api.Handle("/trips/{id}/items/{itemId}", authMiddleware(http.HandlerFunc(deleteItineraryItemHandler))).Methods("DELETE")
	// Client analytics events. Two registrations, matched in order: a request
	// presenting ANY Authorization header takes the authenticated route
	// (token validated + attributed by authMiddleware — an invalid token is a
	// 401, never a silent downgrade to anonymous); a request without
	// credentials falls through to the anonymous route, which accepts only
	// the tiny anonymousClientEventTypes whitelist, always drops trip_id, and
	// sits behind its own rate-limit bucket to bound spam writes (it is an
	// unauthenticated INSERT surface) without draining the strict bucket that
	// the auth endpoints share.
	api.Handle("/events", authMiddleware(http.HandlerFunc(recordClientEventHandler))).
		Methods("POST").HeadersRegexp("Authorization", ".+")
	api.Handle("/events", anonEvents(http.HandlerFunc(recordAnonymousClientEventHandler))).Methods("POST")
	// Price alerts (specs/price-alerts): creation is strict-tier (each alert
	// commits the server to recurring provider searches).
	api.Handle("/alerts", strict(authMiddleware(http.HandlerFunc(createPriceAlertHandler)))).Methods("POST")
	api.Handle("/alerts", authMiddleware(http.HandlerFunc(listPriceAlertsHandler))).Methods("GET")
	// Alert events (specs/price-alerts-v2): the notification-center feed.
	// Registered before /alerts/{id} so "events" is never captured as an id.
	api.Handle("/alerts/events", authMiddleware(http.HandlerFunc(listAlertEventsHandler))).Methods("GET")
	api.Handle("/alerts/events/read", authMiddleware(http.HandlerFunc(markAlertEventsReadHandler))).Methods("POST")
	api.Handle("/alerts/events/unread-count", authMiddleware(http.HandlerFunc(unreadAlertEventsCountHandler))).Methods("GET")
	// Generalized notifications feed (Wave 16): the type-agnostic successor to
	// /alerts/events. The Flutter notification center + badge read these; the
	// price-alert checker writes 'price_drop' rows here.
	api.Handle("/notifications", authMiddleware(http.HandlerFunc(listNotificationsHandler))).Methods("GET")
	api.Handle("/notifications/read", authMiddleware(http.HandlerFunc(markNotificationsReadHandler))).Methods("POST")
	api.Handle("/notifications/unread-count", authMiddleware(http.HandlerFunc(unreadNotificationsCountHandler))).Methods("GET")
	api.Handle("/alerts/{id}", authMiddleware(http.HandlerFunc(patchPriceAlertHandler))).Methods("PATCH")
	api.Handle("/alerts/{id}", authMiddleware(http.HandlerFunc(deletePriceAlertHandler))).Methods("DELETE")
	api.Handle("/preferences", authMiddleware(http.HandlerFunc(getPreferencesHandler))).Methods("GET")
	api.Handle("/preferences", authMiddleware(http.HandlerFunc(putPreferencesHandler))).Methods("PUT")
	api.HandleFunc("/accommodation-links", accommodationLinksHandler).Methods("GET")
	api.Handle("/trips/{id}/accommodations", authMiddleware(http.HandlerFunc(addAccommodationHandler))).Methods("POST")
	api.Handle("/trips/{id}/accommodations/{accId}", authMiddleware(http.HandlerFunc(updateAccommodationHandler))).Methods("PATCH")
	api.Handle("/trips/{id}/accommodations/{accId}", authMiddleware(http.HandlerFunc(deleteAccommodationHandler))).Methods("DELETE")
	api.HandleFunc("/transport-links", transportLinksHandler).Methods("GET")
	api.Handle("/trips/{id}/segments", authMiddleware(http.HandlerFunc(addSegmentHandler))).Methods("POST")
	api.Handle("/trips/{id}/segments/{segmentId}", authMiddleware(http.HandlerFunc(updateSegmentHandler))).Methods("PATCH")
	api.Handle("/trips/{id}/segments/{segmentId}", authMiddleware(http.HandlerFunc(deleteSegmentHandler))).Methods("DELETE")
	api.Handle("/trips/{id}/booking-drafts", authMiddleware(http.HandlerFunc(syncBookingDraftsHandler))).Methods("PUT")
	api.Handle("/trips/{id}/bookings/order", authMiddleware(http.HandlerFunc(reorderBookingsHandler))).Methods("PUT")
	api.Handle("/trips/{id}/booking-todos", authMiddleware(http.HandlerFunc(syncBookingTodosHandler))).Methods("PUT")
	api.Handle("/trips/{id}/booking-todos", authMiddleware(http.HandlerFunc(addBookingTodoHandler))).Methods("POST")
	api.Handle("/trips/{id}/booking-todos/order", authMiddleware(http.HandlerFunc(reorderBookingTodosHandler))).Methods("PUT")
	api.Handle("/trips/{id}/booking-todos/{todoId}", authMiddleware(http.HandlerFunc(patchBookingTodoHandler))).Methods("PATCH")
	api.Handle("/trips/{id}/booking-todos/{todoId}", authMiddleware(http.HandlerFunc(deleteBookingTodoHandler))).Methods("DELETE")
	api.Handle("/trips/{id}/checklist", authMiddleware(http.HandlerFunc(listChecklistHandler))).Methods("GET")
	api.Handle("/trips/{id}/checklist", authMiddleware(http.HandlerFunc(addChecklistItemHandler))).Methods("POST")
	api.Handle("/trips/{id}/checklist/{itemId}", authMiddleware(http.HandlerFunc(patchChecklistItemHandler))).Methods("PATCH")
	api.Handle("/trips/{id}/checklist/{itemId}", authMiddleware(http.HandlerFunc(deleteChecklistItemHandler))).Methods("DELETE")
	api.Handle("/trips/{id}/budget", authMiddleware(http.HandlerFunc(getBudgetHandler))).Methods("GET")
	api.Handle("/trips/{id}/budget", authMiddleware(http.HandlerFunc(putBudgetHandler))).Methods("PUT")
	api.Handle("/trips/{id}/budget/expenses", authMiddleware(http.HandlerFunc(listExpensesHandler))).Methods("GET")
	api.Handle("/trips/{id}/budget/expenses", authMiddleware(http.HandlerFunc(addExpenseHandler))).Methods("POST")
	api.Handle("/trips/{id}/budget/expenses/{expenseId}", authMiddleware(http.HandlerFunc(patchExpenseHandler))).Methods("PATCH")
	api.Handle("/trips/{id}/budget/expenses/{expenseId}", authMiddleware(http.HandlerFunc(deleteExpenseHandler))).Methods("DELETE")
	api.Handle("/trips/{id}/review", authMiddleware(http.HandlerFunc(getTripReviewHandler))).Methods("GET")

	// Local-source content — curation is admin-only (authMiddleware + adminMiddleware).
	api.Handle("/admin/local/sources", admin(listLocalSourcesHandler)).Methods("GET")
	api.Handle("/admin/local/sources", admin(createLocalSourceHandler)).Methods("POST")
	api.Handle("/admin/local/ingest", admin(ingestLocalHandler)).Methods("POST")
	api.Handle("/admin/local/recommendations", admin(listRecommendationsByStatusHandler)).Methods("GET")
	api.Handle("/admin/local/recommendations/{id}", admin(updateRecommendationHandler)).Methods("PATCH")
	api.Handle("/admin/local/recommendations/{id}/publish", admin(publishRecommendationHandler)).Methods("POST")
	api.Handle("/admin/local/coverage", admin(localCoverageHandler)).Methods("GET")
	api.Handle("/admin/metrics", admin(adminMetricsHandler)).Methods("GET")
	// Dashboard extensions (admin_metrics_handler.go): trends, all-time
	// totals, activity tail, per-user aggregates.
	api.Handle("/admin/metrics/timeseries", admin(adminTimeseriesHandler)).Methods("GET")
	api.Handle("/admin/metrics/totals", admin(adminTotalsHandler)).Methods("GET")
	api.Handle("/admin/metrics/activity", admin(adminActivityHandler)).Methods("GET")
	api.Handle("/admin/metrics/users", admin(adminUsersHandler)).Methods("GET")
	// Live in-process request/latency/error + runtime rollup (ops_metrics.go).
	// No dbPool guard — it must render in degraded mode; admin auth only.
	api.Handle("/admin/ops/metrics", admin(opsMetricsHandler)).Methods("GET")

	// Consolidated dependency health: DB + provider config + build + backup
	// freshness (ops_health.go). Also renders in degraded mode; admin auth only.
	api.Handle("/admin/ops/health", admin(opsHealthHandler)).Methods("GET")

	// Public browse endpoints for published local-sourced content.
	api.HandleFunc("/local/recommendations", localRecommendationsHandler).Methods("GET")
	api.HandleFunc("/local/guides", localGuidesHandler).Methods("GET")
	api.HandleFunc("/local/guides/{id}", localGuideDetailHandler).Methods("GET")

	return router
}

// startServer configures and runs the HTTP server; split from main() so the
// boot sequence reads env → DB → buildRouter → serve.
func startServer(router *mux.Router) {
	// Server configuration
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	server := &http.Server{
		Addr:         ":" + port,
		Handler:      router,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 0,
		IdleTimeout:  60 * time.Second,
	}

	log.Printf("Starting Travel Route Planner API server on port %s", port)
	log.Printf("Available endpoints:")
	log.Printf("  GET /                        - Hello World")
	log.Printf("  GET /hello                   - Hello World")
	log.Printf("  GET /health                  - Health Check")
	log.Printf("  GET /api/v1/hello            - Hello World (v1)")
	log.Printf("  GET /api/v1/health           - Health Check (v1)")
	log.Printf("  POST /api/v1/optimize-route     - Route Optimization")
	log.Printf("  GET  /api/v1/places/search      - Search Places")
	log.Printf("  GET  /api/v1/places/autocomplete - Place Autocomplete")
	log.Printf("  GET  /api/v1/places/details     - Place Details")
	log.Printf("  GET  /api/v1/places/photo       - Place Photo (302 redirect)")
	log.Printf("  POST /api/v1/flights/search     - Ranked Flight Search (Duffel)")
	log.Printf("  GET  /api/v1/flights/airports   - Airport/City Autocomplete (Duffel)")
	log.Printf("  POST /api/v1/auth/register      - Register")
	log.Printf("  POST /api/v1/auth/login         - Login")
	log.Printf("  GET  /api/v1/auth/google        - Sign in with Google (redirect flow)")
	log.Printf("  GET  /api/v1/auth/apple         - Sign in with Apple (redirect flow)")
	log.Printf("  POST /api/v1/auth/logout        - Logout (auth)")
	log.Printf("  GET  /api/v1/auth/me            - Current user (auth)")
	log.Printf("  POST /api/v1/auth/onboarding-complete - Mark onboarding done (auth)")
	log.Printf("  GET  /api/v1/trips              - List trips (auth)")
	log.Printf("  GET  /api/v1/chats              - Resumable plan conversations (auth)")
	log.Printf("  GET/DELETE /api/v1/chats/{chatId} - Resume / dismiss a conversation (auth)")
	log.Printf("  GET/PATCH/DELETE /api/v1/trips/{id} - Trip detail (auth)")
	log.Printf("  GET/PUT /api/v1/preferences      - Traveler preferences (auth)")
	log.Printf("  GET  /api/v1/accommodation-links - Airbnb/Booking browse links")
	log.Printf("  POST/DELETE /api/v1/trips/{id}/accommodations - Trip stays (auth)")
	log.Printf("  POST /api/v1/trips/{id}/items   - Add itinerary item (auth)")
	log.Printf("  GET  /api/v1/transport-links     - Google Flights/Kayak/Rome2Rio browse links")
	log.Printf("  POST/DELETE /api/v1/trips/{id}/segments - Trip travel segments (auth)")

	if err := server.ListenAndServe(); err != nil {
		log.Fatal("Server failed to start:", err)
	}
}
