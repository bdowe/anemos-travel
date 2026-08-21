package main

// The enumerated shape corpus — and the instrument that labels it.
//
// WHY THIS FILE EXISTS, and why it is generated rather than written. The
// interleave clause (runs A,B,A,B) scored 0 false rejections and 0 misses
// against a corpus the same agent wrote while developing it. That is not
// evidence: a corpus assembled after a rule failed, to see whether the next
// rule passes, is an output of the rule. A second agent inventing more shapes
// carries the same bias, so the way out is not to imagine harder — it is to
// stop imagining and ENUMERATE.
//
// So this file generates EVERY run-pattern up to five runs over a small hub
// alphabet, crosses each with the run sizes and day assignments that matter,
// and labels every result from the DEFINITION of a correct itinerary:
//
//	A correct itinerary is a sequence of stays. Once you leave A for B you are
//	in B until you leave B.
//
// THE DISCIPLINE THAT MAKES IT WORTH DOING: the labels come from the
// definition, the shapes come from the enumeration, and NEITHER comes from any
// candidate rule. This file contains no candidate rule and does not import one
// — the scoring harness is a separate file, added in a separate commit, so the
// git history itself shows the labels predate the first verdict. If a label is
// changed after a verdict is seen, the corpus has become an output of the rule
// and the exercise is void.
//
// WHAT IS NOT ENUMERATED, stated so the coverage claim is honest rather than
// implied:
//   - Hubless items. `classifyHubRuns` skips empty hubs and computeTripLegs
//     groups them into an "Other places" leg by a different rule, so they are a
//     separate axis, not a run-pattern. The one known hubless shape (LEGIT-05)
//     is carried in the KNOWN block instead.
//   - `day_trip_from`. Hub is `day_trip_from ?? city`, so a day trip is a hub
//     spelling, not a new pattern; varying the hub directly covers it. LEGIT-04
//     is carried in the KNOWN block.
//   - Spelling variance (case, diacritics). Folded before any run reasoning by
//     `foldIdentity`; LEGIT-08 covers it.
//   - Six or more runs. N=5 is the ticket's depth: N=4 reaches A,B,A,B and N=5
//     is where a rule tuned on length 4 breaks.

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"testing"
)

// corpusFixturePath is committed, like testdata/guard_audit_corpus.sql before
// it, so the next person can falsify this rather than re-derive it.
const corpusFixturePath = "testdata/enumerated_shape_corpus.txt"

// maxEnumeratedRuns is the enumeration depth. N=4 reaches A,B,A,B; N=5 is where
// a rule fitted to length 4 shows its edges (A,B,A,C,A · A,B,C,A,B · …).
const maxEnumeratedRuns = 5

// --- the instrument: what makes an itinerary a correct sequence of stays ---

// legalSequenceOfStays is THE label function, and it implements the definition
// and nothing else:
//
//	A correct itinerary is a sequence of stays. Once you leave A for B you are
//	in B until you leave B.
//
// Two obligations follow from that sentence, and they are all this checks:
//
//	(1) Within one stay the places are in visit order — its dated items' day
//	    numbers never step backwards.
//	(2) The stays' day intervals are ORDERED and do not OVERLAP. A later stay
//	    may begin on the day an earlier one ends — that is the shared
//	    transition day, the schema's own convention (itineraryLocationSchema's
//	    `day` description: the move day carries the SAME number in the city
//	    left and the city reached) — but it may not begin before it.
//
// Deliberately absent, because the definition does not contain them:
//
//   - No opinion on how MANY runs a hub occupies. Paris → Rome → Paris is a
//     sequence of three stays and the definition admits it; so is
//     Paris → Rome → Paris → Rome. "Once you leave A for B you are in B until
//     you leave B" constrains TIME, not labels: a second Paris stay does not
//     interrupt the first, because the first ENDED before it began.
//   - No opinion on plausibility. A shape the definition admits is legal even
//     when no traveler would book it. That judgement is the whole instrument
//     and bending it toward a rule is the failure this corpus exists to avoid.
//   - No content comparison. Two stays holding the same places are still two
//     stays; whether the second is a splice copy is not something the
//     definition can see, and pretending otherwise would smuggle the
//     fragmentation predicate into the labels.
//
// Undated items make no claim about time, so they are skipped rather than read
// as day 0 — a spine leaves the middle of a stay empty and an unscheduled tail
// is legitimate.
//
// Run segmentation comes from the production `hubRuns` on purpose. A "stay" IS
// a contiguous same-hub stretch — that is what computeTripLegs renders a leg
// from and what the classifier groups by — so borrowing it keeps the instrument
// measuring the same objects the code does. It is not a candidate rule; it
// decides no verdict.
func legalSequenceOfStays(items []runItem) (bool, string) {
	runs := hubRuns(items)
	maxHi, haveMax := 0, false
	for _, r := range runs {
		s := r.slice(items)
		var prev *int
		for _, it := range s {
			if it.Day == nil {
				continue
			}
			if prev != nil && *it.Day < *prev {
				return false, fmt.Sprintf("the stay in %s runs backwards inside itself: day %d comes after day %d, so the list is not in visit order",
					hubLabel(r.Hub), *it.Day, *prev)
			}
			d := *it.Day
			prev = &d
		}
		lo, hi, ok := dayRange(s)
		if !ok {
			continue
		}
		if haveMax && lo < maxHi {
			return false, fmt.Sprintf("the stay in %s begins on day %d, but the traveler is still elsewhere until day %d — two stays claim the same time",
				hubLabel(r.Hub), lo, maxHi)
		}
		if !haveMax || hi > maxHi {
			maxHi, haveMax = hi, true
		}
	}
	return true, "the stays run in order and never overlap: each begins no earlier than the day the one before it ends"
}

func hubLabel(h string) string {
	if strings.TrimSpace(h) == "" {
		return "(no city)"
	}
	return h
}

// --- dimension 1: every run pattern ---

// enumerateRunPatterns returns EVERY run-label sequence of length 1..maxRuns
// with no two ADJACENT labels equal, canonicalized so labels appear in order of
// first use (A, then B, …). Adjacent equal labels are excluded because a run is
// a MAXIMAL same-hub stretch — "A,A" is one run, not two — and canonicalizing
// removes nothing, since renaming cities cannot change any verdict (every
// predicate in play compares hubs for equality, never by name).
//
// The counts are the Bell numbers shifted: 1, 1, 2, 5, 15 for lengths 1..5,
// which the fixture's own header records so a reader can check the enumeration
// is complete rather than take it on trust.
func enumerateRunPatterns(maxRuns int) []string {
	var out []string
	var grow func(cur []int)
	grow = func(cur []int) {
		if len(cur) > 0 {
			out = append(out, patternString(cur))
		}
		if len(cur) == maxRuns {
			return
		}
		next := 0
		for _, v := range cur {
			if v+1 > next {
				next = v + 1
			}
		}
		for lab := 0; lab <= next; lab++ {
			if len(cur) > 0 && cur[len(cur)-1] == lab {
				continue
			}
			grow(append(append([]int{}, cur...), lab))
		}
	}
	grow(nil)
	sort.Slice(out, func(i, j int) bool {
		if len(out[i]) != len(out[j]) {
			return len(out[i]) < len(out[j])
		}
		return out[i] < out[j]
	})
	return out
}

func patternString(cur []int) string {
	b := make([]byte, len(cur))
	for i, v := range cur {
		b[i] = byte('A' + v)
	}
	return string(b)
}

// --- dimension 2: the day assignments that matter ---

// dayAssignment computes one item's day from its POSITION in the shape and
// nothing else, so every variant is a mechanical function of the pattern rather
// than a shape somebody chose. A nil result means the item carries no day.
//
// firstRun is the index of the first run carrying this run's hub (== k when the
// hub is new), which is what lets the splice-shaped variant re-use a hub's
// original days without naming any particular itinerary.
type dayAssignment struct {
	Name string
	Day  func(k, idx, runSize, n, firstRun int) *int
}

func dayPtr(d int) *int { return &d }

// dayVariants are the assignments the ticket names, plus the two the pattern
// space forces: `paired` (days advance once per TWO runs, which is the only way
// two stays can occupy the very same single day — the interleaved-transition-day
// family lives here) and `splice` (a returning hub re-uses its ORIGINAL days,
// which is the splice bug's mechanism stated positionally rather than copied
// from an incident).
var dayVariants = []dayAssignment{
	{
		// Strictly increasing across the whole list — the plainest legal trip.
		Name: "increasing",
		Day: func(k, idx, runSize, n, firstRun int) *int {
			return dayPtr(k*runSize + idx + 1)
		},
	},
	{
		// Consecutive stays share exactly one day: the transition-day
		// convention, the shape most likely to be mistaken for a fault.
		Name: "shared_boundary",
		Day: func(k, idx, runSize, n, firstRun int) *int {
			return dayPtr(k*(runSize-1) + idx + 1)
		},
	},
	{
		// Days advance once per TWO runs, so a pair of consecutive stays sits
		// entirely inside one day. This is the only assignment under which two
		// stays' intervals can coincide rather than merely touch.
		Name: "paired",
		Day: func(k, idx, runSize, n, firstRun int) *int {
			return dayPtr((k+1)/2 + 1)
		},
	},
	{
		// Each stay is one day; days step forward once per stay.
		Name: "one_day_each",
		Day: func(k, idx, runSize, n, firstRun int) *int {
			return dayPtr(k + 1)
		},
	},
	{
		// The whole trip on a single day number — the degenerate plateau.
		Name: "all_one_day",
		Day: func(k, idx, runSize, n, firstRun int) *int {
			return dayPtr(1)
		},
	},
	{
		// A genuine backwards step: the LAST stay carries the FIRST stay's
		// days. With one run there is no later stay, so the step is made inside
		// it instead — every shape in this variant has a backward step by
		// construction, which is what makes it a control.
		Name: "backwards",
		Day: func(k, idx, runSize, n, firstRun int) *int {
			if n == 1 {
				return dayPtr(runSize - idx)
			}
			if k == n-1 {
				return dayPtr(idx + 1)
			}
			return dayPtr(k*runSize + idx + 1)
		},
	},
	{
		// An unscheduled tail — the last stay is a "maybe" with no days.
		Name: "undated_tail",
		Day: func(k, idx, runSize, n, firstRun int) *int {
			if k == n-1 {
				return nil
			}
			return dayPtr(k*runSize + idx + 1)
		},
	},
	{
		// The splice bug, positionally: a hub seen before carries its ORIGINAL
		// days again. For a pattern with no repeated hub this is `increasing`
		// and dedupes away.
		Name: "splice",
		Day: func(k, idx, runSize, n, firstRun int) *int {
			return dayPtr(firstRun*runSize + idx + 1)
		},
	},
}

// runSizes: one item per stay reaches the degenerate single-day stay a pattern
// of two-item stays structurally cannot express; two reaches the intervals.
var runSizes = []int{1, 2}

// contentVariants: whether a returning hub brings NEW places (a genuine
// revisit) or the SAME places again (a verbatim splice copy). For a pattern
// with no repeated hub the two coincide and dedupe away.
var contentVariants = []string{"fresh", "copy"}

// --- building one shape ---

type enumShape struct {
	ID        string
	Block     string // ENUM (generated) or KNOWN (the previous lane's shapes)
	Pattern   string
	RunSize   int
	DayVar    string
	Content   string
	Locs      []map[string]any
	Legal     bool
	Reason    string
	Signature string
}

func buildEnumShape(pattern string, runSize int, dv dayAssignment, content string) []map[string]any {
	n := len(pattern)
	firstRun := make([]int, n)
	seen := map[byte]int{}
	for k := 0; k < n; k++ {
		if f, ok := seen[pattern[k]]; ok {
			firstRun[k] = f
		} else {
			firstRun[k] = k
			seen[pattern[k]] = k
		}
	}
	var locs []map[string]any
	for k := 0; k < n; k++ {
		hub := string(pattern[k])
		nameRun := k
		if content == "copy" {
			nameRun = firstRun[k]
		}
		for idx := 0; idx < runSize; idx++ {
			name := fmt.Sprintf("%s%d-%d", hub, nameRun+1, idx+1)
			d := dv.Day(k, idx, runSize, n, firstRun[k])
			day := 0
			if d != nil {
				day = *d
			}
			locs = append(locs, rl(name, day, hub, ""))
		}
	}
	return locs
}

// --- the signature: everything any rule or the label can observe ---

// shapeSignature reduces a shape to the tuple of structural facts that decide
// every verdict in play — the run pattern, how each stay's days sit against the
// stays before it, and for each pair of stays sharing a hub, how their contents
// and day ranges relate.
//
// It exists for ONE arithmetic: which enumerated shapes are NEW, meaning they
// present a combination no shape the previous lane had already seen presents.
// Two shapes with the same signature are indistinguishable to the label
// function AND to every candidate rule, so calling one of them new would be
// counting the same evidence twice.
func shapeSignature(items []runItem) string {
	runs := hubRuns(items)
	canon := map[string]string{}
	var parts []string
	pattern := make([]byte, 0, len(runs))
	for _, r := range runs {
		k := foldIdentity(r.Hub)
		if _, ok := canon[k]; !ok {
			canon[k] = string(byte('A' + len(canon)))
		}
		pattern = append(pattern, canon[k][0])
	}
	parts = append(parts, string(pattern))

	maxHi, haveMax := 0, false
	var runFacts []string
	for _, r := range runs {
		s := r.slice(items)
		order := "fwd"
		var prev *int
		for _, it := range s {
			if it.Day == nil {
				continue
			}
			if prev != nil && *it.Day < *prev {
				order = "back"
			}
			d := *it.Day
			prev = &d
		}
		lo, hi, ok := dayRange(s)
		rel := "undated"
		switch {
		case !ok:
		case !haveMax:
			rel = "first"
		case lo > maxHi:
			rel = "after"
		case lo == maxHi:
			rel = "touches"
		default:
			rel = "before"
		}
		width := "span"
		if ok && lo == hi {
			width = "point"
		}
		runFacts = append(runFacts, order+":"+rel+":"+width)
		if ok && (!haveMax || hi > maxHi) {
			maxHi, haveMax = hi, true
		}
	}
	parts = append(parts, strings.Join(runFacts, ","))

	byHub := map[string][]int{}
	var order []string
	for i, r := range runs {
		k := foldIdentity(r.Hub)
		if _, ok := byHub[k]; !ok {
			order = append(order, k)
		}
		byHub[k] = append(byHub[k], i)
	}
	sort.Strings(order)
	var pairFacts []string
	for _, k := range order {
		idx := byHub[k]
		for a := 0; a < len(idx); a++ {
			for b := a + 1; b < len(idx); b++ {
				pairFacts = append(pairFacts, pairRelation(items, runs[idx[a]], runs[idx[b]]))
			}
		}
	}
	sort.Strings(pairFacts)
	parts = append(parts, strings.Join(pairFacts, ","))
	return strings.Join(parts, "|")
}

// pairRelation describes two stays of the SAME hub: whether one's places are a
// content duplicate of the other's, and how their day ranges sit. Both are
// facts a candidate rule in this arc reads.
func pairRelation(items []runItem, a, b hubRun) string {
	ca, cb := identityCounts(a.slice(items)), identityCounts(b.slice(items))
	content := "different"
	switch {
	case subsetOf(ca, cb) && subsetOf(cb, ca):
		content = "identical"
	case subsetOf(cb, ca):
		content = "subset"
	case subsetOf(ca, cb):
		content = "superset"
	}
	aLo, aHi, aOK := dayRange(a.slice(items))
	bLo, bHi, bOK := dayRange(b.slice(items))
	days := "undated"
	switch {
	case !aOK || !bOK:
	case aLo == bLo && aHi == bHi:
		days = "same_range"
	case bLo < aHi:
		days = "overlapping"
	case bLo == aHi:
		days = "touching"
	default:
		days = "separated"
	}
	return content + "/" + days
}

// --- the shapes the previous lane already had ---

// knownShapes are the 21 shapes the trip-scope-guard lane worked from,
// transcribed so the enumerated corpus is a SUPERSET and the old results stay
// comparable. LEGIT-01..12 and CORRUPT-01..04 come verbatim from
// testdata/guard_audit_corpus.sql; LEGIT-13 from
// TestClassifyAllowsRevisitArrivingOnATransitionDay; COUNTER-a from that lane's
// own transcript of the shape.
//
// COUNTER-b, -c and -d are NOT here, and that is stated rather than papered
// over: they existed only in a throwaway probe that lane deleted, and neither
// PR #522, the artifacts, nor the transcript records their contents — only that
// -a and -c were interleaved transition days and that -b was an interleave the
// content-duplication test happened to catch. So the "new" count below is
// accurate to within THREE shapes, and the report says so.
func knownShapes() []enumShape {
	mk := func(id string, locs []map[string]any) enumShape {
		return enumShape{ID: id, Block: "KNOWN", Locs: locs}
	}
	return []enumShape{
		mk("LEGIT-01-linear-two-cities", []map[string]any{
			rl("Louvre", 1, "Paris", ""), rl("Orsay", 2, "Paris", ""), rl("Eiffel Tower", 3, "Paris", ""),
			rl("Colosseum", 4, "Rome", ""), rl("Forum", 5, "Rome", ""), rl("Pantheon", 6, "Rome", ""),
		}),
		mk("LEGIT-02-genuine-revisit", []map[string]any{
			rl("Louvre", 1, "Paris", ""), rl("Orsay", 2, "Paris", ""),
			rl("Colosseum", 3, "Rome", ""), rl("Forum", 4, "Rome", ""),
			rl("Sacre-Coeur", 5, "Paris", ""), rl("Montmartre", 6, "Paris", ""),
		}),
		mk("LEGIT-03-shared-transition-day", []map[string]any{
			rl("Louvre", 1, "Paris", ""), rl("Orsay", 2, "Paris", ""), rl("Sainte-Chapelle", 3, "Paris", ""),
			rl("Trastevere dinner", 3, "Rome", ""), rl("Colosseum", 4, "Rome", ""),
		}),
		mk("LEGIT-04-day-trip-from-hub", []map[string]any{
			rl("Louvre", 1, "Paris", ""), rl("Versailles", 2, "Versailles", "Paris"),
			rl("Orsay", 3, "Paris", ""), rl("Colosseum", 4, "Rome", ""),
		}),
		mk("LEGIT-05-hubless-between-runs", []map[string]any{
			rl("Louvre", 1, "Paris", ""), rl("Roadside viewpoint", 2, "", ""),
			rl("Orsay", 3, "Paris", ""), rl("Colosseum", 4, "Rome", ""),
		}),
		mk("LEGIT-06-spine-empty-middles", []map[string]any{
			rl("Arrive Paris", 1, "Paris", ""), rl("Leave Paris", 4, "Paris", ""),
			rl("Arrive Rome", 4, "Rome", ""), rl("Leave Rome", 8, "Rome", ""),
		}),
		mk("LEGIT-07-undated-tail", []map[string]any{
			rl("Louvre", 1, "Paris", ""), rl("Orsay", 2, "Paris", ""), rl("Maybe: Pompidou", 0, "Paris", ""),
		}),
		mk("LEGIT-08-diacritic-variance", []map[string]any{
			rl("Wawel Castle", 1, "Kraków", ""), rl("Sukiennice", 2, "Krakow", ""),
			rl("Rynek Glowny", 3, "KRAKOW", ""), rl("Charles Bridge", 4, "Prague", ""),
		}),
		mk("LEGIT-09-five-cities", []map[string]any{
			rl("Sagrada Familia", 1, "Barcelona", ""), rl("Park Guell", 2, "Barcelona", ""),
			rl("Montserrat", 3, "Montserrat", "Barcelona"), rl("Boqueria", 4, "Barcelona", ""),
			rl("Alhambra", 4, "Granada", ""), rl("Albaicin", 5, "Granada", ""),
			rl("Mezquita", 6, "Cordoba", ""), rl("Alcazar", 7, "Seville", ""),
			rl("Plaza de Espana", 8, "Seville", ""), rl("Prado", 9, "Madrid", ""),
			rl("Retiro", 10, "Madrid", ""), rl("Maybe: Toledo", 0, "Toledo", "Madrid"),
		}),
		mk("LEGIT-10-single-city", []map[string]any{
			rl("Louvre", 1, "Paris", ""), rl("Orsay", 2, "Paris", ""),
		}),
		mk("LEGIT-11-revisit-repeating-a-place", []map[string]any{
			rl("Louvre", 1, "Paris", ""), rl("Orsay", 2, "Paris", ""),
			rl("Colosseum", 3, "Rome", ""), rl("Forum", 4, "Rome", ""),
			rl("Louvre", 5, "Paris", ""),
		}),
		mk("LEGIT-12-island-hop", []map[string]any{
			rl("Acropolis", 1, "Athens", ""), rl("Plaka dinner", 2, "Athens", ""),
			rl("Oia sunset", 2, "Santorini", ""), rl("Red Beach", 3, "Santorini", ""),
			rl("Little Venice", 4, "Mykonos", ""), rl("Delos", 5, "Delos", "Mykonos"),
		}),
		mk("LEGIT-13-revisit-on-transition-day", []map[string]any{
			rl("Louvre", 1, "Paris", ""), rl("Orsay", 2, "Paris", ""),
			rl("Colosseum", 3, "Rome", ""), rl("Forum", 4, "Rome", ""),
			rl("Gare du Nord", 4, "Paris", ""), rl("Montmartre", 5, "Paris", ""),
		}),
		mk("CORRUPT-01-stale-trailing-run", []map[string]any{
			rl("Wawel Castle", 1, "Krakow", ""), rl("Rynek Glowny", 2, "Krakow", ""),
			rl("Charles Bridge", 3, "Prague", ""), rl("Old Town Square", 4, "Prague", ""),
			rl("Wawel Castle", 3, "Krakow", ""), rl("Rynek Glowny", 4, "Krakow", ""),
		}),
		mk("CORRUPT-02-stale-leading-run", []map[string]any{
			rl("Charles Bridge", 1, "Prague", ""), rl("Old Town Square", 2, "Prague", ""),
			rl("Wawel Castle", 1, "Krakow", ""), rl("Rynek Glowny", 2, "Krakow", ""),
			rl("Charles Bridge", 3, "Prague", ""), rl("Old Town Square", 4, "Prague", ""),
		}),
		mk("CORRUPT-03-days-backwards-no-repeat", []map[string]any{
			rl("Colosseum", 4, "Rome", ""), rl("Forum", 5, "Rome", ""),
			rl("Louvre", 1, "Paris", ""), rl("Orsay", 2, "Paris", ""),
			rl("Duomo", 6, "Milan", ""),
		}),
		mk("CORRUPT-04-four-cities-fragmented", []map[string]any{
			rl("Charles Bridge", 1, "Prague", ""), rl("Old Town Square", 2, "Prague", ""),
			rl("Wawel Castle", 3, "Kraków", ""), rl("Rynek Glowny", 4, "Kraków", ""),
			rl("Colosseum", 5, "Rome", ""), rl("Marina Grande", 7, "Sorrento", ""),
			rl("Charles Bridge", 5, "Prague", ""), rl("Old Town Square", 6, "Prague", ""),
			rl("Wawel Castle", 7, "Krakow", ""), rl("Rynek Glowny", 8, "Krakow", ""),
			rl("Forum", 9, "Rome", ""), rl("Marina Grande", 10, "Sorrento", ""),
		}),
		mk("COUNTER-a-interleaved-transition-day", []map[string]any{
			rl("Charles Bridge", 5, "Prague", ""), rl("Wawel", 6, "Krakow", ""),
			rl("Old Town Sq", 6, "Prague", ""), rl("Rynek", 7, "Krakow", ""),
		}),
	}
}

// --- generation ---

func generateCorpus() []enumShape {
	var shapes []enumShape
	for _, s := range knownShapes() {
		items := runItemsOfLocations(s.Locs)
		s.Legal, s.Reason = legalSequenceOfStays(items)
		s.Signature = shapeSignature(items)
		s.Pattern = strings.SplitN(s.Signature, "|", 2)[0]
		s.RunSize = 0
		s.DayVar = "-"
		s.Content = "-"
		shapes = append(shapes, s)
	}
	knownSigs := map[string]bool{}
	for _, s := range shapes {
		knownSigs[s.Signature] = true
	}

	seen := map[string]bool{}
	i := 0
	for _, pattern := range enumerateRunPatterns(maxEnumeratedRuns) {
		for _, runSize := range runSizes {
			for _, dv := range dayVariants {
				for _, content := range contentVariants {
					locs := buildEnumShape(pattern, runSize, dv, content)
					key := renderLocs(locs)
					if seen[key] {
						continue
					}
					seen[key] = true
					items := runItemsOfLocations(locs)
					legal, reason := legalSequenceOfStays(items)
					i++
					shapes = append(shapes, enumShape{
						ID:        fmt.Sprintf("E-%03d", i),
						Block:     "ENUM",
						Pattern:   pattern,
						RunSize:   runSize,
						DayVar:    dv.Name,
						Content:   content,
						Locs:      locs,
						Legal:     legal,
						Reason:    reason,
						Signature: shapeSignature(items),
					})
				}
			}
		}
	}
	return shapes
}

// isNew reports whether an enumerated shape presents a structural combination
// no shape the previous lane held already presented.
func (s enumShape) isNew(knownSigs map[string]bool) bool {
	return s.Block == "ENUM" && !knownSigs[s.Signature]
}

func knownSignatures(shapes []enumShape) map[string]bool {
	sigs := map[string]bool{}
	for _, s := range shapes {
		if s.Block == "KNOWN" {
			sigs[s.Signature] = true
		}
	}
	return sigs
}

func renderLocs(locs []map[string]any) string {
	parts := make([]string, 0, len(locs))
	for _, l := range locs {
		name, _ := l["name"].(string)
		city, _ := l["city"].(string)
		dtf, _ := l["day_trip_from"].(string)
		hub := city
		if dtf != "" {
			hub = dtf + "<" + city
		}
		day := "-"
		if d, ok := l["day"].(float64); ok {
			day = fmt.Sprintf("%d", int(d))
		}
		if hub == "" {
			hub = "?"
		}
		parts = append(parts, fmt.Sprintf("%s[%s]@%s", name, hub, day))
	}
	return strings.Join(parts, " ")
}

// --- the committed fixture ---

func renderCorpus(shapes []enumShape) string {
	var b strings.Builder
	knownSigs := knownSignatures(shapes)
	patterns := enumerateRunPatterns(maxEnumeratedRuns)
	byLen := map[int]int{}
	for _, p := range patterns {
		byLen[len(p)]++
	}
	counts := make([]string, 0, maxEnumeratedRuns)
	for n := 1; n <= maxEnumeratedRuns; n++ {
		counts = append(counts, fmt.Sprintf("%d runs: %d", n, byLen[n]))
	}

	b.WriteString("# The enumerated shape corpus — labelled from the definition, before any rule ran.\n")
	b.WriteString("#\n")
	b.WriteString("# GENERATED by itinerary_shape_corpus_test.go. Do not hand-edit: run\n")
	b.WriteString("#   UPDATE_SHAPE_CORPUS=1 go test ./... -run TestEnumeratedCorpusFixtureIsCurrent\n")
	b.WriteString("#\n")
	b.WriteString("# WHY IT IS GENERATED. The interleave rule (runs A,B,A,B) scored 0 false\n")
	b.WriteString("# rejections and 0 misses against a corpus written by the agent that wrote the\n")
	b.WriteString("# rule, after earlier candidates had failed. That is an output of the rule, not\n")
	b.WriteString("# evidence about it, and a second agent inventing more shapes carries the same\n")
	b.WriteString("# bias. So nothing here was invented: every ENUM row is one cell of a full\n")
	b.WriteString("# cross-product, and every label comes from the definition of a correct\n")
	b.WriteString("# itinerary rather than from any rule's verdict.\n")
	b.WriteString("#\n")
	b.WriteString("# THE DEFINITION, which is the whole instrument:\n")
	b.WriteString("#   A correct itinerary is a sequence of stays. Once you leave A for B you are\n")
	b.WriteString("#   in B until you leave B.\n")
	b.WriteString("# Read as two obligations and nothing more: (1) within a stay the days never\n")
	b.WriteString("# step backwards, and (2) the stays' day intervals are ordered and do not\n")
	b.WriteString("# overlap — a later stay may BEGIN on the day an earlier one ENDS (the shared\n")
	b.WriteString("# transition day) but not before. It has no opinion on how many stays a city\n")
	b.WriteString("# gets, and none on whether a traveler would plausibly book the trip.\n")
	b.WriteString("#\n")
	b.WriteString("# THE ENUMERATION: every run pattern up to " + fmt.Sprint(maxEnumeratedRuns) + " runs with no two adjacent runs\n")
	b.WriteString("# sharing a hub (" + strings.Join(counts, " · ") + "), crossed with\n")
	b.WriteString("# " + fmt.Sprint(len(runSizes)) + " run sizes × " + fmt.Sprint(len(dayVariants)) + " day assignments × " + fmt.Sprint(len(contentVariants)) + " content relations, deduplicated.\n")
	b.WriteString("#\n")
	b.WriteString("# NOT enumerated, said plainly rather than left to be assumed: hubless items,\n")
	b.WriteString("# day_trip_from spellings, diacritic/case variance and patterns of six runs or\n")
	b.WriteString("# more. The first three are hub SPELLINGS rather than run patterns and are\n")
	b.WriteString("# carried by the KNOWN block (LEGIT-04/-05/-08); the fourth is the depth the\n")
	b.WriteString("# ticket set.\n")
	b.WriteString("#\n")
	b.WriteString("# BLOCKS. KNOWN rows are the shapes the trip-scope-guard lane already worked\n")
	b.WriteString("# from, transcribed so this corpus is a superset and the old numbers stay\n")
	b.WriteString("# comparable. `new=yes` marks an ENUM row whose signature — the tuple of every\n")
	b.WriteString("# structural fact a rule or the label can read — no KNOWN row presents.\n")
	b.WriteString("#\n")
	b.WriteString("# COLUMNS (tab separated):\n")
	b.WriteString("#   id · block · new · pattern · runsize · days · content · label · reason · signature · items\n")
	b.WriteString("#\n")

	legalCount, illegalCount, newCount := 0, 0, 0
	for _, s := range shapes {
		if s.Legal {
			legalCount++
		} else {
			illegalCount++
		}
		if s.isNew(knownSigs) {
			newCount++
		}
	}
	b.WriteString(fmt.Sprintf("# TOTALS: %d shapes — %d legal, %d illegal; %d KNOWN (%d distinct signatures), %d enumerated, of which %d are new.\n#\n",
		len(shapes), legalCount, illegalCount, len(knownShapes()), len(knownSigs), len(shapes)-len(knownShapes()), newCount))

	for _, s := range shapes {
		isNew := "no"
		if s.isNew(knownSigs) {
			isNew = "yes"
		}
		label := "LEGAL"
		if !s.Legal {
			label = "ILLEGAL"
		}
		runSize := fmt.Sprint(s.RunSize)
		if s.RunSize == 0 {
			runSize = "-"
		}
		b.WriteString(strings.Join([]string{
			s.ID, s.Block, isNew, s.Pattern, runSize, s.DayVar, s.Content,
			label, s.Reason, s.Signature, renderLocs(s.Locs),
		}, "\t"))
		b.WriteString("\n")
	}
	return b.String()
}

// TestEnumeratedCorpusFixtureIsCurrent pins the generated corpus to a committed
// file. It is what makes "the labels predate the verdicts" checkable rather
// than asserted: the fixture lands in its own commit, before any file scoring a
// candidate rule exists, and any later change to a label shows up here as a
// diff somebody has to justify.
func TestEnumeratedCorpusFixtureIsCurrent(t *testing.T) {
	got := renderCorpus(generateCorpus())
	if os.Getenv("UPDATE_SHAPE_CORPUS") == "1" {
		if err := os.WriteFile(corpusFixturePath, []byte(got), 0o644); err != nil {
			t.Fatalf("write fixture: %v", err)
		}
		t.Logf("wrote %s", corpusFixturePath)
		return
	}
	want, err := os.ReadFile(corpusFixturePath)
	if err != nil {
		t.Fatalf("read fixture: %v (regenerate with UPDATE_SHAPE_CORPUS=1)", err)
	}
	if string(want) != got {
		t.Fatalf("%s is stale. Regenerate with UPDATE_SHAPE_CORPUS=1 and READ THE DIFF: a changed LABEL is the corpus becoming an output of some rule, which is the one thing this file exists to prevent.", corpusFixturePath)
	}
}

// TestEnumerationIsComplete checks the generator against the count the pattern
// space must have, so "every pattern up to five runs" is a verified claim
// rather than a description of a loop. Sequences over an unbounded alphabet
// with no two adjacent equal, taken up to relabelling, are the set partitions
// of 1..n with no two consecutive elements in one block — the Bell numbers
// shifted by one: 1, 1, 2, 5, 15.
func TestEnumerationIsComplete(t *testing.T) {
	want := map[int]int{1: 1, 2: 1, 3: 2, 4: 5, 5: 15}
	got := map[int]int{}
	for _, p := range enumerateRunPatterns(maxEnumeratedRuns) {
		got[len(p)]++
		for i := 1; i < len(p); i++ {
			if p[i] == p[i-1] {
				t.Fatalf("%q has two adjacent runs of one hub — that is one run, not two", p)
			}
		}
	}
	for n, w := range want {
		if got[n] != w {
			t.Fatalf("length %d: enumerated %d patterns, want %d", n, got[n], w)
		}
	}
	if !strings.Contains(strings.Join(enumerateRunPatterns(maxEnumeratedRuns), " "), "ABAB") {
		t.Fatal("the enumeration must contain ABAB — it is the shape the whole exercise is about")
	}
}

// TestLabelsComeFromTheDefinition is the instrument's own calibration. The
// label function is the one thing in this lane that cannot be checked against a
// rule (checking it against a rule is exactly the circularity being avoided),
// so it is checked against the shapes the repo has ALREADY committed to being
// legal or corrupt, in production code and pinned tests, before this lane
// existed.
//
// If one of these fails, the instrument is wrong and every number produced with
// it is void.
func TestLabelsComeFromTheDefinition(t *testing.T) {
	want := map[string]bool{
		"LEGIT-01-linear-two-cities":          true,
		"LEGIT-02-genuine-revisit":            true,
		"LEGIT-03-shared-transition-day":      true,
		"LEGIT-04-day-trip-from-hub":          true,
		"LEGIT-05-hubless-between-runs":       true,
		"LEGIT-06-spine-empty-middles":        true,
		"LEGIT-07-undated-tail":               true,
		"LEGIT-08-diacritic-variance":         true,
		"LEGIT-09-five-cities":                true,
		"LEGIT-10-single-city":                true,
		"LEGIT-11-revisit-repeating-a-place":  true,
		"LEGIT-12-island-hop":                 true,
		"LEGIT-13-revisit-on-transition-day":  true,
		"CORRUPT-01-stale-trailing-run":       false,
		"CORRUPT-02-stale-leading-run":        false,
		"CORRUPT-03-days-backwards-no-repeat": false,
		"CORRUPT-04-four-cities-fragmented":   false,
	}
	for _, s := range knownShapes() {
		w, ok := want[s.ID]
		if !ok {
			continue
		}
		got, reason := legalSequenceOfStays(runItemsOfLocations(s.Locs))
		if got != w {
			t.Fatalf("%s: the definition says legal=%v, the repo has already committed to legal=%v — %s",
				s.ID, got, w, reason)
		}
	}
}
