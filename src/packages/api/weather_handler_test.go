package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// A fake Open-Meteo: /v1/search geocodes (optionally empty), /v1/forecast and
// /v1/archive return a two-day daily series. Lets the handler test drive the
// real WeatherService end to end without hitting the network.
func newTestWeatherServer(t *testing.T, geocodeHit bool) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.Contains(r.URL.Path, "/search"):
			if !geocodeHit {
				w.Write([]byte(`{"results":[]}`))
				return
			}
			w.Write([]byte(`{"results":[{"name":"Paris","country":"France","latitude":48.85,"longitude":2.35}]}`))
		default: // forecast or archive
			w.Write([]byte(`{"daily":{"time":["2099-08-01","2099-08-02"],"temperature_2m_max":[26,28],"temperature_2m_min":[17,18],"precipitation_sum":[0,3],"precipitation_probability_mean":[10,60]}}`))
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func withTestWeatherService(t *testing.T, geocodeHit bool) {
	t.Helper()
	srv := newTestWeatherServer(t, geocodeHit)
	prev := weatherService
	t.Cleanup(func() { weatherService = prev })
	weatherService = &WeatherService{
		GeocodeBaseURL:  srv.URL,
		ForecastBaseURL: srv.URL,
		ArchiveBaseURL:  srv.URL,
		Client:          srv.Client(),
		geoCache:        newTTLCache[geoResult](time.Hour, 10),
		summaryCache:    newTTLCache[WeatherReport](time.Hour, 10),
	}
}

func TestWeatherHandlerMissingParams(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/api/v1/weather?start_date=2099-08-01", nil)
	rec := httptest.NewRecorder()
	weatherSearchHandler(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for missing city, got %d", rec.Code)
	}
}

func TestWeatherHandlerReturnsReport(t *testing.T) {
	withTestWeatherService(t, true)
	// A far-future range so the archive ("historical") branch runs deterministically.
	req := httptest.NewRequest(http.MethodGet, "/api/v1/weather?city=Paris&start_date=2099-08-01&end_date=2099-08-02", nil)
	rec := httptest.NewRecorder()
	weatherSearchHandler(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var report WeatherReport
	if err := json.Unmarshal(rec.Body.Bytes(), &report); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(report.Days) != 2 {
		t.Fatalf("expected 2 days, got %d", len(report.Days))
	}
	if report.Location == "" {
		t.Fatalf("expected a resolved location label")
	}
}

// Like withTestWeatherService, but the daily endpoints return the given JSON
// body verbatim — for exercising null and short daily arrays (Open-Meteo keeps
// unmodelable days in time[] with null metric values).
func withTestWeatherServiceDaily(t *testing.T, dailyJSON string) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.Contains(r.URL.Path, "/search") {
			w.Write([]byte(`{"results":[{"name":"Paris","country":"France","latitude":48.85,"longitude":2.35}]}`))
			return
		}
		w.Write([]byte(dailyJSON))
	}))
	t.Cleanup(srv.Close)
	prev := weatherService
	t.Cleanup(func() { weatherService = prev })
	weatherService = &WeatherService{
		GeocodeBaseURL:  srv.URL,
		ForecastBaseURL: srv.URL,
		ArchiveBaseURL:  srv.URL,
		Client:          srv.Client(),
		geoCache:        newTTLCache[geoResult](time.Hour, 10),
		summaryCache:    newTTLCache[WeatherReport](time.Hour, 10),
	}
}

func getWeatherReport(t *testing.T, query string) (WeatherReport, *httptest.ResponseRecorder) {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/weather?"+query, nil)
	rec := httptest.NewRecorder()
	weatherSearchHandler(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var report WeatherReport
	if err := json.Unmarshal(rec.Body.Bytes(), &report); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return report, rec
}

// A near-future range so the forecast branch runs (the fake ignores the query
// dates; 2099 ranges steer to the archive branch instead).
func nearFutureRange(days int) string {
	now := time.Now().UTC()
	return "city=Paris&start_date=" + now.AddDate(0, 0, 1).Format(dateLayout) +
		"&end_date=" + now.AddDate(0, 0, days).Format(dateLayout)
}

func TestWeatherServiceDropsNullTailDays(t *testing.T) {
	// The day past Open-Meteo's forecast horizon still appears in time[] but
	// carries null temps; it must be dropped, not parsed as a phantom 0°C.
	withTestWeatherServiceDaily(t, `{"daily":{"time":["2026-08-24","2026-08-25","2026-08-26"],"temperature_2m_max":[26,28,null],"temperature_2m_min":[17,18,null],"precipitation_sum":[0,3,null],"precipitation_probability_mean":[10,60,null]}}`)
	report, _ := getWeatherReport(t, nearFutureRange(3))
	if report.Kind != "forecast" {
		t.Fatalf("expected forecast branch, got %q", report.Kind)
	}
	if len(report.Days) != 2 {
		t.Fatalf("expected the null-temp day dropped (2 days), got %d", len(report.Days))
	}
	for _, d := range report.Days {
		if d.TempMinC == 0 || d.TempMaxC == 0 {
			t.Fatalf("phantom 0° leaked: %+v", d)
		}
		if d.Date == "2026-08-26" {
			t.Fatalf("null-temp day survived: %+v", d)
		}
	}
}

func TestWeatherServiceNullPrecipKeepsDay(t *testing.T) {
	// Null precip must not discard a day with valid temps: a missing sum
	// stays 0mm, and a missing probability stays nil — not a false "0%".
	withTestWeatherServiceDaily(t, `{"daily":{"time":["2026-08-24","2026-08-25"],"temperature_2m_max":[26,28],"temperature_2m_min":[17,18],"precipitation_sum":[null,3],"precipitation_probability_mean":[10,null]}}`)
	report, _ := getWeatherReport(t, nearFutureRange(2))
	if len(report.Days) != 2 {
		t.Fatalf("expected both days kept, got %d", len(report.Days))
	}
	if report.Days[0].PrecipPct == nil || *report.Days[0].PrecipPct != 10 {
		t.Fatalf("expected day 1 precip probability 10, got %v", report.Days[0].PrecipPct)
	}
	if report.Days[1].PrecipPct != nil {
		t.Fatalf("expected nil probability for null, got %d", *report.Days[1].PrecipPct)
	}
	if report.Days[0].PrecipMM != 0 || report.Days[1].PrecipMM != 3 {
		t.Fatalf("unexpected precip mm: %+v", report.Days)
	}
}

func TestWeatherServiceDropsShortArrayDays(t *testing.T) {
	// A temp array shorter than time[] means the tail days carry no data —
	// they must be dropped, not zero-filled.
	withTestWeatherServiceDaily(t, `{"daily":{"time":["2099-08-01","2099-08-02","2099-08-03"],"temperature_2m_max":[26,28],"temperature_2m_min":[17,18],"precipitation_sum":[0,3]}}`)
	report, _ := getWeatherReport(t, "city=Paris&start_date=2099-08-01&end_date=2099-08-03")
	if len(report.Days) != 2 {
		t.Fatalf("expected short-array tail dropped (2 days), got %d", len(report.Days))
	}
}

func TestWeatherHandlerAllNullDaysIsEmptyReport(t *testing.T) {
	withTestWeatherServiceDaily(t, `{"daily":{"time":["2026-08-24","2026-08-25"],"temperature_2m_max":[null,null],"temperature_2m_min":[null,null],"precipitation_sum":[null,null],"precipitation_probability_mean":[null,null]}}`)
	report, rec := getWeatherReport(t, nearFutureRange(2))
	if len(report.Days) != 0 {
		t.Fatalf("expected all days dropped, got %d", len(report.Days))
	}
	if report.Location == "" {
		t.Fatalf("expected the success path (resolved location), not the error path")
	}
	if !strings.Contains(rec.Body.String(), `"days":[]`) {
		t.Fatalf("expected days to serialize as [], got %s", rec.Body.String())
	}
}

func TestWeatherServiceArchiveDropsNullDays(t *testing.T) {
	// The forecast and archive branches share fetchDaily; the null-day drop
	// must hold for historical data too.
	withTestWeatherServiceDaily(t, `{"daily":{"time":["2099-08-01","2099-08-02","2099-08-03"],"temperature_2m_max":[26,null,28],"temperature_2m_min":[17,null,18],"precipitation_sum":[0,null,3]}}`)
	report, _ := getWeatherReport(t, "city=Paris&start_date=2099-08-01&end_date=2099-08-03")
	if report.Kind != "historical" {
		t.Fatalf("expected archive branch, got %q", report.Kind)
	}
	if len(report.Days) != 2 {
		t.Fatalf("expected the null middle day dropped (2 days), got %d", len(report.Days))
	}
}

func TestWeatherHandlerGeocodeMissIsEmptyNot500(t *testing.T) {
	withTestWeatherService(t, false)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/weather?city=Nowheresville&start_date=2099-08-01", nil)
	rec := httptest.NewRecorder()
	weatherSearchHandler(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected best-effort 200 on geocode miss, got %d", rec.Code)
	}
	var report WeatherReport
	if err := json.Unmarshal(rec.Body.Bytes(), &report); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(report.Days) != 0 {
		t.Fatalf("expected empty report, got %d days", len(report.Days))
	}
}
