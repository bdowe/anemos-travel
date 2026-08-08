package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Weather for trip planning via Open-Meteo (open-meteo.com) — keyless and
// free for non-commercial volumes. Within the 16-day horizon we use the real
// forecast; beyond it we report last year's observed weather for the same
// dates as "typical" (the archive API), which is what a traveler planning
// months out actually needs. Same provider-isolation convention as Duffel/
// Ticketmaster: everything Open-Meteo lives in this file behind WeatherReport.

const forecastHorizonDays = 16

type WeatherService struct {
	GeocodeBaseURL  string
	ForecastBaseURL string
	ArchiveBaseURL  string
	Client          *http.Client

	// City coordinates never move; day summaries are stable for hours.
	geoCache     *ttlCache[geoResult]
	summaryCache *ttlCache[WeatherReport]
}

type geoResult struct {
	Lat, Lon float64
	Label    string
}

// WeatherReport is the tool-facing summary: one line per day plus whether it
// is a forecast or last year's observation.
type WeatherReport struct {
	Location string       `json:"location"`
	Kind     string       `json:"kind"` // "forecast" | "historical"
	Days     []WeatherDay `json:"days"`
}

type WeatherDay struct {
	Date      string  `json:"date"`
	TempMinC  float64 `json:"temp_min_c"`
	TempMaxC  float64 `json:"temp_max_c"`
	PrecipMM  float64 `json:"precip_mm"`
	PrecipPct *int    `json:"precip_probability,omitempty"` // forecast only
}

var weatherService = NewWeatherService()

func NewWeatherService() *WeatherService {
	return &WeatherService{
		GeocodeBaseURL:  "https://geocoding-api.open-meteo.com",
		ForecastBaseURL: "https://api.open-meteo.com",
		ArchiveBaseURL:  "https://archive-api.open-meteo.com",
		Client:          newUpstreamClient(10 * time.Second),
		geoCache:        newTTLCache[geoResult](24*time.Hour, 500),
		summaryCache:    newTTLCache[WeatherReport](3*time.Hour, 500),
	}
}

func (s *WeatherService) getJSON(ctx context.Context, rawURL string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return err
	}
	resp, err := s.Client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("weather provider returned %d", resp.StatusCode)
	}
	return json.Unmarshal(body, out)
}

func (s *WeatherService) geocode(ctx context.Context, city string) (geoResult, error) {
	key := strings.ToLower(strings.TrimSpace(city))
	if hit, ok := s.geoCache.get(key); ok {
		return hit, nil
	}
	var out struct {
		Results []struct {
			Name      string  `json:"name"`
			Country   string  `json:"country"`
			Latitude  float64 `json:"latitude"`
			Longitude float64 `json:"longitude"`
		} `json:"results"`
	}
	// Geocoding language was hardcoded to English before i18n; the traveler's
	// locale now decides how the matched place is named (specs/i18n-spanish).
	u := fmt.Sprintf("%s/v1/search?name=%s&count=1&language=%s&format=json",
		s.GeocodeBaseURL, url.QueryEscape(city), requestLocale(ctx))
	if err := s.getJSON(ctx, u, &out); err != nil {
		return geoResult{}, err
	}
	if len(out.Results) == 0 {
		return geoResult{}, fmt.Errorf("no location found for %q", city)
	}
	r := out.Results[0]
	label := r.Name
	if r.Country != "" {
		label += ", " + r.Country
	}
	g := geoResult{Lat: r.Latitude, Lon: r.Longitude, Label: label}
	s.geoCache.set(key, g)
	return g, nil
}

// GetTripWeather returns day summaries for a city and date range. Dates are
// YYYY-MM-DD; ranges longer than 14 days are truncated to keep the payload
// tool-sized.
func (s *WeatherService) GetTripWeather(ctx context.Context, city, startDate, endDate string) (WeatherReport, error) {
	start, err := time.Parse(dateLayout, startDate)
	if err != nil {
		return WeatherReport{}, fmt.Errorf("start_date must be YYYY-MM-DD")
	}
	end := start
	if endDate != "" {
		if end, err = time.Parse(dateLayout, endDate); err != nil {
			return WeatherReport{}, fmt.Errorf("end_date must be YYYY-MM-DD")
		}
	}
	if end.Before(start) {
		end = start
	}
	if end.Sub(start) > 13*24*time.Hour {
		end = start.AddDate(0, 0, 13)
	}

	cacheKey := strings.Join([]string{strings.ToLower(city), startDate, endDate}, "|")
	if hit, ok := s.summaryCache.get(cacheKey); ok {
		return hit, nil
	}

	geo, err := s.geocode(ctx, city)
	if err != nil {
		return WeatherReport{}, err
	}

	// Real forecast whenever the range's REMAINING days fit the horizon —
	// including mid-trip queries whose start date is already past (clamp the
	// fetch to today). Only ranges ending beyond the horizon (or entirely in
	// the past) fall back to last year's observations as "typical".
	today := time.Now().UTC().Truncate(24 * time.Hour)
	fcStart := start
	if fcStart.Before(today) {
		fcStart = today
	}
	var report WeatherReport
	if !end.Before(today) && time.Until(end) <= forecastHorizonDays*24*time.Hour {
		report, err = s.fetchDaily(ctx, geo, fcStart, end, true)
	} else {
		report, err = s.fetchDaily(ctx, geo, start.AddDate(-1, 0, 0), end.AddDate(-1, 0, 0), false)
	}
	if err != nil {
		return WeatherReport{}, err
	}
	report.Location = geo.Label
	s.summaryCache.set(cacheKey, report)
	return report, nil
}

// fetchDaily hits Open-Meteo's forecast or archive endpoint — the two share
// the same daily-series shape, except the archive carries no precipitation
// probability — and maps the response onto a WeatherReport.
func (s *WeatherService) fetchDaily(ctx context.Context, geo geoResult, start, end time.Time, forecast bool) (WeatherReport, error) {
	var out struct {
		Daily struct {
			Time         []string  `json:"time"`
			TempMax      []float64 `json:"temperature_2m_max"`
			TempMin      []float64 `json:"temperature_2m_min"`
			PrecipSum    []float64 `json:"precipitation_sum"`
			PrecipChance []int     `json:"precipitation_probability_mean"`
		} `json:"daily"`
	}
	base, endpoint, daily, kind := s.ArchiveBaseURL, "archive",
		"temperature_2m_max,temperature_2m_min,precipitation_sum", "historical"
	if forecast {
		base, endpoint, kind = s.ForecastBaseURL, "forecast", "forecast"
		daily += ",precipitation_probability_mean"
	}
	u := fmt.Sprintf("%s/v1/%s?latitude=%f&longitude=%f&daily=%s&timezone=auto&start_date=%s&end_date=%s",
		base, endpoint, geo.Lat, geo.Lon, daily, start.Format(dateLayout), end.Format(dateLayout))
	if err := s.getJSON(ctx, u, &out); err != nil {
		return WeatherReport{}, err
	}
	report := WeatherReport{Kind: kind}
	for i, d := range out.Daily.Time {
		day := WeatherDay{Date: d}
		if i < len(out.Daily.TempMax) {
			day.TempMaxC = out.Daily.TempMax[i]
		}
		if i < len(out.Daily.TempMin) {
			day.TempMinC = out.Daily.TempMin[i]
		}
		if i < len(out.Daily.PrecipSum) {
			day.PrecipMM = out.Daily.PrecipSum[i]
		}
		if forecast && i < len(out.Daily.PrecipChance) {
			p := out.Daily.PrecipChance[i]
			day.PrecipPct = &p
		}
		report.Days = append(report.Days, day)
	}
	return report, nil
}

// weatherSearchHandler serves GET /api/v1/weather?city=&start_date=&end_date=,
// returning the WeatherReport as JSON. Public and keyless, matching the events
// lookup. Weather is best-effort trip decoration: a geocode miss or a provider
// hiccup yields a clean empty report (200) rather than a 500 — the client just
// shows no chip. Only a missing required param is a hard 400.
func weatherSearchHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	q := r.URL.Query()
	city := strings.TrimSpace(q.Get("city"))
	startDate := strings.TrimSpace(q.Get("start_date"))
	endDate := strings.TrimSpace(q.Get("end_date"))
	if city == "" || startDate == "" {
		http.Error(w, "Missing required query parameters 'city' and 'start_date'", http.StatusBadRequest)
		return
	}
	if endDate == "" {
		endDate = startDate
	}

	report, err := weatherService.GetTripWeather(r.Context(), city, startDate, endDate)
	if err != nil {
		// Best-effort: log the detail server-side, hand the client an empty
		// report so weather never blocks the itinerary or leaks provider
		// error strings.
		ctxLog(r.Context()).Info("weather lookup returned no data", "error", err)
		json.NewEncoder(w).Encode(WeatherReport{Days: []WeatherDay{}})
		return
	}
	json.NewEncoder(w).Encode(report)
}

// summarizeWeather renders a report as compact text for the model.
func summarizeWeather(r WeatherReport) string {
	var b strings.Builder
	if r.Kind == "historical" {
		fmt.Fprintf(&b, "Typical weather in %s for those dates (last year's observations — too far out for a forecast):\n", r.Location)
	} else {
		fmt.Fprintf(&b, "Forecast for %s:\n", r.Location)
	}
	for _, d := range r.Days {
		line := fmt.Sprintf("%s: %.0f–%.0f°C", d.Date, d.TempMinC, d.TempMaxC)
		if d.PrecipPct != nil {
			line += fmt.Sprintf(", %d%% chance of rain", *d.PrecipPct)
		} else if d.PrecipMM >= 1 {
			line += fmt.Sprintf(", %.0fmm rain", d.PrecipMM)
		}
		b.WriteString(line + "\n")
	}
	b.WriteString("Mention the weather where it changes advice (packing, outdoor plans, season); don't recite every day.")
	return b.String()
}
