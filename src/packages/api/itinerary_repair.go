package main

// One-off repair for itineraries corrupted by the pre-guard
// update_itinerary_section splice (see spliceSection in itinerary_section.go).
//
// The old splice kept every item OUTSIDE the targeted section in `out` and then
// spliced the model's replacement list in verbatim. Asked to reorder two cities,
// the model sent both cities' places under a single-city selector, so the
// non-selected city survived in `out` AND arrived again in newLocs —
// replaceTripSection then wrote both copies as real rows. On screen the city
// appeared twice: once with its dates, once collapsed to a zero-night stop
// because the duplicate copy carried the pre-edit `day` numbers.
//
// Run it with `make api-repair-sections` (report only) or
// `make api-repair-sections APPLY=1`. The hub predicate, the run split and the
// "is this fragmented or a real revisit?" call all live in itinerary_runs.go and
// are SHARED with the scope-'trip' write guard, so detection and enforcement
// cannot drift apart.

import (
	"context"
	"flag"
	"fmt"
	"log"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// repairPlan is what a dry run prints and an apply run executes.
type repairPlan struct {
	TripID    uuid.UUID
	DeleteIDs []uuid.UUID
	Before    []string
	After     []string
	Skipped   []string // hub -> why it was left alone
	Tied      bool     // day-order tie: a human should confirm before applying
}

func (p repairPlan) empty() bool { return len(p.DeleteIDs) == 0 }

func describeItem(it store.ItineraryItem) string {
	day := "no day"
	if it.Day != nil {
		day = fmt.Sprintf("day %d", *it.Day)
	}
	hub := hubOfItem(it)
	if hub == "" {
		hub = "no city"
	}
	return fmt.Sprintf("  pos %3d  %-32s (%s, %s)", it.Position, it.Name, hub, day)
}

// planTripRepair decides which duplicate run to collapse, given the shared
// classifier's verdict about which hubs are fragmented at all. Pure: no DB, no
// I/O, so it is unit-testable without Postgres.
//
// The conservatism that keeps a genuine revisit (Paris → Rome → Paris) out of
// this plan lives in classifyHubRuns — see itinerary_runs.go. What is left here
// is repair-only: which of the twin runs is the stale copy, and the refusal
// backstop.
//
// The four-item floor is a repair heuristic, not part of the predicate: a trip
// this small predates the splice bug's reach and is not worth a destructive
// guess. The write-path guard deliberately has no such floor — it rejects rather
// than deletes, so it has nothing to be careful with.
func planTripRepair(items []store.ItineraryItem) repairPlan {
	plan := repairPlan{}
	if len(items) < 4 {
		return plan
	}
	rits := runItemsOfStored(items)
	c := classifyHubRuns(rits)
	plan.Skipped = c.Skipped

	drop := map[int]bool{}
	for _, f := range c.Fragmented {
		// Which copy is stale? Whichever removal leaves the trip's day numbers
		// running forwards. Neither "first" nor "last" is right on its own: the
		// stale copy lands last when the model targeted the other city first,
		// and first when it targeted this one.
		without := func(skip int) []runItem {
			var out []runItem
			for i, r := range c.Runs {
				if i == skip {
					continue
				}
				out = append(out, r.slice(rits)...)
			}
			return out
		}
		va, vb := dayOrderViolations(without(f.A)), dayOrderViolations(without(f.B))
		victim := f.B
		switch {
		case va < vb:
			victim = f.A
		case vb < va:
			victim = f.B
		default:
			plan.Tied = true
		}
		drop[victim] = true
	}

	if len(drop) == 0 {
		return plan
	}

	var kept []store.ItineraryItem
	for i, r := range c.Runs {
		if drop[i] {
			for _, it := range items[r.Start:r.End] {
				plan.DeleteIDs = append(plan.DeleteIDs, it.ID)
			}
			continue
		}
		kept = append(kept, items[r.Start:r.End]...)
	}
	// Backstop, not a live path: two duplicate runs can never exceed half a
	// trip's items, so this cannot fire under today's rules. It exists so that
	// relaxing them later (three-run hubs, partial overlap) can't quietly turn
	// into a destructive repair.
	if len(plan.DeleteIDs)*2 > len(items) {
		return repairPlan{Skipped: append(plan.Skipped,
			fmt.Sprintf("would delete %d of %d items — refusing", len(plan.DeleteIDs), len(items)))}
	}
	for _, it := range items {
		plan.Before = append(plan.Before, describeItem(it))
	}
	for i, it := range kept {
		it.Position = int32(i)
		plan.After = append(plan.After, describeItem(it))
	}
	return plan
}

// applyTripRepair deletes the planned rows and re-densifies positions in ONE
// transaction, under the same row lock replaceTripSection takes so it cannot
// race a live agent rewrite. `day` is deliberately NOT renumbered: this removes
// rows the bug added, it does not re-plan the trip.
func applyTripRepair(ctx context.Context, tripID uuid.UUID, plan repairPlan) error {
	tx, err := dbPool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	q := store.New(tx)

	if _, err := q.GetTripForUpdate(ctx, tripID); err != nil {
		return err
	}
	for _, id := range plan.DeleteIDs {
		n, err := q.DeleteItineraryItem(ctx, store.DeleteItineraryItemParams{ID: id, TripID: tripID})
		if err != nil {
			return err
		}
		if n != 1 {
			return fmt.Errorf("item %s: expected to delete 1 row, deleted %d (trip changed under us)", id, n)
		}
	}
	remaining, err := q.GetItineraryItemsByTrip(ctx, tripID)
	if err != nil {
		return err
	}
	ids := make([]uuid.UUID, len(remaining))
	positions := make([]int32, len(remaining))
	for i, it := range remaining {
		ids[i] = it.ID
		positions[i] = int32(i)
	}
	if len(ids) > 0 {
		if err := q.SetItineraryItemPositionsBatch(ctx, store.SetItineraryItemPositionsBatchParams{
			TripID: tripID, Ids: ids, Positions: positions,
		}); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

// candidateTripIDs prefilters to trips where some hub occupies two or more
// non-contiguous runs. Raw SQL rather than a sqlc query: this is a one-off ops
// subcommand, not part of the served API surface. The filter deliberately
// OVER-matches (a genuine revisit looks identical here) — planTripRepair is what
// separates corruption from a real revisit.
const candidateTripsSQL = `
WITH k AS (
  SELECT trip_id, position,
         LOWER(NULLIF(TRIM(COALESCE(NULLIF(TRIM(day_trip_from), ''), city, '')), '')) AS hub
  FROM itinerary_items
),
marked AS (
  SELECT *, CASE WHEN hub IS DISTINCT FROM LAG(hub) OVER w THEN 1 ELSE 0 END AS new_run
  FROM k WINDOW w AS (PARTITION BY trip_id ORDER BY position)
),
runs AS (
  SELECT *, SUM(new_run) OVER (PARTITION BY trip_id ORDER BY position
                               ROWS UNBOUNDED PRECEDING) AS run_no
  FROM marked
)
SELECT DISTINCT trip_id FROM runs
WHERE hub IS NOT NULL
GROUP BY trip_id, hub
HAVING COUNT(DISTINCT run_no) > 1
`

// runRepairSections is the `repair-sections` subcommand entrypoint. Dry run is
// the DEFAULT: without -apply it prints every plan and writes nothing.
func runRepairSections(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("repair-sections", flag.ContinueOnError)
	apply := fs.Bool("apply", false, "actually delete the duplicate runs (default: report only)")
	only := fs.String("trip", "", "repair just this trip id")
	verbose := fs.Bool("v", false, "print the full before/after itinerary for each plan")
	if err := fs.Parse(args); err != nil {
		return err
	}

	var ids []uuid.UUID
	if *only != "" {
		id, err := uuid.Parse(*only)
		if err != nil {
			return fmt.Errorf("bad -trip id: %w", err)
		}
		ids = append(ids, id)
	} else {
		rows, err := dbPool.Query(ctx, candidateTripsSQL)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var id uuid.UUID
			if err := rows.Scan(&id); err != nil {
				return err
			}
			ids = append(ids, id)
		}
		if err := rows.Err(); err != nil {
			return err
		}
	}

	q := store.New(dbPool)
	var repaired, flagged, skipped int
	for _, id := range ids {
		items, err := q.GetItineraryItemsByTrip(ctx, id)
		if err != nil {
			return err
		}
		plan := planTripRepair(items)
		if plan.empty() {
			if len(plan.Skipped) > 0 {
				skipped++
				log.Printf("trip %s: left alone", id)
				for _, s := range plan.Skipped {
					log.Printf("    %s", s)
				}
			}
			continue
		}
		flagged++
		log.Printf("trip %s: %d duplicate item(s) to delete%s", id, len(plan.DeleteIDs),
			map[bool]string{true: "  [TIED — confirm by hand]"}[plan.Tied])
		if *verbose {
			log.Printf("  before:")
			for _, l := range plan.Before {
				log.Print(l)
			}
			log.Printf("  after:")
			for _, l := range plan.After {
				log.Print(l)
			}
		}
		for _, s := range plan.Skipped {
			log.Printf("    also: %s", s)
		}
		if !*apply {
			continue
		}
		if plan.Tied {
			log.Printf("  SKIPPED by -apply: ambiguous which copy is stale; re-run with -trip %s -v and fix by hand", id)
			continue
		}
		if err := applyTripRepair(ctx, id, plan); err != nil {
			return fmt.Errorf("trip %s: %w", id, err)
		}
		repaired++
		log.Printf("  repaired")
	}

	mode := "dry run — nothing was written (pass -apply to repair)"
	if *apply {
		mode = fmt.Sprintf("%d trip(s) repaired", repaired)
	}
	log.Printf("checked %d candidate trip(s): %d with duplicates, %d left alone; %s",
		len(ids), flagged, skipped, mode)

	return auditTripScopeGuard(ctx, q, *only, *verbose)
}

// auditGuardTripsSQL is the guard audit's own candidate set, and it is
// deliberately NOT candidateTripsSQL. That query prefilters to trips where some
// hub occupies two or more runs, which can only ever answer the fragmentation
// half — a trip whose day numbers run backwards without any repeated hub would
// never be looked at, and the audit's day-monotonicity number would be a
// statement about the prefilter rather than about the data. The guard runs on
// every payload, so the audit scans every trip that has items.
//
// Ordered, unlike candidateTripsSQL, so two runs over an unchanged database
// produce the same report in the same order.
const auditGuardTripsSQL = `
SELECT DISTINCT trip_id FROM itinerary_items ORDER BY trip_id
`

// auditTripScopeGuard answers, for every trip: would these items, resubmitted as
// a scope-'trip' payload, be REJECTED by the guard? It writes nothing and
// changes no verdict above it — its only job is to turn "the guard is probably
// safe on real data" into a number somebody can read.
//
// Reading a stored trip as a payload is exact rather than approximate: an
// itinerary IS what a scope-'trip' payload becomes, and inspectTripScope is
// literally the function the write path calls, reached through the SAME
// classifier via the stored-row reducer (pinned by
// TestStoredAndSubmittedReduceIdentically).
//
// What a reader has to judge, and what the output is shaped to let them judge:
// a flagged trip is either corruption that already happened — these are the
// trips the repair pass above exists for — or a legitimate itinerary the guard
// would wrongly block. Only the second kind invalidates the guard, so every
// finding names its places.
//
// It runs AFTER the repair pass, deliberately: under -apply that means it
// reports the state the database is actually left in, not the state it was
// found in. Under the default dry run the two are the same thing.
func auditTripScopeGuard(ctx context.Context, q *store.Queries, only string, verbose bool) error {
	var ids []uuid.UUID
	if only != "" {
		id, err := uuid.Parse(only)
		if err != nil {
			return fmt.Errorf("bad -trip id: %w", err)
		}
		ids = append(ids, id)
	} else {
		rows, err := dbPool.Query(ctx, auditGuardTripsSQL)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var id uuid.UUID
			if err := rows.Scan(&id); err != nil {
				return err
			}
			ids = append(ids, id)
		}
		if err := rows.Err(); err != nil {
			return err
		}
	}

	var rejected, fragmented, dayBroken int
	for _, id := range ids {
		items, err := q.GetItineraryItemsByTrip(ctx, id)
		if err != nil {
			return err
		}
		v := inspectTripScope(runItemsOfStored(items))
		if v.ok() {
			continue
		}
		rejected++
		log.Printf("trip %s: WOULD BE REJECTED by the scope 'trip' guard", id)
		if len(v.Fragmented) > 0 {
			fragmented++
			log.Printf("    fragmented: %s", describeFragments(v))
		}
		if len(v.Breaks) > 0 {
			dayBroken++
			for i, b := range v.Breaks {
				if i == straySampleCap {
					log.Printf("    day order: and %d more", len(v.Breaks)-i)
					break
				}
				log.Printf("    day order: %s is day %d, after day %d", b.Name, b.Day, b.Prev)
			}
		}
		if verbose {
			for _, it := range items {
				log.Print(describeItem(it))
			}
			for _, s := range v.Skipped {
				log.Printf("    also: %s", s)
			}
		}
	}

	log.Printf("guard audit (report only, nothing written): scanned %d trip(s) with itinerary items — "+
		"%d would be rejected (%d fragmented, %d day-order), %d would pass",
		len(ids), rejected, fragmented, dayBroken, len(ids)-rejected)
	if len(ids) == 0 {
		log.Printf("guard audit: NO TRIPS TO CHECK — this database is empty, so this is not evidence " +
			"that the guard is safe. Point DATABASE_URL at a database with real trips.")
	}
	return nil
}
