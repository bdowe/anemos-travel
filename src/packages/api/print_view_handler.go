package main

import (
	"context"
	"fmt"
	"html/template"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/gorilla/mux"

	"travel-route-planner/store"
)

// capitalize upper-cases the first rune of a lower-case token (e.g. "morning" →
// "Morning", "flight" → "Flight") for display. Avoids the deprecated
// strings.Title while covering these single-word values.
func capitalize(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	return strings.ToUpper(s[:1]) + s[1:]
}

// segmentModeKeys maps the stored transport-mode enum to its catalog key. The
// labels live under ics.* because the .ics event titles are their canonical
// home (the Flutter client mirrors them byte-for-byte); the print packet reuses
// the same strings so a segment reads identically on paper and in a calendar.
var segmentModeKeys = map[string]string{
	"flight": "ics.mode.flight",
	"train":  "ics.mode.train",
	"bus":    "ics.mode.bus",
	"car":    "ics.mode.car",
	"ferry":  "ics.mode.ferry",
	"other":  "ics.mode.other",
}

// localizedMode renders a transport mode for display. Anything outside the
// enum falls back to capitalize(), which is exactly what the English output
// did before localization.
func localizedMode(locale, mode string) string {
	if key, ok := segmentModeKeys[strings.ToLower(strings.TrimSpace(mode))]; ok {
		return tr(locale, key)
	}
	return capitalize(mode)
}

var timeOfDayKeys = map[string]string{
	"morning":   "timeofday.morning",
	"afternoon": "timeofday.afternoon",
	"evening":   "timeofday.evening",
}

// localizedTimeOfDay renders an itinerary item's time_of_day, falling back to
// capitalize() for unexpected values.
func localizedTimeOfDay(locale, tod string) string {
	if key, ok := timeOfDayKeys[strings.ToLower(strings.TrimSpace(tod))]; ok {
		return tr(locale, key)
	}
	return capitalize(tod)
}

// print_view_handler.go — GET /api/v1/export/{token}/print.html, a printable
// full-trip page. Token-gated and PUBLIC (no authMiddleware): the signed token
// is the capability. Rendered with html/template so every field is
// auto-escaped; NEVER assemble this HTML with fmt.Sprintf (same rule as
// share_preview_handler.go).
//
// Layout is a day-by-day travel packet (specs/print-travel-packet): one
// section per calendar day (weather, transport, activities, tonight's stay),
// then Unscheduled items, reference lists for undatable stays/transport,
// Budget, and the booking/packing checklists. Budget and weather load here
// only, best-effort — loadExportData stays shared with the review engine and
// plan tools and must not grow those costs.

// maxPrintDays caps the rendered day range. The day loop iterates 1..N, so a
// stray item day (e.g. 5000) must not render thousands of sections; items
// beyond the cap fall into Unscheduled.
const maxPrintDays = 60

// maxPrintWeatherCities caps outbound weather lookups per page render.
const maxPrintWeatherCities = 5

type printItem struct {
	Name          string
	TimeOfDay     string
	City          string // set only when it differs from the day's hub (day trips)
	Address       string
	RecommendedBy string // local_source_name attribution, when present
}

type printDay struct {
	Label string // "Day 3" / "Unscheduled"
	Date  string // "Mon, Jan 2" or "" when undatable
	Items []printItem
}

type printGroup struct {
	Hub  string // day_trip_from → city → "Itinerary"
	Days []printDay
}

type printStay struct {
	Name    string
	Address string
	Meta    string // provider · price note · check-in/out or tonight note
	URL     string
	URLText string // short visible link text (paper isn't clickable)
	Booked  bool
}

type printSegment struct {
	Route   string // "Origin → Destination"
	Mode    string
	Meta    string // depart/arrive · provider · price note
	Notes   string
	URL     string
	URLText string
	Booked  bool
}

type printDaySection struct {
	Label    string // "Day 3"
	Date     string // "Mon, Jan 2" or "" for undated trips
	Hub      string // where you are that day
	DayTrip  string // "Day trip from Athens" when the whole day is one day trip
	Weather  string // formatted line; "" = omit
	Segments []printSegment
	Items    []printItem
	Stays    []printStay // tonight's stay(s)
}

type printBudgetRow struct {
	Label string
	// Planned/Amount are the two money columns (00067): what the traveler meant
	// to spend, and what was actually paid. Either may be "" — a line planned
	// but not yet paid, or a payment that was never planned — and the packet
	// prints the blank rather than repeating the other number, because on paper
	// there is no way to un-say "you spent this".
	Planned  string
	Amount   string
	Subtotal bool // category subtotal row (rendered bold)
}

type printBudget struct {
	Currency  string
	Target    string // "" when no target set
	Planned   string
	Spent     string
	Remaining string // "" when no target set
	Rows      []printBudgetRow
}

type printTodo struct {
	Title    string
	Subtitle string
	Booked   bool
}

type printChecklistGroup struct {
	Category string
	Items    []printChecklistItem
}

type printChecklistItem struct {
	Title   string
	Checked bool
}

// printLabels holds the page's static chrome in the reader's locale. The
// template can't call Sprintf, so every label is resolved up front and
// referenced as {{$.T.X}}; anything with an interpolated value stays a
// catalog template resolved in Go.
type printLabels struct {
	Weather          string
	Booked           string
	RecommendedBy    string
	NoPlans          string
	Tonight          string
	EmptyExport      string
	Unscheduled      string
	Accommodations   string
	OtherTransport   string
	Budget           string
	Target           string
	Planned          string
	TotalSpent       string
	Remaining        string
	BookingChecklist string
	PackingChecklist string
	Footer           string
}

func newPrintLabels(locale string) printLabels {
	return printLabels{
		Weather:          tr(locale, "print.weather"),
		Booked:           tr(locale, "print.booked"),
		RecommendedBy:    tr(locale, "print.recommendedBy"),
		NoPlans:          tr(locale, "print.noPlans"),
		Tonight:          tr(locale, "print.tonight"),
		EmptyExport:      tr(locale, "print.emptyExport"),
		Unscheduled:      tr(locale, "common.unscheduled"),
		Accommodations:   tr(locale, "print.accommodations"),
		OtherTransport:   tr(locale, "print.otherTransport"),
		Budget:           tr(locale, "print.budget"),
		Target:           tr(locale, "print.target"),
		Planned:          tr(locale, "print.planned"),
		TotalSpent:       tr(locale, "print.totalSpent"),
		Remaining:        tr(locale, "print.remaining"),
		BookingChecklist: tr(locale, "print.bookingChecklist"),
		PackingChecklist: tr(locale, "print.packingChecklist"),
		Footer:           tr(locale, "print.footer"),
	}
}

type printViewData struct {
	Lang          string
	T             printLabels
	Title         string
	Dates         string
	Summary       string
	Days          []printDaySection
	Unscheduled   []printGroup
	OtherStays    []printStay
	OtherSegments []printSegment
	Budget        *printBudget
	Todos         []printTodo
	Checklist     []printChecklistGroup
	HasContent    bool
}

// printViewTmpl uses html/template — every field is auto-escaped. Brand house
// style (teal gradient header) cloned from dockerize/static/privacy.html.
var printViewTmpl = template.Must(template.New("print-view").Parse(`<!DOCTYPE html>
<html lang="{{.Lang}}">
<head>
  <meta charset="utf-8">
  <title>{{.Title}} — Anemos</title>
  <style>
    * { box-sizing: border-box; }
    body {
      margin: 0;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      color: #263238; background: #fff; line-height: 1.55;
    }
    header {
      background: linear-gradient(to bottom right, #00897B, #004D40);
      color: #fff; padding: 32px 24px 28px;
    }
    header .wrap { max-width: 820px; margin: 0 auto; }
    header .brand {
      font-size: 0.8rem; letter-spacing: 0.08em; text-transform: uppercase;
      opacity: 0.85; margin: 0 0 6px; display: flex; align-items: center; gap: 10px;
    }
    header .brand img {
      /* White plate behind the bronze rose (the icon PNG is transparent).
         The app retired its plate and floats the reversed rose on teal
         instead (brand_logo.dart, policy v3) — print deliberately does not
         follow, because paper has a second state the app does not: the
         header's teal band is a background, stripped by default in print
         output, while print-color-adjust keeps this plate. The dark rose
         therefore reads either way — separated by the plate on the teal
         band, and on plain white when the band is gone. The reversed rose
         would be invisible in that second state. box-sizing is border-box,
         so grow the box to keep an 18px glyph. */
      height: 26px; width: 26px; padding: 4px;
      background: rgba(255, 255, 255, 0.92);
      border-radius: 5px;
      -webkit-print-color-adjust: exact; print-color-adjust: exact;
    }
    header h1 { margin: 0; font-size: 1.7rem; }
    header .meta { margin: 8px 0 0; opacity: 0.9; font-size: 0.95rem; }
    main { max-width: 820px; margin: 0 auto; padding: 28px 24px 56px; }
    h2 {
      color: #00695C; font-size: 1.2rem; margin: 32px 0 8px;
      border-bottom: 2px solid #B2DFDB; padding-bottom: 6px;
    }
    .summary { font-size: 1.02rem; color: #455A64; margin: 0 0 8px; }
    .day-sec { margin: 0 0 8px; }
    .daytrip { margin: -4px 0 8px; font-size: 0.92rem; color: #00695C; font-style: italic; }
    .wx { margin: 0 0 8px; font-size: 0.9rem; color: #546E7A; }
    .hub { margin: 20px 0 0; }
    .hub-name { font-size: 1.05rem; font-weight: 600; color: #004D40; margin: 0 0 4px; }
    .day { margin: 12px 0 0; padding: 10px 14px; background: #F5F7F7; border-radius: 8px; }
    .day-head { font-weight: 600; color: #00695C; margin: 0 0 6px; }
    .item { margin: 6px 0; padding-left: 14px; border-left: 3px solid #B2DFDB; }
    .item-name { font-weight: 600; }
    .item-meta { font-size: 0.9rem; color: #546E7A; }
    .rec { font-size: 0.88rem; color: #00695C; font-style: italic; }
    .row { padding: 8px 0; border-bottom: 1px solid #ECEFF1; }
    .row:last-child { border-bottom: none; }
    .row-title { font-weight: 600; }
    .row-meta { font-size: 0.9rem; color: #546E7A; }
    .stay { margin: 10px 0 0; padding: 8px 12px; background: #F5F7F7; border-radius: 8px; }
    .url { font-size: 0.85rem; color: #546E7A; word-break: break-all; }
    a { color: inherit; text-decoration: none; }
    .cat { font-weight: 600; color: #004D40; margin: 14px 0 4px; text-transform: capitalize; }
    ul.check { list-style: none; padding-left: 0; margin: 0; }
    ul.check li { padding: 3px 0; }
    .box { display: inline-block; width: 1em; }
    .booked { color: #2E7D32; }
    table.budget { border-collapse: collapse; width: 100%; max-width: 420px; }
    table.budget td { padding: 3px 0; font-size: 0.95rem; }
    table.budget td.amt { text-align: right; }
    table.budget tr.subtotal td { font-weight: 600; color: #004D40; padding-top: 8px; }
    table.budget td.exp { padding-left: 14px; color: #546E7A; }
    table.budget tr.head td { font-size: 0.8rem; color: #78909C; text-transform: uppercase; letter-spacing: 0.04em; }
    .budget-line { margin: 10px 0 0; font-weight: 600; }
    footer { margin-top: 40px; padding-top: 14px; border-top: 1px solid #CFD8DC; font-size: 0.85rem; color: #607D8B; }
    .empty { color: #607D8B; font-style: italic; }
    @page { margin: 14mm; }
    @media print {
      header { background: #004D40 !important; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
      .day-sec, .day, .hub, .row, .stay, .item, table.budget tr { break-inside: avoid; page-break-inside: avoid; }
      h2 { break-after: avoid; page-break-after: avoid; }
    }
  </style>
</head>
<body>
  <header>
    <div class="wrap">
      <p class="brand"><img src="/app/icons/Icon-512.png?v=3" alt="">Anemos</p>
      <h1>{{.Title}}</h1>
      {{if .Dates}}<p class="meta">{{.Dates}}</p>{{end}}
    </div>
  </header>
  <main>
    {{if not .HasContent}}<p class="empty">{{$.T.EmptyExport}}</p>{{end}}

    {{if .Summary}}<p class="summary">{{.Summary}}</p>{{end}}

    {{range .Days}}
    <section class="day-sec">
      <h2>{{.Label}}{{if .Date}} · {{.Date}}{{end}}{{if .Hub}} — {{.Hub}}{{end}}</h2>
      {{if .DayTrip}}<p class="daytrip">{{.DayTrip}}</p>{{end}}
      {{if .Weather}}<p class="wx">{{$.T.Weather}}: {{.Weather}}</p>{{end}}
      {{range .Segments}}
      <div class="row">
        <div class="row-title">{{.Mode}} · {{.Route}}{{if .Booked}} <span class="booked">{{$.T.Booked}}</span>{{end}}</div>
        {{if .Meta}}<div class="row-meta">{{.Meta}}</div>{{end}}
        {{if .Notes}}<div class="row-meta">{{.Notes}}</div>{{end}}
        {{if .URLText}}<div class="url"><a href="{{.URL}}">{{.URLText}}</a></div>{{end}}
      </div>
      {{end}}
      {{range .Items}}
      <div class="item">
        <div class="item-name">{{.Name}}</div>
        {{if or .TimeOfDay .City .Address}}<div class="item-meta">{{if .TimeOfDay}}{{.TimeOfDay}}{{end}}{{if and .TimeOfDay .City}} · {{end}}{{.City}}{{if and (or .TimeOfDay .City) .Address}} · {{end}}{{.Address}}</div>{{end}}
        {{if .RecommendedBy}}<div class="rec">{{$.T.RecommendedBy}} {{.RecommendedBy}}</div>{{end}}
      </div>
      {{end}}
      {{if not .Items}}<p class="empty">{{$.T.NoPlans}}</p>{{end}}
      {{range .Stays}}
      <div class="stay">
        <div class="row-title">{{$.T.Tonight}} {{.Name}}{{if .Booked}} <span class="booked">{{$.T.Booked}}</span>{{end}}</div>
        {{if .Address}}<div class="row-meta">{{.Address}}</div>{{end}}
        {{if .Meta}}<div class="row-meta">{{.Meta}}</div>{{end}}
        {{if .URLText}}<div class="url"><a href="{{.URL}}">{{.URLText}}</a></div>{{end}}
      </div>
      {{end}}
    </section>
    {{end}}

    {{if .Unscheduled}}
    <h2>{{$.T.Unscheduled}}</h2>
    {{range .Unscheduled}}
    <div class="hub">
      <p class="hub-name">{{.Hub}}</p>
      {{range .Days}}
      <div class="day">
        <p class="day-head">{{.Label}}{{if .Date}} · {{.Date}}{{end}}</p>
        {{range .Items}}
        <div class="item">
          <div class="item-name">{{.Name}}</div>
          {{if or .TimeOfDay .Address}}<div class="item-meta">{{if .TimeOfDay}}{{.TimeOfDay}}{{end}}{{if and .TimeOfDay .Address}} · {{end}}{{.Address}}</div>{{end}}
          {{if .RecommendedBy}}<div class="rec">{{$.T.RecommendedBy}} {{.RecommendedBy}}</div>{{end}}
        </div>
        {{end}}
      </div>
      {{end}}
    </div>
    {{end}}
    {{end}}

    {{if .OtherStays}}
    <h2>{{$.T.Accommodations}}</h2>
    {{range .OtherStays}}
    <div class="row">
      <div class="row-title">{{.Name}}{{if .Booked}} <span class="booked">{{$.T.Booked}}</span>{{end}}</div>
      {{if .Address}}<div class="row-meta">{{.Address}}</div>{{end}}
      {{if .Meta}}<div class="row-meta">{{.Meta}}</div>{{end}}
      {{if .URLText}}<div class="url"><a href="{{.URL}}">{{.URLText}}</a></div>{{end}}
    </div>
    {{end}}
    {{end}}

    {{if .OtherSegments}}
    <h2>{{$.T.OtherTransport}}</h2>
    {{range .OtherSegments}}
    <div class="row">
      <div class="row-title">{{.Mode}} · {{.Route}}{{if .Booked}} <span class="booked">{{$.T.Booked}}</span>{{end}}</div>
      {{if .Meta}}<div class="row-meta">{{.Meta}}</div>{{end}}
      {{if .Notes}}<div class="row-meta">{{.Notes}}</div>{{end}}
      {{if .URLText}}<div class="url"><a href="{{.URL}}">{{.URLText}}</a></div>{{end}}
    </div>
    {{end}}
    {{end}}

    {{with .Budget}}
    <h2>{{$.T.Budget}} ({{.Currency}})</h2>
    {{if .Target}}<p class="budget-line">{{$.T.Target}} {{.Target}}</p>{{end}}
    {{if .Rows}}
    <table class="budget">
      <tr class="head"><td></td><td class="amt">{{$.T.Planned}}</td><td class="amt">{{$.T.TotalSpent}}</td></tr>
      {{range .Rows}}
      <tr{{if .Subtotal}} class="subtotal"{{end}}><td{{if not .Subtotal}} class="exp"{{end}}>{{.Label}}</td><td class="amt">{{.Planned}}</td><td class="amt">{{.Amount}}</td></tr>
      {{end}}
    </table>
    {{end}}
    <p class="budget-line">{{if .Planned}}{{$.T.Planned}} {{.Planned}} · {{end}}{{$.T.TotalSpent}} {{.Spent}}{{if .Remaining}} · {{$.T.Remaining}} {{.Remaining}}{{end}}</p>
    {{end}}

    {{if .Todos}}
    <h2>{{$.T.BookingChecklist}}</h2>
    {{range .Todos}}
    <div class="row">
      <div class="row-title"><span class="box">{{if .Booked}}&#9745;{{else}}&#9744;{{end}}</span> {{.Title}}{{if .Booked}} <span class="booked">{{$.T.Booked}}</span>{{end}}</div>
      {{if .Subtitle}}<div class="row-meta">{{.Subtitle}}</div>{{end}}
    </div>
    {{end}}
    {{end}}

    {{if .Checklist}}
    <h2>{{$.T.PackingChecklist}}</h2>
    {{range .Checklist}}
    <p class="cat">{{.Category}}</p>
    <ul class="check">
      {{range .Items}}<li><span class="box">{{if .Checked}}&#9745;{{else}}&#9744;{{end}}</span> {{.Title}}</li>{{end}}
    </ul>
    {{end}}
    {{end}}

    <footer>{{$.T.Footer}}</footer>
  </main>
</body>
</html>`))

// printViewHandler renders the full trip as a printable HTML page.
func printViewHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	// localeMiddleware has already resolved ?lang= / Accept-Language; this route
	// is token-gated and public, so the request is the only locale signal.
	locale := requestLocale(r.Context())
	data, ok := resolveExport(r, mux.Vars(r)["token"])
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		w.Write([]byte("<!DOCTYPE html><html lang=\"" + locale + "\"><body><h2>" +
			template.HTMLEscapeString(tr(locale, "print.linkUnavailableTitle")) + "</h2><p>" +
			template.HTMLEscapeString(tr(locale, "print.linkUnavailableBody")) + "</p></body></html>"))
		return
	}
	budget := loadPrintBudget(r.Context(), data.Trip.ID)
	var weather []string
	if n, dated := printDayCount(data); dated {
		weather = loadPrintWeather(r.Context(), weatherService, data, n)
	}
	view := buildPrintView(locale, data, budget, weather)
	if err := printViewTmpl.Execute(w, view); err != nil {
		// Headers already sent; nothing sensible left to do.
		return
	}
}

// loadPrintBudget loads the trip's budget + expenses for display. Best-effort:
// any failure returns nil and the Budget section is simply omitted — the print
// page must render without it.
func loadPrintBudget(ctx context.Context, tripID uuid.UUID) *printBudget {
	if dbPool == nil {
		return nil
	}
	q := store.New(dbPool)
	var b *store.TripBudget
	if row, err := q.GetBudgetByTrip(ctx, tripID); err == nil {
		b = &row
	}
	expenses, err := q.ListExpensesByTrip(ctx, tripID)
	if err != nil {
		return nil
	}
	return buildPrintBudget(b, expenses)
}

// loadPrintWeather returns one formatted weather line per trip day (index 0 =
// Day 1), "" where unavailable. Best-effort: never returns an error — weather
// must not break or slow the page beyond its own timeout. Takes the service as
// a parameter so tests don't need to swap the package-level singleton.
func loadPrintWeather(ctx context.Context, ws *WeatherService, d exportData, n int) []string {
	if ws == nil || !d.Trip.StartDate.Valid || n <= 0 {
		return nil
	}
	locale := requestLocale(ctx)
	ctx, cancel := context.WithTimeout(ctx, 6*time.Second)
	defer cancel()

	start := d.Trip.StartDate.Time
	cities := resolveDayCities(d, n)
	out := make([]string, n)

	// One lookup per contiguous same-city run, capped at a handful of distinct
	// cities per render (the service's TTL cache absorbs repeats).
	type cityRun struct {
		city     string
		from, to int
	}
	var runs []cityRun
	for i := 0; i < n; i++ {
		c := cities[i]
		if c == "" {
			continue
		}
		if len(runs) > 0 && runs[len(runs)-1].city == c && runs[len(runs)-1].to == i-1 {
			runs[len(runs)-1].to = i
			continue
		}
		runs = append(runs, cityRun{city: c, from: i, to: i})
	}
	distinct := map[string]bool{}
	for _, run := range runs {
		if !distinct[run.city] {
			if len(distinct) >= maxPrintWeatherCities {
				continue
			}
			distinct[run.city] = true
		}
		report, err := ws.GetTripWeather(ctx, run.city,
			start.AddDate(0, 0, run.from).Format(dateLayout),
			start.AddDate(0, 0, run.to).Format(dateLayout))
		if err != nil || len(report.Days) == 0 {
			continue // weather is decoration; skip silently
		}
		historical := report.Kind == "historical"
		byKey := map[string]WeatherDay{}
		for _, wd := range report.Days {
			byKey[weatherDayKey(wd.Date, historical)] = wd
		}
		for i := run.from; i <= run.to; i++ {
			key := start.AddDate(0, 0, i).Format(dateLayout)
			if historical {
				key = start.AddDate(0, 0, i).Format("01-02")
			}
			if wd, ok := byKey[key]; ok {
				out[i] = formatWeatherLine(locale, wd, historical)
			}
		}
	}
	return out
}

// formatWeatherLine mirrors summarizeWeather's per-day rendering; "Typical:"
// flags archive data (last year's observations, not a forecast).
func formatWeatherLine(locale string, wd WeatherDay, historical bool) string {
	line := fmt.Sprintf("%.0f–%.0f°C", wd.TempMinC, wd.TempMaxC)
	if wd.PrecipPct != nil {
		line += tr(locale, "print.weatherRainChance", *wd.PrecipPct)
	} else if wd.PrecipMM >= 1 {
		line += tr(locale, "print.weatherRainMm", wd.PrecipMM)
	}
	if historical {
		return tr(locale, "print.weatherTypical", line)
	}
	return line
}

// buildPrintView reshapes the raw export data into the template view model:
// day-by-day packet sections plus unscheduled/reference/budget/checklist
// sections. budget and weatherByDay are optional (nil ⇒ section/lines omitted).
func buildPrintView(locale string, d exportData, budget *printBudget, weatherByDay []string) printViewData {
	d = confirmedOnly(d)
	view := printViewData{Lang: locale, T: newPrintLabels(locale), Title: strings.TrimSpace(d.Trip.Title)}
	if view.Title == "" {
		view.Title = tr(locale, "print.untitledTrip")
	}
	if d.Trip.StartDate.Valid && d.Trip.EndDate.Valid {
		view.Dates = localizedDate(locale, d.Trip.StartDate.Time, dateStyleMonthDay) + " – " + printDateWithYear(locale, d.Trip.EndDate.Time)
	} else if d.Trip.StartDate.Valid {
		view.Dates = printDateWithYear(locale, d.Trip.StartDate.Time)
	}
	view.Summary = strings.TrimSpace(strPtrVal(d.Trip.Summary))

	view.HasContent = len(d.Items) > 0 || len(d.Accommodations) > 0 ||
		len(d.Segments) > 0 || len(d.BookingTodos) > 0 || len(d.Checklist) > 0 ||
		budget != nil
	if !view.HasContent {
		return view
	}

	days, unscheduled, otherStays, otherSegs := buildPrintDays(locale, d, weatherByDay)
	view.Days = days
	view.Unscheduled = groupExportItemsIn(locale, d.Trip, unscheduled)
	view.OtherStays = otherStays
	view.OtherSegments = otherSegs
	view.Budget = budget

	for _, t := range d.BookingTodos {
		view.Todos = append(view.Todos, printTodo{
			Title:    t.Title,
			Subtitle: strPtrVal(t.Subtitle),
			Booked:   t.Booked,
		})
	}
	view.Checklist = groupChecklist(d.Checklist)
	return view
}

// printDayCount returns how many day sections to render and whether the trip
// has real dates. The count comes from the trip's date range, extended by item
// day numbers (so a Day 7 item on a 5-day trip still shows), and clamped to
// maxPrintDays. Undated trips get relative day sections from item days alone.
func printDayCount(d exportData) (int, bool) {
	dated := d.Trip.StartDate.Valid
	n := 0
	if dated {
		n = 1
		if d.Trip.EndDate.Valid {
			if span := int(d.Trip.EndDate.Time.Sub(d.Trip.StartDate.Time).Hours()/24) + 1; span > 1 {
				n = span
			}
		}
	}
	// Item days extend the range, but a runaway day number (beyond the clamp)
	// must not drag dozens of hollow sections with it — that item just lands
	// in Unscheduled instead.
	for _, it := range d.Items {
		if it.Day != nil && int(*it.Day) > n && int(*it.Day) <= maxPrintDays {
			n = int(*it.Day)
		}
	}
	if n > maxPrintDays {
		n = maxPrintDays
	}
	return n, dated
}

// resolveDayCities maps each day (index 0 = Day 1) to a city: the first item
// that day with a city, gaps inheriting the previous day's city and leading
// gaps backfilling from the first known one. Drives the day header label and
// weather lookups — deliberately prefers City over DayTripFrom (weather should
// be where you are, not the hub you left from).
func resolveDayCities(d exportData, n int) []string {
	cities := make([]string, n)
	for _, it := range d.Items {
		if it.Day == nil {
			continue
		}
		di := int(*it.Day) - 1
		if di < 0 || di >= n || cities[di] != "" {
			continue
		}
		if city := strings.TrimSpace(strPtrVal(it.City)); city != "" {
			cities[di] = city
		}
	}
	first := ""
	for _, c := range cities {
		if c != "" {
			first = c
			break
		}
	}
	prev := first
	for i := range cities {
		if cities[i] == "" {
			cities[i] = prev
		} else {
			prev = cities[i]
		}
	}
	return cities
}

// buildPrintDays assembles the day-by-day sections: items bucketed by day,
// segments attached by depart (falling back to arrive) date, stays matched to
// the nights they cover (check_in ≤ night < check_out). Whatever can't be
// placed on a day is returned for the trailing reference sections.
func buildPrintDays(locale string, d exportData, weatherByDay []string) ([]printDaySection, []store.ItineraryItem, []printStay, []printSegment) {
	n, dated := printDayCount(d)
	var unscheduled []store.ItineraryItem
	var otherStays []printStay
	var otherSegs []printSegment

	if n == 0 {
		for _, a := range d.Accommodations {
			otherStays = append(otherStays, toPrintStay(a, stayDatesNote(locale, a)))
		}
		for _, s := range d.Segments {
			otherSegs = append(otherSegs, toPrintSegment(locale, s))
		}
		return nil, d.Items, otherStays, otherSegs
	}

	start := d.Trip.StartDate.Time
	cities := resolveDayCities(d, n)
	days := make([]printDaySection, n)
	for i := range days {
		days[i].Label = tr(locale, "common.day", i+1)
		days[i].Hub = cities[i]
		if dated {
			days[i].Date = localizedDate(locale, start.AddDate(0, 0, i), dateStyleWeekdayMonthDay)
		}
		if i < len(weatherByDay) {
			days[i].Weather = weatherByDay[i]
		}
	}

	// Items, in position order. A day whose items all share one non-empty
	// DayTripFrom gets a "Day trip from <hub>" subline; the sentinel marks a
	// day disqualified by a mixed or missing hub.
	const mixedDayTrip = "\x00"
	dayTripHub := make([]string, n)
	for _, it := range d.Items {
		di := -1
		if it.Day != nil {
			di = int(*it.Day) - 1
		}
		if di < 0 || di >= n {
			unscheduled = append(unscheduled, it)
			continue
		}
		item := printItem{
			Name:          it.Name,
			TimeOfDay:     localizedTimeOfDay(locale, strPtrVal(it.TimeOfDay)),
			Address:       strPtrVal(it.Address),
			RecommendedBy: strPtrVal(it.LocalSourceName),
		}
		if city := strings.TrimSpace(strPtrVal(it.City)); city != "" && !strings.EqualFold(city, cities[di]) {
			item.City = city
		}
		days[di].Items = append(days[di].Items, item)

		dtf := strings.TrimSpace(strPtrVal(it.DayTripFrom))
		switch {
		case dtf == "":
			dayTripHub[di] = mixedDayTrip
		case dayTripHub[di] == "":
			dayTripHub[di] = dtf
		case !strings.EqualFold(dayTripHub[di], dtf):
			dayTripHub[di] = mixedDayTrip
		}
	}
	for i, hub := range dayTripHub {
		if hub != "" && hub != mixedDayTrip {
			days[i].DayTrip = tr(locale, "print.dayTripFrom", hub)
		}
	}

	dayIndexOf := func(t time.Time) int {
		if !dated {
			return -1
		}
		di := int(t.Sub(start).Hours() / 24)
		if di < 0 || di >= n {
			return -1
		}
		return di
	}

	for _, s := range d.Segments {
		di := -1
		if s.DepartDate.Valid {
			di = dayIndexOf(s.DepartDate.Time)
		}
		if di < 0 && s.ArriveDate.Valid {
			di = dayIndexOf(s.ArriveDate.Time)
		}
		if di < 0 {
			otherSegs = append(otherSegs, toPrintSegment(locale, s))
			continue
		}
		days[di].Segments = append(days[di].Segments, toPrintSegment(locale, s))
	}

	for _, a := range d.Accommodations {
		attached := false
		if dated && a.CheckIn.Valid {
			checkIn := a.CheckIn.Time
			checkOut := checkIn.AddDate(0, 0, 1) // no/invalid check-out ⇒ single night
			if a.CheckOut.Valid && a.CheckOut.Time.After(checkIn) {
				checkOut = a.CheckOut.Time
			}
			for i := 0; i < n; i++ {
				night := start.AddDate(0, 0, i)
				if night.Before(checkIn) || !night.Before(checkOut) {
					continue
				}
				var notes []string
				if night.Equal(checkIn) {
					notes = append(notes, tr(locale, "print.checkInToday"))
				}
				if a.CheckOut.Valid && night.Equal(checkOut.AddDate(0, 0, -1)) {
					notes = append(notes, tr(locale, "print.checkOutOn",
						localizedDate(locale, checkOut, dateStyleWeekdayMonthDay)))
				}
				days[i].Stays = append(days[i].Stays, toPrintStay(a, strings.Join(notes, " · ")))
				attached = true
			}
		}
		if !attached {
			otherStays = append(otherStays, toPrintStay(a, stayDatesNote(locale, a)))
		}
	}

	// Undated trips can't attach weather, stays, or transport to a day, so an
	// item-less "Day N" section would be an empty shell — drop those. Dated
	// trips keep them (real calendar days worth showing even when unplanned).
	if !dated {
		filtered := days[:0]
		for _, day := range days {
			if len(day.Items) > 0 {
				filtered = append(filtered, day)
			}
		}
		days = filtered
	}

	return days, unscheduled, otherStays, otherSegs
}

// buildPrintBudget shapes the budget section: expenses grouped by category in
// first-appearance order, each group led by a bold subtotal row. Returns nil
// when there is nothing worth printing.
func buildPrintBudget(b *store.TripBudget, expenses []store.TripExpense) *printBudget {
	if len(expenses) == 0 && (b == nil || b.TargetAmount == nil) {
		return nil
	}
	pb := &printBudget{Currency: "USD"}
	if b != nil {
		if c := strings.TrimSpace(b.Currency); c != "" {
			pb.Currency = c
		}
		if b.TargetAmount != nil {
			pb.Target = formatMoneyAmount(*b.TargetAmount)
		}
	}

	type catGroup struct {
		name     string
		expenses []store.TripExpense
	}
	var groups []*catGroup
	idx := map[string]*catGroup{}
	for _, e := range expenses {
		g, ok := idx[e.Category]
		if !ok {
			g = &catGroup{name: e.Category}
			idx[e.Category] = g
			groups = append(groups, g)
		}
		g.expenses = append(g.expenses, e)
	}
	for _, g := range groups {
		// Subtotals come from the same summing function as the totals, so a
		// column that doesn't foot is a test failure and not a rounding story.
		sub := sumExpenses(g.expenses)
		pb.Rows = append(pb.Rows, printBudgetRow{
			Label:    capitalize(g.name),
			Planned:  formatOptionalMoneyAmount(&sub.Planned, sub.Planned > 0),
			Amount:   formatOptionalMoneyAmount(&sub.Spent, sub.Spent > 0),
			Subtotal: true,
		})
		for _, e := range g.expenses {
			pb.Rows = append(pb.Rows, printBudgetRow{
				Label:   e.Label,
				Planned: formatOptionalMoneyAmount(e.PlannedAmount, e.PlannedAmount != nil),
				Amount:  formatOptionalMoneyAmount(e.ActualAmount, e.ActualAmount != nil),
			})
		}
	}
	totals := sumExpenses(expenses)
	pb.Spent = formatMoneyAmount(totals.Spent)
	if totals.Planned > 0 {
		pb.Planned = formatMoneyAmount(totals.Planned)
	}
	if b != nil && b.TargetAmount != nil {
		pb.Remaining = formatMoneyAmount(*b.TargetAmount - totals.Spent)
	}
	return pb
}

// formatOptionalMoneyAmount renders v only when present; an absent number
// prints as a blank cell, never as 0.00 (a zero a traveler did not write down
// is a claim the packet has no way to retract on paper).
func formatOptionalMoneyAmount(v *float64, present bool) string {
	if v == nil || !present {
		return ""
	}
	return formatMoneyAmount(*v)
}

func formatMoneyAmount(v float64) string {
	return strconv.FormatFloat(v, 'f', 2, 64)
}

func toPrintSegment(locale string, s store.TripSegment) printSegment {
	var meta []string
	if dep := formatExportDate(locale, dateToPtr(s.DepartDate)); dep != "" {
		meta = append(meta, tr(locale, "print.departs", dep))
	}
	if arr := formatExportDate(locale, dateToPtr(s.ArriveDate)); arr != "" {
		meta = append(meta, tr(locale, "print.arrives", arr))
	}
	if p := strings.TrimSpace(strPtrVal(s.Provider)); p != "" {
		meta = append(meta, p)
	}
	if pn := strings.TrimSpace(strPtrVal(s.PriceNote)); pn != "" {
		meta = append(meta, pn)
	}
	rawURL := strings.TrimSpace(strPtrVal(s.Url))
	return printSegment{
		Route:   segmentRouteIn(locale, s),
		Mode:    localizedMode(locale, s.Mode),
		Meta:    strings.Join(meta, " · "),
		Notes:   strings.TrimSpace(strPtrVal(s.Notes)),
		URL:     rawURL,
		URLText: displayURL(rawURL),
		Booked:  s.Booked,
	}
}

// toPrintStay converts an accommodation; note is context-dependent (a tonight
// note on day sections, the check-in/out range on reference lists).
func toPrintStay(a store.Accommodation, note string) printStay {
	var meta []string
	if p := strings.TrimSpace(strPtrVal(a.Provider)); p != "" {
		meta = append(meta, p)
	}
	if pn := strings.TrimSpace(strPtrVal(a.PriceNote)); pn != "" {
		meta = append(meta, pn)
	}
	if note != "" {
		meta = append(meta, note)
	}
	rawURL := strings.TrimSpace(strPtrVal(a.Url))
	return printStay{
		Name:    a.Name,
		Address: strPtrVal(a.Address),
		Meta:    strings.Join(meta, " · "),
		URL:     rawURL,
		URLText: displayURL(rawURL),
		Booked:  a.Booked,
	}
}

// stayDatesNote renders the reference-list date range for a stay.
func stayDatesNote(locale string, a store.Accommodation) string {
	var parts []string
	if ci := formatExportDate(locale, dateToPtr(a.CheckIn)); ci != "" {
		parts = append(parts, tr(locale, "print.checkIn", ci))
	}
	if co := formatExportDate(locale, dateToPtr(a.CheckOut)); co != "" {
		parts = append(parts, tr(locale, "print.checkOut", co))
	}
	return strings.Join(parts, " · ")
}

// displayURL builds the short visible text for a booking link — paper isn't
// clickable, so the reader needs something typable: host + path, no scheme,
// "www." or query noise, truncated.
func displayURL(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	display := raw
	if u, err := url.Parse(raw); err == nil && u.Host != "" {
		display = strings.TrimPrefix(u.Host, "www.") + strings.TrimSuffix(u.Path, "/")
	}
	const maxRunes = 48
	runes := []rune(display)
	if len(runes) > maxRunes {
		return string(runes[:maxRunes-1]) + "…"
	}
	return display
}

// groupExportItems is the English-locale entry point, kept for trip_review.go,
// which reads only the hub grouping and has no locale to thread through.
func groupExportItems(trip store.Trip, items []store.ItineraryItem) []printGroup {
	return groupExportItemsIn(defaultLocale, trip, items)
}

// groupExportItemsIn walks items in position order and groups them by hub
// (day_trip_from, falling back to city, then "Itinerary"), sub-grouping by day.
// First-appearance order is preserved for both hubs and days. Per-item date is
// trip.start_date + (day-1) when both are present. Used for the Unscheduled
// section (and exercised by the .ics fixture tests).
func groupExportItemsIn(locale string, trip store.Trip, items []store.ItineraryItem) []printGroup {
	var groups []printGroup
	groupIdx := map[string]int{}
	dayIdx := map[string]int{} // key: hub + "\x00" + day

	for _, it := range items {
		hub := strings.TrimSpace(strPtrVal(it.DayTripFrom))
		if hub == "" {
			hub = strings.TrimSpace(strPtrVal(it.City))
		}
		if hub == "" {
			hub = tr(locale, "print.itinerary")
		}
		gi, ok := groupIdx[hub]
		if !ok {
			gi = len(groups)
			groupIdx[hub] = gi
			groups = append(groups, printGroup{Hub: hub})
		}

		dayNum := 0
		if it.Day != nil {
			dayNum = int(*it.Day)
		}
		dayKey := hub + "\x00" + strconv.Itoa(dayNum)
		di, ok := dayIdx[dayKey]
		if !ok {
			di = len(groups[gi].Days)
			dayIdx[dayKey] = di
			label := tr(locale, "common.unscheduled")
			date := ""
			if dayNum > 0 {
				label = tr(locale, "common.day", dayNum)
				if trip.StartDate.Valid {
					date = localizedDate(locale, trip.StartDate.Time.AddDate(0, 0, dayNum-1), dateStyleWeekdayMonthDay)
				}
			}
			groups[gi].Days = append(groups[gi].Days, printDay{Label: label, Date: date})
		}

		groups[gi].Days[di].Items = append(groups[gi].Days[di].Items, printItem{
			Name:          it.Name,
			TimeOfDay:     localizedTimeOfDay(locale, strPtrVal(it.TimeOfDay)),
			Address:       strPtrVal(it.Address),
			RecommendedBy: strPtrVal(it.LocalSourceName),
		})
	}
	return groups
}

// groupChecklist buckets packing items by category, preserving first-appearance
// order (items already arrive sorted by position).
func groupChecklist(items []store.TripChecklistItem) []printChecklistGroup {
	var groups []printChecklistGroup
	idx := map[string]int{}
	for _, it := range items {
		gi, ok := idx[it.Category]
		if !ok {
			gi = len(groups)
			idx[it.Category] = gi
			groups = append(groups, printChecklistGroup{Category: it.Category})
		}
		groups[gi].Items = append(groups[gi].Items, printChecklistItem{Title: it.Title, Checked: it.Checked})
	}
	return groups
}

// segmentRoute is the English-locale entry point, kept for trip_review.go.
func segmentRoute(s store.TripSegment) string {
	return segmentRouteIn(defaultLocale, s)
}

// segmentRouteIn renders "Origin → Destination", tolerating missing endpoints.
// Only the both-endpoints-missing fallback (the mode name) is localizable; the
// endpoints themselves are traveler-supplied place names.
func segmentRouteIn(locale string, s store.TripSegment) string {
	o := strings.TrimSpace(strPtrVal(s.Origin))
	dst := strings.TrimSpace(strPtrVal(s.Destination))
	switch {
	case o != "" && dst != "":
		return o + " → " + dst
	case dst != "":
		return dst
	case o != "":
		return o
	default:
		return localizedMode(locale, s.Mode)
	}
}

// formatExportDate turns a *string "YYYY-MM-DD" into a friendly "Mon, Jan 2"
// ("lun, 2 ene" in Spanish), leaving an unparseable value untouched.
func formatExportDate(locale string, s *string) string {
	if s == nil || *s == "" {
		return ""
	}
	t, err := time.Parse(dateLayout, *s)
	if err != nil {
		return *s
	}
	return localizedDate(locale, t, dateStyleWeekdayMonthDay)
}

// printDateWithYear renders a year-qualified short date: "Aug 5, 2026" /
// "5 ago de 2026". localizedDate has no year-bearing short style, so the year
// is joined through the catalog to keep Spanish's "de" in the right place.
func printDateWithYear(locale string, t time.Time) string {
	return tr(locale, "print.dateWithYear", localizedDate(locale, t, dateStyleMonthDay), t.Year())
}
