package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"strings"
	"time"
)

// trip_import_handler.go: POST /api/v1/trips/import — paste an external-AI
// conversation (ChatGPT, Claude, …), get a persisted trip back. Auth required
// (trips are per-user); strict rate tier (each request is one Claude call plus
// up to importMaxPlaceLookups Places lookups); its own 2 MiB body lane in
// bodyLimitMiddleware (a long transcript blows the 256 KiB default).

type importTripRequest struct {
	Text string `json:"text"`
	// Which AI the text came from — analytics only, never trusted for logic.
	Source string `json:"source"`
}

type importTripResponse struct {
	TripID    string   `json:"trip_id"`
	Title     string   `json:"title"`
	ItemCount int      `json:"item_count"`
	Warnings  []string `json:"warnings"`
}

var allowedImportSources = map[string]bool{
	"chatgpt": true, "claude": true, "gemini": true, "other": true,
}

func importTripHandler(w http.ResponseWriter, r *http.Request) {
	user, ok := userFromContext(r.Context())
	if !ok {
		writeJSONError(w, http.StatusUnauthorized, "authentication required")
		return
	}

	var req importTripRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	text := strings.TrimSpace(req.Text)
	if text == "" {
		writeJSONError(w, http.StatusBadRequest, "text is required")
		return
	}
	source := strings.ToLower(strings.TrimSpace(req.Source))
	if !allowedImportSources[source] {
		source = "other"
	}

	apiKey := os.Getenv("ANTHROPIC_API_KEY")
	if apiKey == "" {
		writeJSONError(w, http.StatusServiceUnavailable, "ANTHROPIC_API_KEY not configured")
		return
	}

	locale := requestLocale(r.Context())

	// Per-user daily spend ceiling (abuse_caps.go) — checked after the free
	// validations so bad requests don't consume the day's quota.
	if !importAllowed(user.ID.String(), time.Now()) {
		writeJSONError(w, http.StatusTooManyRequests, tr(locale, "import.error.daily_limit"))
		return
	}

	res, err := importTripCore(r.Context(), newAnthropicClient(apiKey), user.ID, text, source)
	if err != nil {
		var phase *importPhaseError
		switch {
		case errors.Is(err, errImportNoTrip):
			writeJSONError(w, http.StatusUnprocessableEntity, tr(locale, "import.error.no_trip"))
		case errors.Is(err, errImportNothingLocated):
			writeJSONError(w, http.StatusUnprocessableEntity, tr(locale, "import.error.nothing_located"))
		case errors.Is(err, errImportPlacesUnavailable):
			// Places outage/quota, not a bad paste — retryable.
			writeJSONError(w, http.StatusServiceUnavailable, tr(locale, "import.error.places_unavailable"))
		case errors.Is(err, errImportTripLimit),
			strings.Contains(err.Error(), "trip limit reached"): // persistTrip's transactional re-check (race path)
			writeJSONError(w, http.StatusUnprocessableEntity, tr(locale, "import.error.trip_limit"))
		case errors.As(err, &phase) && phase.phase == "extract":
			// Provider/internal detail stays in the server log (tees to
			// Sentry); the client gets a generic message.
			ctxLog(r.Context()).Error("trip import: extraction failed", "error", err)
			writeJSONError(w, http.StatusBadGateway, "extraction failed")
		default:
			ctxLog(r.Context()).Error("trip import: persist failed", "error", err)
			writeJSONError(w, http.StatusInternalServerError, "could not save trip")
		}
		return
	}

	writeJSON(w, http.StatusCreated, importTripResponse{
		TripID:    res.TripID,
		Title:     res.Title,
		ItemCount: res.ItemCount,
		Warnings:  res.Warnings,
	})
}
