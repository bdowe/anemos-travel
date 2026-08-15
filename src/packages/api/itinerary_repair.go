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
// `make api-repair-sections APPLY=1`. Reuses the same hub predicate as the guard
// (sameHub/keyOfItem), so detection and enforcement cannot drift apart.

import (
	"context"
	"flag"
	"fmt"
	"log"
	"sort"
	"strings"

	"github.com/google/uuid"

	"travel-route-planner/store"
)

// hubRun is one contiguous same-hub stretch in position order — the same
// grouping computeTripLegs renders a leg from.
type hubRun struct {
	Hub   string
	Items []store.ItineraryItem
}

func hubRuns(items []store.ItineraryItem) []hubRun {
	var runs []hubRun
	for _, it := range items {
		hub := hubOfItem(it)
		if len(runs) == 0 || !sameHub(runs[len(runs)-1].Hub, hub) {
			runs = append(runs, hubRun{Hub: hub})
		}
		runs[len(runs)-1].Items = append(runs[len(runs)-1].Items, it)
	}
	return runs
}

// itemIdentity is what a verbatim splice copy preserves byte-for-byte. `day` is
// deliberately EXCLUDED: the duplicate's stale day is the whole reason the two
// copies differ, so keying on it would hide exactly the pairs we're looking for.
// Position is excluded for the same reason.
type itemIdentity struct {
	Name, PlaceID, City, DayTripFrom string
	LatE5, LngE5                     int64
}

func identityOf(it store.ItineraryItem) itemIdentity {
	deref := func(p *string) string {
		if p == nil {
			return ""
		}
		return strings.ToLower(foldHub(*p))
	}
	return itemIdentity{
		Name:        strings.ToLower(foldHub(it.Name)),
		PlaceID:     deref(it.PlaceID),
		City:        deref(it.City),
		DayTripFrom: deref(it.DayTripFrom),
		LatE5:       int64(it.Latitude * 1e5),
		LngE5:       int64(it.Longitude * 1e5),
	}
}

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

// dayOrderViolations counts adjacent pairs (in position order) whose day numbers
// run backwards. The splice bug leaves the stale copy's days out of order with
// everything around it, so removing the stale run drops this count while
// removing the fresh one does not.
func dayOrderViolations(items []store.ItineraryItem) int {
	n := 0
	var prev *int32
	for _, it := range items {
		if it.Day == nil {
			continue
		}
		if prev != nil && *it.Day < *prev {
			n++
		}
		d := *it.Day
		prev = &d
	}
	return n
}

func identityCounts(items []store.ItineraryItem) map[itemIdentity]int {
	m := make(map[itemIdentity]int, len(items))
	for _, it := range items {
		m[identityOf(it)]++
	}
	return m
}

// subsetOf reports whether every identity in a appears in b at least as often.
func subsetOf(a, b map[itemIdentity]int) bool {
	for k, n := range a {
		if b[k] < n {
			return false
		}
	}
	return true
}

func dayRange(items []store.ItineraryItem) (lo, hi int32, ok bool) {
	for _, it := range items {
		if it.Day == nil {
			continue
		}
		if !ok || *it.Day < lo {
			lo = *it.Day
		}
		if !ok || *it.Day > hi {
			hi = *it.Day
		}
		ok = true
	}
	return lo, hi, ok
}

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

// planTripRepair classifies a trip's hub runs and returns what collapsing the
// duplicates would delete. Pure: no DB, no I/O, so it is unit-testable without
// Postgres.
//
// It is deliberately conservative. A hub occupying two runs is NOT by itself
// corruption — computeTripLegs supports genuine revisits (Paris → Rome → Paris),
// and those must be left alone. A run is only dropped when it is also a content
// duplicate of its twin AND the two disagree about dates.
func planTripRepair(items []store.ItineraryItem) repairPlan {
	plan := repairPlan{}
	if len(items) < 4 {
		return plan
	}
	runs := hubRuns(items)

	byHub := map[string][]int{}
	var order []string
	for i, r := range runs {
		if strings.TrimSpace(r.Hub) == "" {
			continue // hubless runs group together by a different rule; skip
		}
		k := strings.ToLower(foldHub(r.Hub))
		if _, seen := byHub[k]; !seen {
			order = append(order, k)
		}
		byHub[k] = append(byHub[k], i)
	}
	sort.Strings(order)

	drop := map[int]bool{}
	for _, k := range order {
		idx := byHub[k]
		if len(idx) < 2 {
			continue
		}
		hub := runs[idx[0]].Hub
		if len(idx) > 2 {
			plan.Skipped = append(plan.Skipped,
				fmt.Sprintf("%s: %d runs — too many to classify automatically", hub, len(idx)))
			continue
		}
		a, b := runs[idx[0]], runs[idx[1]]
		ca, cb := identityCounts(a.Items), identityCounts(b.Items)
		if !subsetOf(ca, cb) && !subsetOf(cb, ca) {
			plan.Skipped = append(plan.Skipped,
				fmt.Sprintf("%s: two runs hold different places — looks like a real revisit", hub))
			continue
		}
		aLo, aHi, aOK := dayRange(a.Items)
		bLo, bHi, bOK := dayRange(b.Items)
		if aOK && bOK && aLo == bLo && aHi == bHi {
			plan.Skipped = append(plan.Skipped,
				fmt.Sprintf("%s: duplicate runs share the same days — not the splice bug", hub))
			continue
		}

		// Which copy is stale? Whichever removal leaves the trip's day numbers
		// running forwards. Neither "first" nor "last" is right on its own: the
		// stale copy lands last when the model targeted the other city first,
		// and first when it targeted this one.
		without := func(skip int) []store.ItineraryItem {
			var out []store.ItineraryItem
			for i, r := range runs {
				if i == skip {
					continue
				}
				out = append(out, r.Items...)
			}
			return out
		}
		va, vb := dayOrderViolations(without(idx[0])), dayOrderViolations(without(idx[1]))
		victim := idx[1]
		switch {
		case va < vb:
			victim = idx[0]
		case vb < va:
			victim = idx[1]
		default:
			plan.Tied = true
		}
		drop[victim] = true
	}

	if len(drop) == 0 {
		return plan
	}

	var kept []store.ItineraryItem
	for i, r := range runs {
		if drop[i] {
			for _, it := range r.Items {
				plan.DeleteIDs = append(plan.DeleteIDs, it.ID)
			}
			continue
		}
		kept = append(kept, r.Items...)
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
	return nil
}
