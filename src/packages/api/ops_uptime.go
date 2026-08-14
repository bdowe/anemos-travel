package main

// Uptime history rollup + endpoint (specs/uptime-history): turns the
// health_samples stream written by ops_monitor.go into the per-day, per-
// component availability the admin Health pane's 90-day status strip renders.
//
//	GET /admin/ops/uptime?days=   — admin-gated at route registration; 503 in
//	                                degraded mode (the history lives in the DB),
//	                                unlike its /admin/ops/* siblings.
//
// rollupUptime is PURE and is the only place any of this is derived
// (docs/zen.md: derived state is computed in exactly one place). Every sample
// row is an interval with a state, so the walk here sums labeled seconds and
// infers nothing; the attribution table lives in rowVerdicts, stated once.
//
// The wire carries stable reason CODES, not prose — writeJSONError-style
// strings are not localized in this repo (i18n.go), so day reasons are enum
// codes the Flutter client localizes.

import (
	"errors"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"travel-route-planner/store"
)

const (
	// Day / current states on the wire. no_data is first-class: a day nobody
	// observed is a different fact from a 0% day and from a 100% day.
	uptimeStateUp       = "up"
	uptimeStateDegraded = "degraded"
	uptimeStateDown     = "down"
	uptimeStateNoData   = "no_data"

	// Stable per-day reason codes (localized client-side, never prose here).
	uptimeReasonDBUnreachable = "db_unreachable"
	uptimeReasonProcessDown   = "process_down"
	uptimeReasonAIFailing     = "ai_failing"
	uptimeReasonBackupsStale  = "backups_stale"

	// degradedPctFloor splits an unhealthy day into degraded (a blip) vs down
	// (a real outage) for the bar color.
	degradedPctFloor = 99.0

	uptimeMaxDays = 90
)

// Component slots, index-addressed by the rollup. Order is the render order.
const (
	uptimeCompAPI = iota
	uptimeCompDatabase
	uptimeCompAI
	uptimeCompBackups
	uptimeCompCount
)

var uptimeComponentKeys = [uptimeCompCount]string{"api", "database", "ai_provider", "backups"}

// UptimeDay is one UTC calendar day for one component. UptimePct is null IFF
// State is no_data — 0.0, 100.0 and null are three different values, and the
// seconds always satisfy up+down+unknown == elapsed (86400, or less for
// today / the window's first monitored day).
type UptimeDay struct {
	Day         string   `json:"day"` // YYYY-MM-DD, UTC bucket
	State       string   `json:"state"`
	UptimePct   *float64 `json:"uptime_pct"`
	UpS         int64    `json:"up_s"`
	DownS       int64    `json:"down_s"`
	UnknownS    int64    `json:"unknown_s"`
	ReasonCodes []string `json:"reason_codes"` // non-nil (empty slice, not null)
}

// UptimeComponent is one status-page row. Days is DENSE — exactly Days entries,
// oldest first — deliberately unlike the sparse EventDailyCounts precedent: a
// missing day MEANS something here, and letting the client synthesize it would
// put that meaning in two places. Status is the freshest sample's verdict
// (up/down), or no_data when the newest sample is stale or absent — it is an
// instant, so it never says "degraded".
type UptimeComponent struct {
	Key          string      `json:"key"`
	Status       string      `json:"status"`
	UptimePct    *float64    `json:"uptime_pct"` // window-wide, over observed seconds only
	ObservedDays int         `json:"observed_days"`
	Days         []UptimeDay `json:"days"`
}

// UptimeResponse is the body of GET /admin/ops/uptime.
type UptimeResponse struct {
	Days     int    `json:"days"`
	StartDay string `json:"start_day"` // first day of the window, YYYY-MM-DD UTC
	// MonitoringSince is when the first sample ever was recorded (RFC3339),
	// null before any exist — it is what lets the pane caption a wall of grey
	// bars as "before we were watching" instead of leaving them unexplained.
	MonitoringSince *string           `json:"monitoring_since"`
	Components      []UptimeComponent `json:"components"`
}

// uptimeVerdict is one component's share of one sample row.
type uptimeVerdict struct {
	state  uint8 // one of the verdict* constants below
	reason string
}

const (
	verdictUp uint8 = iota
	verdictDown
	verdictUnknown
)

// rowVerdicts is THE attribution table — the entire meaning of a sample row,
// stated once:
//
//	row              | api   | database | ai_provider | backups
//	tick, db_ok      | up    | up       | ai_ok?      | backups_ok?
//	tick, !db_ok     | DOWN  | down     | ai_ok?      | backups_ok?
//	gap,  deploy     | unk   | unknown  | unknown     | unknown
//	gap,  unknown    | DOWN  | unknown  | unknown     | unknown
//
// api contains database on purpose — the app is unusable without persistence —
// one verdict with a documented containment, not two competing ones. A gap
// says nothing about Anthropic or backups: charging our own restart to their
// uptime would be a lie, so gap seconds are unknown everywhere except the api
// row, where an UNEXPLAINED gap (crash/OOM/host reboot; ops_monitor.go decided
// the cause at boot) is downtime. Deploy gaps are unknown even for api — that
// is what keeps 6-12 deploys/day from denting the number.
func rowVerdicts(row store.HealthSamplesSinceRow) [uptimeCompCount]uptimeVerdict {
	boolVerdict := func(ok *bool, reason string) uptimeVerdict {
		if ok != nil && *ok {
			return uptimeVerdict{state: verdictUp}
		}
		return uptimeVerdict{state: verdictDown, reason: reason}
	}

	if row.Kind == healthSampleGap {
		v := [uptimeCompCount]uptimeVerdict{}
		for i := range v {
			v[i] = uptimeVerdict{state: verdictUnknown}
		}
		if row.GapCause != nil && *row.GapCause == healthGapUnknown {
			v[uptimeCompAPI] = uptimeVerdict{state: verdictDown, reason: uptimeReasonProcessDown}
		}
		return v
	}

	dbOK := row.DbOk != nil && *row.DbOk
	api := uptimeVerdict{state: verdictUp}
	if !dbOK {
		api = uptimeVerdict{state: verdictDown, reason: uptimeReasonDBUnreachable}
	}
	return [uptimeCompCount]uptimeVerdict{
		uptimeCompAPI:      api,
		uptimeCompDatabase: boolVerdict(row.DbOk, uptimeReasonDBUnreachable),
		uptimeCompAI:       boolVerdict(row.AiOk, uptimeReasonAIFailing),
		uptimeCompBackups:  boolVerdict(row.BackupsOk, uptimeReasonBackupsStale),
	}
}

// dayBucket accumulates one component's seconds for one day.
type dayBucket struct {
	upS, downS int64
	reasons    map[string]bool
}

// rollupUptime folds the ascending sample stream into the response. Pure —
// unit-tested with literal fixtures. rows must be ordered by observed_at (the
// query guarantees it); each covers [CoversFrom, ObservedAt), clipped to the
// window and split at UTC midnights. unknown_s is derived, not tracked:
// elapsed − up − down, which uniformly covers deploy gaps, time before
// monitoring began, and today's still-unwritten tail. staleAfter bounds how
// old the newest sample may be while still driving the current-status pill.
func rollupUptime(rows []store.HealthSamplesSinceRow, startDay time.Time, days int, now time.Time, monitoringSince *string, staleAfter time.Duration) UptimeResponse {
	buckets := make([][uptimeCompCount]dayBucket, days)
	for d := range buckets {
		for c := range buckets[d] {
			buckets[d][c].reasons = map[string]bool{}
		}
	}

	windowEnd := now
	prevEnd := time.Time{} // defensive monotonic clip: rows must not overlap
	for _, row := range rows {
		from, to := row.CoversFrom, row.ObservedAt
		if from.Before(prevEnd) {
			from = prevEnd
		}
		prevEnd = to
		if from.Before(startDay) {
			from = startDay
		}
		if to.After(windowEnd) {
			to = windowEnd
		}
		if !from.Before(to) {
			continue
		}
		verdicts := rowVerdicts(row)

		// Split [from, to) at UTC midnights and add each segment to its day.
		for from.Before(to) {
			dayStart := from.UTC().Truncate(24 * time.Hour)
			segEnd := dayStart.Add(24 * time.Hour)
			if segEnd.After(to) {
				segEnd = to
			}
			d := int(dayStart.Sub(startDay) / (24 * time.Hour))
			if d >= 0 && d < days {
				secs := int64(segEnd.Sub(from).Seconds())
				for c, v := range verdicts {
					switch v.state {
					case verdictUp:
						buckets[d][c].upS += secs
					case verdictDown:
						buckets[d][c].downS += secs
						buckets[d][c].reasons[v.reason] = true
					}
					// verdictUnknown: contributes nothing; unknown_s is derived.
				}
			}
			from = segEnd
		}
	}

	resp := UptimeResponse{
		Days:            days,
		StartDay:        startDay.Format("2006-01-02"),
		MonitoringSince: monitoringSince,
		Components:      make([]UptimeComponent, 0, uptimeCompCount),
	}
	for c := 0; c < uptimeCompCount; c++ {
		comp := UptimeComponent{
			Key:    uptimeComponentKeys[c],
			Status: currentStatus(rows, c, now, staleAfter),
			Days:   make([]UptimeDay, 0, days),
		}
		var totalUp, totalDown int64
		for d := 0; d < days; d++ {
			dayStart := startDay.AddDate(0, 0, d)
			elapsed := int64((24 * time.Hour).Seconds())
			if tail := int64(now.Sub(dayStart).Seconds()); tail < elapsed {
				elapsed = tail // today: only elapsed time is accounted for
			}
			b := buckets[d][c]
			state, pct := dayVerdict(b.upS, b.downS)
			unknown := elapsed - b.upS - b.downS
			if unknown < 0 {
				unknown = 0
			}
			reasons := make([]string, 0, len(b.reasons))
			// Fixed order so the payload is deterministic.
			for _, code := range []string{uptimeReasonProcessDown, uptimeReasonDBUnreachable, uptimeReasonAIFailing, uptimeReasonBackupsStale} {
				if b.reasons[code] {
					reasons = append(reasons, code)
				}
			}
			comp.Days = append(comp.Days, UptimeDay{
				Day:         dayStart.Format("2006-01-02"),
				State:       state,
				UptimePct:   pct,
				UpS:         b.upS,
				DownS:       b.downS,
				UnknownS:    unknown,
				ReasonCodes: reasons,
			})
			if b.upS+b.downS > 0 {
				comp.ObservedDays++
			}
			totalUp += b.upS
			totalDown += b.downS
		}
		if totalUp+totalDown > 0 {
			pct := round2(float64(totalUp) / float64(totalUp+totalDown) * 100)
			comp.UptimePct = &pct
		}
		resp.Components = append(resp.Components, comp)
	}
	return resp
}

// dayVerdict is the one place a day's seconds become a state + percentage.
// no_data (nil pct) when nothing was observed; up only when zero seconds were
// unhealthy; degraded vs down splits on degradedPctFloor.
func dayVerdict(upS, downS int64) (string, *float64) {
	observed := upS + downS
	if observed == 0 {
		return uptimeStateNoData, nil
	}
	pct := round2(float64(upS) / float64(observed) * 100)
	switch {
	case downS == 0:
		return uptimeStateUp, &pct
	case pct >= degradedPctFloor:
		return uptimeStateDegraded, &pct
	default:
		return uptimeStateDown, &pct
	}
}

// currentStatus derives the pill next to a strip from the NEWEST tick row —
// up/down at an instant, so never "degraded" — or no_data when the newest
// sample is older than staleAfter (the sampler is not running / just booted)
// or absent. Gap rows carry no component booleans, so only ticks qualify.
func currentStatus(rows []store.HealthSamplesSinceRow, comp int, now time.Time, staleAfter time.Duration) string {
	for i := len(rows) - 1; i >= 0; i-- {
		row := rows[i]
		if row.Kind != healthSampleTick {
			continue
		}
		if now.Sub(row.ObservedAt) > staleAfter {
			return uptimeStateNoData
		}
		if rowVerdicts(row)[comp].state == verdictUp {
			return uptimeStateUp
		}
		return uptimeStateDown
	}
	return uptimeStateNoData
}

// opsUptimeHandler is GET /admin/ops/uptime?days=. DB-backed, so unlike its
// /admin/ops/* siblings it 503s in degraded mode, like /admin/metrics/*.
func opsUptimeHandler(w http.ResponseWriter, r *http.Request) {
	if dbPool == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "database unavailable")
		return
	}
	days := uptimeMaxDays
	if d, err := strconv.Atoi(r.URL.Query().Get("days")); err == nil && d > 0 && d <= uptimeMaxDays {
		days = d
	}
	now := time.Now().UTC()
	// Align the window to UTC midnight so buckets are whole days, exactly like
	// adminTimeseriesHandler.
	startDay := now.Truncate(24*time.Hour).AddDate(0, 0, -(days - 1))

	q := store.New(dbPool)
	rows, err := q.HealthSamplesSince(r.Context(), startDay)
	if err != nil {
		log.Printf("ops uptime: samples query: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "query failed")
		return
	}
	var monitoringSince *string
	if earliest, err := q.EarliestHealthSample(r.Context()); err == nil {
		iso := earliest.UTC().Format(time.RFC3339)
		monitoringSince = &iso
	} else if !errors.Is(err, pgx.ErrNoRows) {
		log.Printf("ops uptime: earliest sample query: %v", err)
		writeJSONError(w, http.StatusInternalServerError, "query failed")
		return
	}

	// Freshness bound for the current-status pill: three tick intervals, read
	// at request time — this is a now-fact about the live sampler, not history,
	// so the env read here cannot re-score any stored day.
	staleAfter := 3 * time.Duration(envInt("HEALTH_TICK_MINUTES", defaultHealthTickMinutes)) * time.Minute

	writeJSON(w, http.StatusOK, rollupUptime(rows, startDay, days, now, monitoringSince, staleAfter))
}
