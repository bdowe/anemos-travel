package main

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// hotelsSearchHandler answers GET /api/v1/hotels/search (specs/hotel-search).
// Shares one implementation with the /plan agent's search_hotels tool — the
// tool dispatcher and this handler both call searchHotels, so a future trip-
// page lodging surface cannot grow a second, subtly different lookup.
//
// Never 5xxs for a provider problem: searchHotels degrades to the no-rates
// tier instead, and the response says so via rates_live/rates_note.
func hotelsSearchHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	q := r.URL.Query()
	city := strings.TrimSpace(q.Get("city"))
	if city == "" {
		http.Error(w, "Missing required query parameter 'city'", http.StatusBadRequest)
		return
	}

	checkIn := strings.TrimSpace(q.Get("check_in"))
	checkOut := strings.TrimSpace(q.Get("check_out"))
	// Paired or absent — never one. Half a stay window cannot be interpreted,
	// and inventing the other end would price nights nobody asked about.
	if (checkIn == "") != (checkOut == "") {
		http.Error(w, "'check_in' and 'check_out' must be supplied together", http.StatusBadRequest)
		return
	}
	if checkIn != "" {
		in, err := time.Parse("2006-01-02", checkIn)
		if err != nil {
			http.Error(w, "'check_in' must be YYYY-MM-DD", http.StatusBadRequest)
			return
		}
		out, err := time.Parse("2006-01-02", checkOut)
		if err != nil {
			http.Error(w, "'check_out' must be YYYY-MM-DD", http.StatusBadRequest)
			return
		}
		if !out.After(in) {
			http.Error(w, "'check_out' must be after 'check_in'", http.StatusBadRequest)
			return
		}
	}

	adults, _ := strconv.Atoi(q.Get("adults"))
	maxPrice, _ := strconv.Atoi(q.Get("max_price"))
	minRating, _ := strconv.ParseFloat(q.Get("min_rating"), 64)

	res, err := searchHotels(r.Context(), HotelSearchRequest{
		City: city, CheckIn: checkIn, CheckOut: checkOut,
		Adults: adults, MaxPrice: maxPrice, MinRating: minRating,
	})
	if err != nil {
		// Only reachable when the discovery tier ALSO failed (e.g. Places
		// unconfigured) — a genuine outage, not a degrade. Detail stays
		// server-side; this endpoint is unauthenticated.
		ctxLog(r.Context()).Error("hotel search failed", "error", err)
		http.Error(w, "Failed to search stays", http.StatusInternalServerError)
		return
	}

	json.NewEncoder(w).Encode(res)
}
