package main

// Scoring the arc's candidate rules over the enumerated corpus.
//
// This file is deliberately SEPARATE from itinerary_shape_corpus_test.go and
// landed in a LATER commit. The corpus and its labels exist first, in the
// history, so "the labels were written before any rule ran" is something a
// reader can check rather than something this comment asserts. Nothing here may
// ever edit a label; if a verdict looks wrong, the finding is that the RULE is
// wrong, and the report says so.
//
// The candidates are every rule the arc considered, reconstructed from PR #522,
// the audit-finding artifact and that lane's transcript:
//
//	UNGUARDED      what main did before #522: validate nothing. The floor.
//	CURRENT        #522 as first written: fragmentation OR a day break.
//	OPT-A          #522 as merged: (fragmentation AND a day break) OR a day
//	               break — which reduces to the day break alone.
//	OVERLAP        two stays in one city whose day ranges collide, or a break.
//	GAP            a returning stay must start after the previous stay ends,
//	               or a break.
//	INTERLEAVE     the clause alone: runs A,B,A,B.
//	A+INTERLEAVE   the rule this lane exists to test: OPT-A plus the clause.
//	A+INTERLEAVE   the same clause under its tighter reading, where the four
//	  (adjacent)   runs must be consecutive. Scored so "you tested the wrong
//	               reading" is answered rather than left open.
//
// The scoring bar is the one the guard lane established and the coordinator
// upheld, and it is not symmetric:
//
//   - A FALSE REJECTION is a regression. A scope-'trip' payload is always the
//     COMPLETE itinerary, so rejecting a legal one blocks every whole-trip edit
//     on that trip, permanently and silently.
//   - A MISS is not a regression. main validates nothing here, so a shape a
//     rule fails to catch is a smaller improvement, never a new harm.
//
// So a rule with one false rejection is worse than a rule with twenty misses,
// however the totals read.

import (
	"fmt"
	"sort"
	"strings"
	"testing"
)

type candidateRule struct {
	Name    string
	Rejects func(items []runItem) bool
}

// hasInterleave is the clause under test, exactly as the plan states it:
//
//	runs i < j < k < l where hub(i)==hub(k), hub(j)==hub(l), hub(i)≠hub(j)
//
// — the run pattern A,B,A,B. Hubless runs are skipped, as everywhere else:
// computeTripLegs groups them by a different rule and they are not a city being
// interrupted.
func hasInterleave(items []runItem) bool {
	runs := hubRuns(items)
	var hubs []string
	for _, r := range runs {
		hubs = append(hubs, foldIdentity(r.Hub))
	}
	for i := 0; i < len(hubs); i++ {
		if hubs[i] == "" {
			continue
		}
		for j := i + 1; j < len(hubs); j++ {
			if hubs[j] == "" || hubs[j] == hubs[i] {
				continue
			}
			for k := j + 1; k < len(hubs); k++ {
				if hubs[k] != hubs[i] {
					continue
				}
				for l := k + 1; l < len(hubs); l++ {
					if hubs[l] == hubs[j] {
						return true
					}
				}
			}
		}
	}
	return false
}

// hasAdjacentInterleave is the TIGHTER reading of the same clause: the four
// runs must be CONSECUTIVE, so only a literal A,B,A,B stretch counts and
// A,B,A,C,B does not. Scored because the plan's wording (i < j < k < l) admits
// both readings, and a reader would otherwise reasonably ask whether the loose
// one is what failed. It is not — the decisive counterexample, four one-day
// stays on days 1,2,3,4, is consecutive.
//
// Scored, NOT proposed. Adopting a rule invented in the same pass that scores
// it is the error this lane exists to avoid committing a second time.
func hasAdjacentInterleave(items []runItem) bool {
	runs := hubRuns(items)
	for i := 0; i+3 < len(runs); i++ {
		a, b := foldIdentity(runs[i].Hub), foldIdentity(runs[i+1].Hub)
		if a == "" || b == "" || a == b {
			continue
		}
		if foldIdentity(runs[i+2].Hub) == a && foldIdentity(runs[i+3].Hub) == b {
			return true
		}
	}
	return false
}

// sameHubDaysCollide is the OVERLAP candidate: two stays in the same city that
// share a day number. Reconstructed from the guard lane's own statement of it —
// "a genuine revisit occupies disjoint, ordered day ranges; corruption puts the
// same city in two runs whose days collide" — so a shared day counts as a
// collision and a merely adjacent pair does not.
//
// It is evaluated on the runs directly rather than through classifyHubRuns,
// which skips identical day ranges before any range test could see them. That
// skip is load-bearing for `repair-sections`' verdicts and is not touched here;
// evaluating around it is what lets the candidate be scored at all.
func sameHubDaysCollide(items []runItem) bool {
	return anySameHubPair(items, func(a, b hubRun) bool {
		aLo, aHi, aOK := dayRange(a.slice(items))
		bLo, bHi, bOK := dayRange(b.slice(items))
		if !aOK || !bOK {
			return false
		}
		return bLo <= aHi && aLo <= bHi
	})
}

// returnStartsTooSoon is the GAP candidate: a stay in a city visited before must
// begin AFTER the stay immediately preceding it has ended. The guard lane's
// counterexample — a revisit that arrives on a shared transition day, Rome that
// morning and back in Paris that evening — is what fixes "previous stay" as the
// immediately preceding run rather than the previous run of the same city.
func returnStartsTooSoon(items []runItem) bool {
	runs := hubRuns(items)
	seen := map[string]bool{}
	for i, r := range runs {
		h := foldIdentity(r.Hub)
		if h == "" {
			continue
		}
		if seen[h] && i > 0 {
			lo, _, ok := dayRange(r.slice(items))
			_, prevHi, prevOK := dayRange(runs[i-1].slice(items))
			if ok && prevOK && lo <= prevHi {
				return true
			}
		}
		seen[h] = true
	}
	return false
}

func anySameHubPair(items []runItem, hit func(a, b hubRun) bool) bool {
	runs := hubRuns(items)
	byHub := map[string][]int{}
	for i, r := range runs {
		h := foldIdentity(r.Hub)
		if h == "" {
			continue
		}
		byHub[h] = append(byHub[h], i)
	}
	for _, idx := range byHub {
		for a := 0; a < len(idx); a++ {
			for b := a + 1; b < len(idx); b++ {
				if hit(runs[idx[a]], runs[idx[b]]) {
					return true
				}
			}
		}
	}
	return false
}

func candidateRules() []candidateRule {
	return []candidateRule{
		{"UNGUARDED", func(items []runItem) bool { return false }},
		{"CURRENT", func(items []runItem) bool {
			v := inspectTripScope(items)
			return len(v.Fragmented) > 0 || len(v.Breaks) > 0
		}},
		{"OPT-A (shipped)", func(items []runItem) bool { return inspectTripScope(items).rejects() }},
		{"OVERLAP", func(items []runItem) bool {
			return sameHubDaysCollide(items) || len(inspectTripScope(items).Breaks) > 0
		}},
		{"GAP", func(items []runItem) bool {
			return returnStartsTooSoon(items) || len(inspectTripScope(items).Breaks) > 0
		}},
		{"INTERLEAVE alone", hasInterleave},
		{"A+INTERLEAVE", func(items []runItem) bool {
			return inspectTripScope(items).rejects() || hasInterleave(items)
		}},
		{"A+INTERLEAVE (adjacent)", func(items []runItem) bool {
			return inspectTripScope(items).rejects() || hasAdjacentInterleave(items)
		}},
	}
}

type ruleScore struct {
	FalseRejections, Misses, Total int
	FalseRejectionIDs, MissIDs     []string
}

func scoreRule(r candidateRule, shapes []enumShape) ruleScore {
	var s ruleScore
	for _, sh := range shapes {
		s.Total++
		rejects := r.Rejects(runItemsOfLocations(sh.Locs))
		switch {
		case sh.Legal && rejects:
			s.FalseRejections++
			s.FalseRejectionIDs = append(s.FalseRejectionIDs, sh.ID)
		case !sh.Legal && !rejects:
			s.Misses++
			s.MissIDs = append(s.MissIDs, sh.ID)
		}
	}
	return s
}

func sample(ids []string, n int) string {
	if len(ids) == 0 {
		return "—"
	}
	if len(ids) <= n {
		return strings.Join(ids, ", ")
	}
	return strings.Join(ids[:n], ", ") + fmt.Sprintf(" +%d more", len(ids)-n)
}

// TestCandidateRulesOverTheEnumeratedCorpus is the lane's actual deliverable:
// one table, every candidate rule, scored over the whole labelled space and
// over the NEW shapes alone. The second number is the finding — a rule that
// only performs on the shapes it was fitted to shows up there and nowhere else.
func TestCandidateRulesOverTheEnumeratedCorpus(t *testing.T) {
	shapes := generateCorpus()
	knownSigs := knownSignatures(shapes)
	var newShapes []enumShape
	for _, s := range shapes {
		if s.isNew(knownSigs) {
			newShapes = append(newShapes, s)
		}
	}
	legal, illegal := 0, 0
	for _, s := range shapes {
		if s.Legal {
			legal++
		} else {
			illegal++
		}
	}
	newLegal, newIllegal := 0, 0
	for _, s := range newShapes {
		if s.Legal {
			newLegal++
		} else {
			newIllegal++
		}
	}

	t.Logf("corpus: %d shapes (%d legal, %d illegal); %d new (%d legal, %d illegal)",
		len(shapes), legal, illegal, len(newShapes), newLegal, newIllegal)
	t.Logf("%-23s | %-22s | %-22s", "rule", "ALL  false-rej / miss", "NEW  false-rej / miss")
	t.Logf("%s", strings.Repeat("-", 70))
	for _, r := range candidateRules() {
		all := scoreRule(r, shapes)
		nw := scoreRule(r, newShapes)
		t.Logf("%-23s | %10d / %-10d | %10d / %-10d", r.Name,
			all.FalseRejections, all.Misses, nw.FalseRejections, nw.Misses)
	}
	t.Logf("%s", strings.Repeat("-", 70))
	for _, r := range candidateRules() {
		all := scoreRule(r, shapes)
		t.Logf("%-23s  false rejections: %s", r.Name, sample(all.FalseRejectionIDs, 4))
	}
}

// TestTheInterleaveClauseRejectsLegalItineraries is the lane's finding, pinned
// so it cannot be quietly re-litigated.
//
// A,B,A,B is not a corruption signature. It is Paris → Rome → Paris → Rome, and
// every one of those is a stay that began after the one before it ended. The
// plan's principle — "once you leave A for B you are in B until you leave B" —
// constrains TIME, and this shape does not violate it: the first Paris stay was
// not interrupted by Rome, it ENDED. The step from "A,B,A is a supported
// revisit" (pinned by TestClassifyAllowsGenuineRevisit, and the load-bearing
// fact of the whole classifier) to "A,B,A,B is two lists spliced together" is
// not supported by the definition — it is one more ordinary stay, the kind a
// traveler adds by spending the last night back near the airport they fly home
// from.
//
// By the arc's own asymmetry a false rejection is a REGRESSION, so the clause
// does not clear the bar and is not shipped. This test exists so that if
// somebody proposes it again, the counterexample is already in the tree.
func TestTheInterleaveClauseRejectsLegalItineraries(t *testing.T) {
	// Paris 1-3 · Rome 4-6 · Paris 7-9 · Rome 10. Days run forwards throughout,
	// no stay overlaps another, and the two Rome stays hold different places.
	locs := []map[string]any{
		rl("Louvre", 1, "Paris", ""), rl("Orsay", 2, "Paris", ""), rl("Rodin", 3, "Paris", ""),
		rl("Colosseum", 4, "Rome", ""), rl("Forum", 5, "Rome", ""), rl("Pantheon", 6, "Rome", ""),
		rl("Sacre-Coeur", 7, "Paris", ""), rl("Montmartre", 8, "Paris", ""), rl("Marais dinner", 9, "Paris", ""),
		rl("Trastevere", 10, "Rome", ""),
	}
	items := runItemsOfLocations(locs)

	if legal, reason := legalSequenceOfStays(items); !legal {
		t.Fatalf("the definition must admit this shape; it says: %s", reason)
	}
	if !inspectTripScope(items).ok() {
		t.Fatal("the shipped guard accepts this today — if that changed, the regression is here, not in the clause")
	}
	if !hasInterleave(items) {
		t.Fatal("this is A,B,A,B; if the clause no longer matches it, the clause was reworded and this test is stale")
	}
	t.Log("A,B,A,B with forward-running days is legal, is accepted today, and the interleave clause would reject it")
}

// TestTheDefinitionAndDayMonotonicityAreTheSamePredicate is the caveat that
// keeps the scoring table from being read as more than it is.
//
// OPT-A scores 0 false rejections and 0 misses, and that is NOT a measurement
// of its merit — it is an identity. "Days never step backwards in position
// order" and "the stays are ordered and do not overlap" are the same predicate:
// every item of an earlier stay precedes every item of a later one, so a stay
// starting before an earlier one ended is exactly a backward day step, and a
// backward step inside a stay is exactly a stay out of visit order. The
// enumeration cannot award the shipped rule anything, and this test says so out
// loud rather than letting the table imply otherwise.
//
// What the enumeration CAN do is falsify, and that is not weakened by any of
// this: the labels are independent of CURRENT, OVERLAP, GAP and INTERLEAVE, so
// every false rejection those four collect is real evidence against them.
//
// The consequence worth carrying forward: a payload's position order and its
// day numbers are the only two carriers of time this schema has. When they
// agree, there is nothing left in the data to appeal to — so any rule that
// rejects MORE than day-monotonicity is necessarily rejecting on something the
// payload does not say.
func TestTheDefinitionAndDayMonotonicityAreTheSamePredicate(t *testing.T) {
	for _, s := range generateCorpus() {
		items := runItemsOfLocations(s.Locs)
		legal, _ := legalSequenceOfStays(items)
		if legal != (len(dayOrderBreaks(items)) == 0) {
			t.Fatalf("%s separates the two: definition says legal=%v, day-monotonicity says legal=%v — %s",
				s.ID, legal, len(dayOrderBreaks(items)) == 0, renderLocs(s.Locs))
		}
	}
}

// TestTheClauseFalseRejectionsAreNotDegenerate answers the one objection that
// could rescue the clause: that its false rejections are all silly shapes —
// everything on one day, or two stays sharing a single day — which a reader
// might discount even though the ticket forbids discarding a shape for being
// unrealistic.
//
// They are not. A large share of them run STRICTLY FORWARD (every day number
// greater than the one before it, so no shared day anywhere) with every stay
// holding DIFFERENT places, which is the plainest legal itinerary this schema
// can express. The clause rejects those too.
func TestTheClauseFalseRejectionsAreNotDegenerate(t *testing.T) {
	shapes := generateCorpus()
	knownSigs := knownSignatures(shapes)
	var plain []string
	for _, s := range shapes {
		items := runItemsOfLocations(s.Locs)
		if !s.Legal || !hasInterleave(items) || !s.isNew(knownSigs) {
			continue
		}
		if strictlyForward(items) && allStaysHoldDifferentPlaces(items) {
			plain = append(plain, s.ID)
		}
	}
	if len(plain) == 0 {
		t.Fatal("every A,B,A,B false rejection turned out to be degenerate — that would materially weaken the finding and the report must be rewritten")
	}
	t.Logf("%d of the clause's false rejections are strictly-forward, all-different-places itineraries: %s",
		len(plain), sample(plain, 6))
}

// strictlyForward: every dated item's day is greater than the one before it —
// no shared transition day, no plateau, nothing to quibble with.
func strictlyForward(items []runItem) bool {
	var prev *int
	dated := 0
	for _, it := range items {
		if it.Day == nil {
			return false
		}
		dated++
		if prev != nil && *it.Day <= *prev {
			return false
		}
		d := *it.Day
		prev = &d
	}
	return dated == len(items) && dated > 0
}

// allStaysHoldDifferentPlaces: no stay duplicates another's contents, so not
// even the conservative fragmentation predicate has anything to say about it.
func allStaysHoldDifferentPlaces(items []runItem) bool {
	return !anySameHubPair(items, func(a, b hubRun) bool {
		ca, cb := identityCounts(a.slice(items)), identityCounts(b.slice(items))
		return subsetOf(ca, cb) || subsetOf(cb, ca)
	})
}

// TestTheEnumerationFindsNoRuleBetterThanTheShippedOne states the comparison
// plainly: over 589 labelled shapes, exactly one candidate has zero false
// rejections, and it is the rule already on main.
//
// Written as a loop over the candidates rather than as a fixed table so that a
// sixth rule proposed later is scored by the same instrument automatically.
func TestTheEnumerationFindsNoRuleBetterThanTheShippedOne(t *testing.T) {
	shapes := generateCorpus()
	var clean []string
	for _, r := range candidateRules() {
		s := scoreRule(r, shapes)
		if r.Name == "OPT-A (shipped)" && s.FalseRejections > 0 {
			t.Fatalf("the SHIPPED rule has false rejections over the enumerated corpus — that is a live regression on main and outranks everything else this lane found: %s",
				sample(s.FalseRejectionIDs, 4))
		}
		// Validating nothing is trivially non-regressive; it is the floor, not
		// a candidate.
		if s.FalseRejections == 0 && r.Name != "UNGUARDED" {
			clean = append(clean, r.Name)
		}
	}
	sort.Strings(clean)
	if len(clean) != 1 || clean[0] != "OPT-A (shipped)" {
		t.Fatalf("expected the shipped rule to be the only non-regressive candidate; got %v. A NEW rule clearing this bar is a finding to report, not a reason to edit this test", clean)
	}
}
