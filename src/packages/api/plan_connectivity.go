package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	anthropic "github.com/anthropics/anthropic-sdk-go"
)

// plan_connectivity.go — the check_flight_connectivity agent tool. Before the
// agent recommends a destination or stopover, it compares real flight
// connectivity (cheapest price, fastest duration, nonstop availability) for
// 2-5 candidates in ONE tool call: a bounded concurrent fan-out over offer
// searches (the flightOffersSearch seam — Duffel, or SerpApi while the
// temporary swap is active), reduced to a compact indicative summary. A
// dedicated tool instead of N search_flights calls keeps it to one agent
// iteration, avoids streaming a "flights" card per candidate (the UI has a
// single flight-offers slot), and lets the indicative per-leg results be
// cached briefly — unlike bookable offers, which are never cached.
//
// While the SerpApi swap is active the fan-out is throttled harder: fewer
// candidates and a daily-quota headroom guard, because every uncached leg is
// one search against the 250/month free tier.

const (
	// maxConnectivityCandidates bounds Duffel spend per call; extra candidates
	// are dropped with a note so the model knows.
	maxConnectivityCandidates = 5
	// maxConnectivityCandidatesSerpapi is the tighter clamp while the
	// temporary SerpApi swap is active: 3 candidates (× 2 with an onward leg)
	// = at most 6 uncached searches per call against the small daily cap.
	maxConnectivityCandidatesSerpapi = 3
	// connectivitySerpapiReserve is the slice of the SerpApi daily cap that
	// connectivity must leave untouched: if today's remaining quota can't
	// cover the uncached legs AND this reserve, the tool reports unavailable
	// instead of starving search_flights (whose results are bookable and
	// therefore matter more).
	connectivitySerpapiReserve = 10
	// maxConnectivityCallsPerSession bounds spend per /plan request.
	maxConnectivityCallsPerSession = 3
	// connectivityConcurrency bounds simultaneous Duffel offer requests.
	connectivityConcurrency = 5
	// connectivitySupplierTimeoutMS is passed to Duffel so slow airlines are
	// dropped — indicative results don't need the long tail.
	connectivitySupplierTimeoutMS = 10000
)

// connectivityToolTimeout is the overall deadline for one tool call; legs that
// miss it are reported as unknown rather than failing the comparison. A var so
// tests can shorten it.
var connectivityToolTimeout = 30 * time.Second

// connectivityUnavailableMsg is the friendly non-error the model gets when the
// SerpApi swap is on but connectivity can't run (no key, or no quota headroom)
// — same settle-don't-retry framing as the session-cap message.
const connectivityUnavailableMsg = "Connectivity data is unavailable right now. Recommend based on geography and typical routing, then run search_flights on the chosen destination for real options."

// connectivityCache holds per-leg indicative summaries, keyed
// "ORIG|DEST|YYYY-MM-DD". 45 minutes is fresh enough for "is this route
// sane?" while absorbing repeat checks within and across sessions.
var connectivityCache = newTTLCache[legConnectivity](45*time.Minute, 2000)

// legConnectivity is the indicative summary for one directed leg on a date.
// Mins are taken across the raw offers independently — the cheapest, fastest,
// and fewest-stops offers may be different flights, which is the right framing
// for "how reachable is this place?".
type legConnectivity struct {
	Origin     string
	Dest       string
	Cheapest   float64
	Currency   string
	FastestMin int
	MinStops   int
	OfferCount int // 0 => no service found for that date
}

type connLeg struct {
	origin, dest, date string
}

type connLegResult struct {
	conn     *legConnectivity
	timedOut bool
	err      error
}

var checkFlightConnectivityTool = anthropic.ToolParam{
	Name: "check_flight_connectivity",
	Description: anthropic.String("Compare flight connectivity for several CANDIDATE destinations before recommending one — cheapest price, fastest duration, and whether nonstops exist, for origin→candidate and optionally candidate→onward legs. " +
		"Use this whenever you are about to suggest a destination or stopover the traveler didn't ask for by name, and when the traveler proposes a stopover themselves, so you never present a 20-hour or $4,000 route as convenient. " +
		"Results are indicative, not bookable offers — use search_flights afterwards for real options on the chosen place. " +
		"If the traveler has no fixed dates, pick a representative weekday about 4-8 weeks out (or mid-month of the month they mentioned) — the comparison matters more than the exact date."),
	InputSchema: anthropic.ToolInputSchemaParam{
		Properties: map[string]any{
			"origin": map[string]any{
				"type":        "string",
				"description": "Where the traveler starts this leg — city name or IATA code",
			},
			"candidates": map[string]any{
				"type":        "array",
				"items":       map[string]any{"type": "string"},
				"minItems":    2,
				"maxItems":    maxConnectivityCandidates,
				"description": "2-5 candidate destinations/stopovers to compare, city names or IATA codes",
			},
			"depart_date": map[string]any{
				"type":        "string",
				"description": "YYYY-MM-DD; a representative date is fine when dates aren't fixed",
			},
			"onward_destination": map[string]any{
				"type":        "string",
				"description": "Optional final destination — also checks each candidate→onward leg (e.g. stopover candidates between origin and here)",
			},
		},
		Required: []string{"origin", "candidates", "depart_date"},
	},
}

func runCheckFlightConnectivityTool(s *planSession, input json.RawMessage) (string, bool) {
	var in struct {
		Origin            string   `json:"origin"`
		Candidates        []string `json:"candidates"`
		DepartDate        string   `json:"depart_date"`
		OnwardDestination string   `json:"onward_destination"`
	}
	json.Unmarshal(input, &in)

	// While the temporary offers provider is active, per-leg searches ride the
	// flightOffersSearch seam to SerpApi (Duffel's test token would return
	// synthetic data — worse than none). Without a key there is nothing to
	// call; a tighter candidate clamp and a quota headroom check (below, once
	// the leg set is known) keep the fan-out from draining the daily cap.
	if serpapiFlights.Active() && !serpapiFlights.Configured() {
		return connectivityUnavailableMsg, false
	}

	s.connectivityCalls++
	if s.connectivityCalls > maxConnectivityCallsPerSession {
		// Friendly non-error text so the model settles instead of retrying.
		return "Connectivity check limit reached for this session — decide using the results you already have.", false
	}
	if strings.TrimSpace(in.Origin) == "" || len(in.Candidates) == 0 {
		return "check_flight_connectivity needs an origin and at least one candidate destination.", true
	}

	maxCandidates := maxConnectivityCandidates
	if serpapiFlights.Active() {
		maxCandidates = maxConnectivityCandidatesSerpapi
	}
	truncated := false
	if len(in.Candidates) > maxCandidates {
		in.Candidates = in.Candidates[:maxCandidates]
		truncated = true
	}

	originIata := resolveIATA(s.ctx, in.Origin)
	if originIata == "" {
		return fmt.Sprintf("Could not resolve %q to an airport. Ask the traveler to clarify the origin city or airport.", in.Origin), true
	}
	onwardIata := ""
	if strings.TrimSpace(in.OnwardDestination) != "" {
		onwardIata = resolveIATA(s.ctx, in.OnwardDestination)
	}

	// Resolve candidates, keeping unresolvable ones as rows so the model can
	// tell the traveler instead of silently dropping a place.
	type candidate struct {
		name string
		iata string // "" => unresolvable
	}
	candidates := make([]candidate, 0, len(in.Candidates))
	legSet := map[connLeg]bool{}
	for _, name := range in.Candidates {
		c := candidate{name: name, iata: resolveIATA(s.ctx, name)}
		candidates = append(candidates, c)
		if c.iata == "" || c.iata == originIata || c.iata == onwardIata {
			continue
		}
		legSet[connLeg{originIata, c.iata, in.DepartDate}] = true
		if onwardIata != "" {
			legSet[connLeg{c.iata, onwardIata, in.DepartDate}] = true
		}
	}
	legs := make([]connLeg, 0, len(legSet))
	for l := range legSet {
		legs = append(legs, l)
	}

	// Quota headroom guard while the swap is active: cached legs are free, but
	// every uncached one is an upstream SerpApi search. If today's remaining
	// quota can't cover them plus the reserve, bail out before spending
	// anything rather than burning searches search_flights will need.
	if serpapiFlights.Active() {
		uncached := 0
		for _, l := range legs {
			if _, ok := connectivityCache.get(legCacheKey(l)); !ok {
				uncached++
			}
		}
		if uncached > 0 && serpapiFlights.RemainingToday() < uncached+connectivitySerpapiReserve {
			return connectivityUnavailableMsg, false
		}
	}

	ctx, cancel := context.WithTimeout(s.ctx, connectivityToolTimeout)
	defer cancel()
	results := fetchConnectivity(ctx, legs)

	// Render one numbered line per candidate; header + closing instruction
	// mirror summarizeOffers so the model treats it the same way.
	var b strings.Builder
	header := fmt.Sprintf("Connectivity check from %s on %s (indicative, one-way economy, per adult):\n", originIata, in.DepartDate)
	b.WriteString(header)
	anyChecked := false
	for i, c := range candidates {
		if c.iata == "" {
			fmt.Fprintf(&b, "%d. Could not resolve %q to an airport.\n", i+1, c.name)
			continue
		}
		if c.iata == originIata || c.iata == onwardIata {
			fmt.Fprintf(&b, "%d. %s (%s): same airport as the origin or onward destination — no flight needed.\n", i+1, c.name, c.iata)
			continue
		}
		line := formatLegConnectivity(results[connLeg{originIata, c.iata, in.DepartDate}], originIata, c.iata)
		if onwardIata != "" {
			line += "; " + formatLegConnectivity(results[connLeg{c.iata, onwardIata, in.DepartDate}], c.iata, onwardIata)
		}
		fmt.Fprintf(&b, "%d. %s (%s): %s\n", i+1, c.name, c.iata, line)
		anyChecked = true
	}
	if truncated {
		fmt.Fprintf(&b, "(Only the first %d candidates were checked.)\n", maxCandidates)
	}
	if in.OnwardDestination != "" && onwardIata == "" {
		fmt.Fprintf(&b, "Could not resolve onward destination %q to an airport, so candidate→onward legs were skipped.\n", in.OnwardDestination)
	}
	b.WriteString("Prefer well-connected candidates. If you still recommend a poorly connected or unknown one, tell the traveler the tradeoff plainly (typical price and total travel time). These are indicative numbers — run search_flights on the chosen destination for real options.")

	// Only a fully useless result is an error: every leg failed or nothing
	// was checkable at all.
	if !anyChecked {
		return b.String(), true
	}
	allFailed := len(legs) > 0
	for _, l := range legs {
		if r := results[l]; r.conn != nil {
			allFailed = false
			break
		}
	}
	return b.String(), allFailed
}

// fetchConnectivity runs the deduped legs through the flightOffersSearch seam
// (Duffel, or SerpApi while the swap is active) with bounded concurrency,
// consulting the per-leg cache first. Legs cut off by ctx are marked timedOut.
// Workers never touch the SSE writer.
func fetchConnectivity(ctx context.Context, legs []connLeg) map[connLeg]connLegResult {
	results := make(map[connLeg]connLegResult, len(legs))
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, connectivityConcurrency)

	for _, leg := range legs {
		if conn, ok := connectivityCache.get(legCacheKey(leg)); ok {
			c := conn
			mu.Lock()
			results[leg] = connLegResult{conn: &c}
			mu.Unlock()
			continue
		}
		wg.Add(1)
		leg := leg
		safeGo("connectivity leg lookup", func() {
			defer wg.Done()
			select {
			case sem <- struct{}{}:
				defer func() { <-sem }()
			case <-ctx.Done():
				mu.Lock()
				results[leg] = connLegResult{timedOut: true}
				mu.Unlock()
				return
			}
			offers, err := flightOffersSearch(ctx, duffelService, FlightSearchRequest{
				Origin: leg.origin, Destination: leg.dest, DepartDate: leg.date,
				Adults: 1, SupplierTimeoutMS: connectivitySupplierTimeoutMS,
			})
			var res connLegResult
			switch {
			case err != nil && ctx.Err() != nil:
				res = connLegResult{timedOut: true}
			case err != nil:
				res = connLegResult{err: err}
			default:
				conn := connectivityFromOffers(leg.origin, leg.dest, offers)
				connectivityCache.set(legCacheKey(leg), conn)
				res = connLegResult{conn: &conn}
			}
			mu.Lock()
			results[leg] = res
			mu.Unlock()
		})
	}
	wg.Wait()
	return results
}

func legCacheKey(l connLeg) string {
	return strings.ToUpper(l.origin) + "|" + strings.ToUpper(l.dest) + "|" + l.date
}

// connectivityFromOffers reduces raw offers to the indicative per-leg summary.
func connectivityFromOffers(origin, dest string, offers []FlightOffer) legConnectivity {
	conn := legConnectivity{Origin: origin, Dest: dest, OfferCount: len(offers)}
	for i, o := range offers {
		if i == 0 || o.Price < conn.Cheapest {
			conn.Cheapest = o.Price
			conn.Currency = o.Currency
		}
		if i == 0 || o.DurationMin < conn.FastestMin {
			conn.FastestMin = o.DurationMin
		}
		if i == 0 || o.Stops < conn.MinStops {
			conn.MinStops = o.Stops
		}
	}
	return conn
}

// formatLegConnectivity renders one leg of a candidate line.
func formatLegConnectivity(res connLegResult, origin, dest string) string {
	route := origin + "→" + dest
	switch {
	case res.timedOut:
		return route + " — timed out, connectivity unknown"
	case res.err != nil:
		return route + " — lookup failed, connectivity unknown"
	case res.conn == nil:
		return route + " — not checked"
	case res.conn.OfferCount == 0:
		return route + " — no flights found for this date (poorly connected or no service)"
	}
	c := res.conn
	stops := "nonstop available"
	if c.MinStops == 1 {
		stops = "min 1 stop (no nonstop)"
	} else if c.MinStops > 1 {
		stops = fmt.Sprintf("min %d stops (no nonstop)", c.MinStops)
	}
	return fmt.Sprintf("%s — from %s %.0f, fastest %dh%02dm, %s",
		route, c.Currency, c.Cheapest, c.FastestMin/60, c.FastestMin%60, stops)
}
