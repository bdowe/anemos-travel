package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

// Price-alert checker (specs/price-alerts): an in-process ticker that
// re-searches watched routes via Duffel and emails owners on a real drop.
// Single-process by design — if the API ever runs multi-instance, add
// FOR UPDATE SKIP LOCKED to ListDuePriceAlerts.

const (
	// minDropFraction/minDropAbs absorb Duffel offer-to-offer noise in
	// any-drop mode: a "drop" must be at least 5% AND $5 below the baseline.
	minDropFraction = 0.05
	minDropAbs      = 5.0
	// notifyEpsilon: a further drop must beat the last notified price by at
	// least this much to re-notify (target mode).
	notifyEpsilon = 1.0

	defaultAlertTickMinutes = 5
	defaultAlertCheckHours  = 6
	alertBatchSize          = 25
	alertPerCallGap         = time.Second
)

type alertChecker struct {
	duffel     *DuffelService
	interval   time.Duration // ticker period
	checkEvery time.Duration // per-alert freshness window
	batchSize  int
	perCallGap time.Duration
}

// startAlertChecker launches the background loop. No-ops (with a log line)
// when persistence or the flight provider is unavailable; alert CRUD still
// works and checking resumes on next boot once configured.
func startAlertChecker(ctx context.Context) {
	if dbPool == nil {
		log.Printf("price alerts: checker disabled (no database)")
		return
	}
	if duffelService.Token == "" {
		log.Printf("price alerts: checker disabled (DUFFEL_ACCESS_TOKEN not set)")
		return
	}
	c := &alertChecker{
		duffel:     duffelService,
		interval:   time.Duration(envInt("ALERT_TICK_MINUTES", defaultAlertTickMinutes)) * time.Minute,
		checkEvery: time.Duration(envInt("ALERT_CHECK_HOURS", defaultAlertCheckHours)) * time.Hour,
		batchSize:  alertBatchSize,
		perCallGap: alertPerCallGap,
	}
	go c.run(ctx)
	log.Printf("price alerts: checker started (tick %s, per-alert freshness %s)", c.interval, c.checkEvery)
}

func envInt(name string, fallback int) int {
	if v, err := strconv.Atoi(os.Getenv(name)); err == nil && v > 0 {
		return v
	}
	return fallback
}

func (c *alertChecker) run(ctx context.Context) {
	// Jitter the first tick so restarts don't synchronize a burst of Duffel
	// searches.
	select {
	case <-ctx.Done():
		return
	case <-time.After(time.Duration(rand.Int63n(int64(c.interval)))):
	}
	ticker := time.NewTicker(c.interval)
	defer ticker.Stop()
	for {
		// Guard each tick: a panic in one cycle must not kill the ticker (and
		// with it the whole process). Log-and-continue to the next tick.
		safeRun("price alert checker tick", func() { c.runOnce(ctx) })
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

// runOnce performs one checking cycle. Exported-in-spirit: the testable unit.
func (c *alertChecker) runOnce(ctx context.Context) {
	q := store.New(dbPool)

	if n, err := q.ExpirePastPriceAlerts(ctx); err != nil {
		log.Printf("price alerts: expire pass failed: %v", err)
	} else if n > 0 {
		log.Printf("price alerts: expired %d past alerts", n)
	}

	cutoff := time.Now().Add(-c.checkEvery)
	due, err := q.ListDuePriceAlerts(ctx, store.ListDuePriceAlertsParams{
		LastCheckedAt: pgTimestamptz(cutoff),
		Limit:         int32(c.batchSize),
	})
	if err != nil {
		log.Printf("price alerts: could not list due alerts: %v", err)
		return
	}
	if len(due) == 0 {
		return
	}

	// Fan every due alert out to its departure window and dedupe into distinct
	// dated searches. A flexible alert (flex_days>0) yields 2N+1 candidate
	// dates; candidates that land on the same route+date collapse to one
	// search across all alerts — an exact Jul-15 watch and a ±1 Jul-14..16
	// watch share the Jul-15 call, exactly as identical exact watches did.
	today := time.Now()
	searches := map[string]FlightSearchRequest{}
	var searchOrder []string
	alertCandidates := map[uuid.UUID][]flexCandidate{}
	for _, row := range due {
		cands := flexCandidates(row.PriceAlert, today)
		alertCandidates[row.PriceAlert.ID] = cands
		for _, cand := range cands {
			if _, seen := searches[cand.key]; !seen {
				searches[cand.key] = cand.req
				searchOrder = append(searchOrder, cand.key)
			}
		}
	}

	// Issue at most batchSize distinct provider searches this cycle: the cost
	// budget bounds Duffel calls, not alert rows, so a wide flexible window
	// consumes more of the per-cycle budget rather than a bigger one. Searches
	// beyond the cap are deferred — their alerts stay un-checked and lead the
	// due queue (oldest-checked first) on the next cycle.
	results := map[string]FlightOffer{}
	attempted := map[string]bool{}
	issued := 0
	for _, key := range searchOrder {
		if issued >= c.batchSize {
			break
		}
		if ctx.Err() != nil {
			return
		}
		if issued > 0 {
			time.Sleep(c.perCallGap)
		}
		issued++
		attempted[key] = true
		offers, err := searchFlightsWithBaggage(ctx, c.duffel, searches[key])
		if err != nil {
			log.Printf("price alerts: search %s failed: %v", key, err)
			continue
		}
		if lowest, ok := lowestOffer(offers); ok {
			results[key] = lowest
		} else {
			log.Printf("price alerts: search %s returned no offers", key)
		}
	}

	// Settle each alert against the cheapest priced date across its window.
	for _, row := range due {
		if ctx.Err() != nil {
			return
		}
		best, matched, covered, complete := cheapestCandidate(alertCandidates[row.PriceAlert.ID], results, attempted)
		switch {
		case !complete:
			// Part of the window was budget-deferred this cycle — leave the
			// alert un-checked so its full window is priced together next time.
			continue
		case !covered:
			// Every candidate was attempted but none returned a usable price
			// (provider error / empty / cross-currency): advance the timestamp
			// so a broken route rotates to the back instead of retrying every
			// tick and starving the batch.
			c.touch(ctx, q, []store.ListDuePriceAlertsRow{row})
		default:
			c.settle(ctx, q, row, best, matched)
		}
	}
}

// flexCandidate is one dated Duffel search a (possibly flexible) alert expands
// to for a cycle: the request, its cross-alert dedupe key, and the departure
// date it prices.
type flexCandidate struct {
	date time.Time
	req  FlightSearchRequest
	key  string
}

// flexCandidates expands an alert into the distinct dated searches for its
// departure window [depart-flex_days, depart+flex_days]. Past candidates
// (before today) are skipped — never search a departure that has already
// gone — as are candidates that would depart after a fixed return date.
// flex_days=0 yields exactly the single exact-date search (unchanged).
func flexCandidates(a store.PriceAlert, today time.Time) []flexCandidate {
	flex := int(a.FlexDays)
	if flex < 0 {
		flex = 0
	}
	todayStr := today.Format(dateLayout)
	ret := dateString(a.ReturnDate)
	out := make([]flexCandidate, 0, 2*flex+1)
	for d := -flex; d <= flex; d++ {
		dep := a.DepartDate.Time.AddDate(0, 0, d)
		depStr := dep.Format(dateLayout)
		if depStr < todayStr {
			continue
		}
		if ret != "" && depStr > ret {
			continue
		}
		req := FlightSearchRequest{
			Origin: a.Origin, Destination: a.Destination,
			DepartDate: depStr, ReturnDate: ret,
			Adults: int(a.Adults), CabinClass: a.CabinClass,
			Baggage: a.Baggage,
		}
		out = append(out, flexCandidate{date: dep, req: req, key: flexSearchKey(req)})
	}
	return out
}

// cheapestCandidate picks the lowest-priced date across an alert's window from
// the cycle's search results. complete is false when any candidate was not
// attempted (budget-deferred), signalling the alert should be re-checked later
// with its full window intact; covered is false when the window was fully
// attempted but nothing priced (all failed/empty).
func cheapestCandidate(cands []flexCandidate, results map[string]FlightOffer, attempted map[string]bool) (best FlightOffer, matched pgtype.Date, covered, complete bool) {
	complete = true
	for _, cand := range cands {
		if !attempted[cand.key] {
			complete = false
			continue
		}
		offer, ok := results[cand.key]
		if !ok {
			continue
		}
		if !covered || scoringPrice(offer) < scoringPrice(best) {
			best = offer
			matched = pgtype.Date{Time: cand.date, Valid: true}
			covered = true
		}
	}
	return best, matched, covered, complete
}

func (c *alertChecker) touch(ctx context.Context, q *store.Queries, rows []store.ListDuePriceAlertsRow) {
	ids := make([]uuid.UUID, 0, len(rows))
	for _, row := range rows {
		ids = append(ids, row.PriceAlert.ID)
	}
	if err := q.TouchPriceAlerts(ctx, ids); err != nil {
		log.Printf("price alerts: touch failed: %v", err)
	}
}

// settle applies one search result to one alert: record the check, and
// notify if the trigger condition is met. MarkPriceAlertNotified runs BEFORE
// the send so a crashed/retried send can never double-notify.
func (c *alertChecker) settle(ctx context.Context, q *store.Queries, row store.ListDuePriceAlertsRow, lowest FlightOffer, matched pgtype.Date) {
	a := row.PriceAlert
	// A cross-currency offer is unusable: never write its price into the row
	// (it would display under the wrong currency label and poison the
	// baseline) — just advance the timestamp.
	if a.Currency != nil && *a.Currency != "" && *a.Currency != lowest.Currency {
		c.touch(ctx, q, []store.ListDuePriceAlertsRow{row})
		return
	}
	// Every recorded/compared price is the EFFECTIVE price (fare + bag fee)
	// on baggage-aware alerts; scoringPrice is the bare fare otherwise.
	effective := scoringPrice(lowest)
	notify := evaluateAlert(a, effective, lowest.Currency)

	if err := q.MarkPriceAlertChecked(ctx, store.MarkPriceAlertCheckedParams{
		ID: a.ID, LastCheckedPrice: &effective, Currency: &lowest.Currency,
	}); err != nil {
		log.Printf("price alerts: mark checked %s: %v", a.ID, err)
		return
	}
	if !notify {
		return
	}
	if err := q.MarkPriceAlertNotified(ctx, store.MarkPriceAlertNotifiedParams{
		ID: a.ID, LastNotifiedPrice: &effective,
	}); err != nil {
		log.Printf("price alerts: mark notified %s: %v", a.ID, err)
		return
	}
	// Persist the in-app notification (Wave 16) inside the same idempotent block
	// that marked the alert notified, with the same values the email gets.
	// Best-effort like the email: a failed insert logs and never blocks the
	// check loop. This is the CUTOVER writer — the generalized `notifications`
	// feed replaced alert_events as the notification-center spine (the migration
	// backfilled history), so the checker no longer writes alert_events; the old
	// table/endpoints remain intact but dormant.
	// matched_departure_date names the winning date only for flexible alerts;
	// for an exact watch it always equals depart_date, so it stays NULL.
	matchedParam := matched
	if a.FlexDays == 0 {
		matchedParam = pgtype.Date{}
	}
	payload := priceDropPayload(a, effective, lowest.Currency, alertReferencePrice(a), matchedParam)
	if _, err := q.InsertNotification(ctx, store.InsertNotificationParams{
		UserID:  a.UserID,
		Type:    "price_drop",
		Payload: payload,
		TripID:  a.TripID,
	}); err != nil {
		log.Printf("price alerts: insert notification %s: %v", a.ID, err)
	}
	// Background tick, no request to negotiate from: the owner's stored language
	// rides along on the due-alert row.
	locale := localeOrDefault(row.OwnerLocale)
	safeGo("sendAlertEmail", func() { sendAlertEmail(locale, row.OwnerEmail, a, lowest, matchedParam) })
	tripID := tripIDPtr(a)
	safeGo("recordEvent", func() {
		recordEvent(a.UserID, "alert_triggered", tripID, map[string]any{
			"origin": a.Origin, "destination": a.Destination,
			"price": effective, "currency": lowest.Currency,
			"target_price": a.TargetPrice,
		})
	})
}

// alertReferencePrice returns the price a triggered drop was judged against —
// the same fixed reference evaluateAlert uses: the last notified price, else
// the creation/first-check baseline. Nil when a target-mode alert triggers on
// its very first observation (no seed, nothing checked yet). Must be called
// with the pre-settle alert row, before MarkPriceAlertChecked/Notified.
func alertReferencePrice(a store.PriceAlert) *float64 {
	if a.LastNotifiedPrice != nil {
		return a.LastNotifiedPrice
	}
	return a.BaselinePrice
}

// evaluateAlert decides whether the freshly observed lowest price should
// notify the owner. Pure — the unit-test target. Callers must have already
// excluded cross-currency offers (settle touches those without recording).
func evaluateAlert(a store.PriceAlert, lowestPrice float64, lowestCurrency string) bool {
	if a.Currency != nil && *a.Currency != "" && *a.Currency != lowestCurrency {
		return false
	}
	// Idempotency: only a real further drop below the last notified price
	// can notify again.
	if a.LastNotifiedPrice != nil && lowestPrice > *a.LastNotifiedPrice-notifyEpsilon {
		return false
	}
	if a.TargetPrice != nil {
		return lowestPrice <= *a.TargetPrice
	}
	// Any-drop compares against a FIXED reference — the last notified price,
	// else the creation/first-check baseline — never the rolling last check,
	// so slow cumulative declines accumulate toward the threshold and a
	// spike-then-revert can't notify above what the user was watching.
	ref := a.BaselinePrice
	if a.LastNotifiedPrice != nil {
		ref = a.LastNotifiedPrice
	}
	if ref == nil {
		// First check: record the baseline only.
		return false
	}
	return lowestPrice <= *ref-minDropAbs && lowestPrice <= *ref*(1-minDropFraction)
}

// flexSearchKey collapses candidate dates that would issue an identical Duffel
// search into one call. Deliberately excludes flex_days: two alerts that price
// the same route+date+cabin share the call regardless of how wide each one's
// window is, so cross-alert dedupe still works across mixed flexibilities.
func flexSearchKey(req FlightSearchRequest) string {
	return strings.Join([]string{
		req.Origin, req.Destination, req.DepartDate, req.ReturnDate,
		req.CabinClass, strconv.Itoa(req.Adults), normalizeBaggage(req.Baggage),
	}, "|")
}

// lowestOffer returns the cheapest offer of a search, by effective price on
// baggage-aware searches. Offers whose bag fee is unknown are skipped there —
// an unpriceable fare is not a comparable "lowest price" and would understate
// what the traveler pays. All-unknown behaves like an empty search (not ok).
func lowestOffer(offers []FlightOffer) (FlightOffer, bool) {
	var best FlightOffer
	found := false
	for _, o := range offers {
		if o.BaggageStatus == baggageStatusUnknown {
			continue
		}
		if !found || scoringPrice(o) < scoringPrice(best) {
			best = o
			found = true
		}
	}
	return best, found
}

// buildAlertEmail renders the notification in the recipient's language.
// Pure — unit-tested.
func buildAlertEmail(locale string, a store.PriceAlert, lowest FlightOffer, matched pgtype.Date) (subject, body string) {
	route := fmt.Sprintf("%s → %s", a.Origin, a.Destination)
	price := fmt.Sprintf("%s %.0f", lowest.Currency, scoringPrice(lowest))
	if a.TargetPrice != nil {
		subject = tr(locale, "email.alert.subject_target", route, price)
	} else {
		subject = tr(locale, "email.alert.subject_drop", route, price)
	}

	var b strings.Builder
	fmt.Fprintf(&b, "%s\n\n", tr(locale, "email.alert.lead"))
	fmt.Fprintf(&b, "%s\n", tr(locale, "email.alert.route", route))
	// For a flexible watch the cheapest date in the window may differ from the
	// nominal departure; name it so the traveler books the right day.
	if a.FlexDays > 0 && matched.Valid {
		fmt.Fprintf(&b, "%s\n", tr(locale, "email.alert.departing_flex", dateString(matched), a.FlexDays))
	} else {
		fmt.Fprintf(&b, "%s\n", tr(locale, "email.alert.departing", dateString(a.DepartDate)))
	}
	if ret := dateString(a.ReturnDate); ret != "" {
		fmt.Fprintf(&b, "%s\n", tr(locale, "email.alert.returning", ret))
	}
	fmt.Fprintf(&b, "%s\n", tr(locale, "email.alert.cabin", a.CabinClass, a.Adults))
	switch a.Baggage {
	case baggageCarryOn:
		fmt.Fprintf(&b, "%s\n", tr(locale, "email.alert.bag_carry_on"))
	case baggageChecked:
		fmt.Fprintf(&b, "%s\n", tr(locale, "email.alert.bag_checked"))
	}
	fmt.Fprintf(&b, "\n%s", tr(locale, "email.alert.best_price", price))
	if len(lowest.Airlines) > 0 {
		fmt.Fprintf(&b, " %s", tr(locale, "email.alert.on_airlines", strings.Join(lowest.Airlines, "/")))
	}
	b.WriteString("\n")
	if a.TargetPrice != nil {
		fmt.Fprintf(&b, "%s\n", tr(locale, "email.alert.your_target", lowest.Currency, *a.TargetPrice))
	} else if a.LastCheckedPrice != nil {
		fmt.Fprintf(&b, "%s\n", tr(locale, "email.alert.previously", lowest.Currency, *a.LastCheckedPrice))
	}
	fmt.Fprintf(&b, "\n%s\n", tr(locale, "email.alert.book", publicAppURL("alerts")))
	fmt.Fprintf(&b, "\n%s\n", tr(locale, "email.alert.footer"))
	return subject, b.String()
}

func sendAlertEmail(locale, to string, a store.PriceAlert, lowest FlightOffer, matched pgtype.Date) {
	subject, body := buildAlertEmail(locale, a, lowest, matched)
	if err := emailService.Send(to, subject, body); err != nil {
		log.Printf("price alerts: email to %s failed: %v", maskEmail(to), err)
	}
}

// --- small conversion helpers ---

// dateString renders a pgtype.Date as YYYY-MM-DD, "" when unset.
func dateString(d pgtype.Date) string {
	if !d.Valid {
		return ""
	}
	return d.Time.Format(dateLayout)
}

func pgTimestamptz(t time.Time) pgtype.Timestamptz {
	return pgtype.Timestamptz{Time: t, Valid: true}
}

// priceDropPayload builds the `notifications.payload` JSON for a triggered
// price-drop. The key set matches the migration backfill exactly (same fields
// ListAlertEventsByUser used to join in), so a live-written notification and a
// backfilled one render identically in the client's price_drop tile. Absent
// values are JSON null (not omitted), mirroring jsonb_build_object.
func priceDropPayload(a store.PriceAlert, price float64, currency string, previous *float64, matched pgtype.Date) []byte {
	m := map[string]any{
		"alert_id":       a.ID.String(),
		"price":          price,
		"currency":       currency,
		"previous_price": previous,
		"origin":         a.Origin,
		"destination":    a.Destination,
		"depart_date":    dateString(a.DepartDate),
		"return_date":    nil,
		"matched_date":   nil,
		"target_price":   a.TargetPrice,
		"alert_status":   a.Status,
	}
	if ret := dateString(a.ReturnDate); ret != "" {
		m["return_date"] = ret
	}
	if matched.Valid {
		m["matched_date"] = dateString(matched)
	}
	b, err := json.Marshal(m)
	if err != nil {
		// A map of scalars/strings cannot fail to marshal; fall back to an empty
		// object rather than dropping the notification.
		return []byte(`{}`)
	}
	return b
}

func tripIDPtr(a store.PriceAlert) *uuid.UUID {
	if !a.TripID.Valid {
		return nil
	}
	id := uuid.UUID(a.TripID.Bytes)
	return &id
}
