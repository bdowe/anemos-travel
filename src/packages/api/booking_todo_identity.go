package main

import (
	"strings"

	"travel-route-planner/store"
)

// booking_todo_identity.go — what makes a derived checklist row THE SAME ROW
// across syncs (migration 00064).
//
// A derived leg used to be identified by its endpoint labels:
// `transport:<origin>>><dest>`, where the origin token was whatever the
// renderer had on hand — trips.origin, or failing that the VIEWER's saved home
// airport. Label and identity were the same string, so changing the label
// changed the key, and the prune deleted the row: booked flag, per-leg mode
// override, manual position and the linked expense's source all went with it.
// That fired on an ordinary Settings edit of a home airport, and on any
// collaborator opening a shared trip.
//
// Now the two home legs key on a reserved token whose POSITION carries the
// direction, and the labels are content:
//
//	home_outbound  transport:@home>>amsterdam   origin_label="ALB"
//	home_return    transport:rome>>@home        destination_label="EWR"
//	inter_city     transport:paris>>rome        (key unchanged)
//	stay           stay:paris                   (key unchanged)
//
// Because the key no longer names an airport, changing one is an in-place
// title/label update that UpsertBookingTodosBatch already performs — booked,
// auto and mode are deliberately outside its DO UPDATE set. And because the
// token's position distinguishes the directions, a trip can leave from ALB and
// come home into EWR without the two legs colliding.
//
// The canonical form is computed HERE, server-side, from the posted payload —
// never sent by the client. That is what makes a stale tab, an old cached
// bundle, or a collaborator's device land on the same row instead of pruning
// it, and it is why this change needs no client flag day.
//
// The client is deliberately NOT asked to label its own rows. It would be the
// more direct source ("refuse the temptation to guess"), but a posted role is
// a second writer of identity that every old bundle would omit anyway, so the
// inference below has to exist and be correct regardless — and two paths that
// can disagree is the failure mode this file exists to end. The inference is
// not really a guess: it is a total function of the payload, using the rule
// stayCitySet already applies, over rows the client builds outbound-first and
// return-last.

// homeEndpointToken stands in for "wherever this trip starts or ends" inside a
// derived transport key. `@` rather than a bare word: namesAPlace accepts
// "home" as a city name and would leak it into traveler-facing copy, while `@`
// cannot occur in an IATA code or a Google Places city label — so one prefix
// guard covers every reserved token we ever add.
const homeEndpointToken = "@home"

// The closed vocabulary of booking_todos.role. Home roles are paired with the
// key shape by CHECK constraints (00064), so a wrong canonicalization fails at
// write time instead of storing a plausible-looking wrong row.
const (
	roleHomeOutbound = "home_outbound"
	roleHomeReturn   = "home_return"
	roleInterCity    = "inter_city"
	roleStay         = "stay"
)

// transportTodoKey builds a derived transport row's key from its two endpoint
// tokens. The single definition of the `transport:a>>b` grammar — its Dart twin
// is _deriveTodos in trip_detail_screen.dart, pinned by the parity fixtures.
func transportTodoKey(origin, destination string) string {
	return "transport:" + strings.ToLower(strings.TrimSpace(origin)) + ">>" + strings.ToLower(strings.TrimSpace(destination))
}

// isDerivedTransportKey reports whether a key speaks the itinerary-derived leg
// grammar (`transport:<a>>><b>`). Custom, agent-added and legacy rows use other
// shapes and are left exactly as posted.
func isDerivedTransportKey(key string) bool {
	rest, ok := strings.CutPrefix(key, "transport:")
	if !ok {
		return false
	}
	a, b, found := strings.Cut(rest, ">>")
	return found && a != "" && b != ""
}

// isHomeRole reports whether a role names one of the two journey endpoints.
func isHomeRole(role string) bool {
	return role == roleHomeOutbound || role == roleHomeReturn
}

// derivedIdentity is one posted row's canonical identity.
type derivedIdentity struct {
	role string
	// key is the STORAGE key. It differs from what the client posted only for
	// the two home legs; displayBookingTodoKey maps it back for the wire.
	key string
}

// classifyDerivedTodos assigns a role and a canonical storage key to every
// posted row, in posted order.
//
// The rule is the one stayCitySet already states for generating copy — a
// transport endpoint outside the trip's stay cities is a home leg, and an EMPTY
// stay set never reads as home — promoted here from copy-generation to
// identity, so there is one definition rather than two that can drift. It is
// restricted to the FIRST and LAST transport row because that is
// _deriveTodos' construction order: outbound before the city loop, return
// after it.
//
// Everything is computed from the payload alone, with no reference to the
// trip's current origin or the traveler's saved airport, so a sync that races
// an origin change still lands on the same row.
func classifyDerivedTodos(derived []DerivedBookingTodo) []derivedIdentity {
	out := make([]derivedIdentity, len(derived))
	stayCities := make(map[string]bool)
	transportIdx := make([]int, 0, len(derived))
	for i, d := range derived {
		kind := strings.TrimSpace(d.Kind)
		out[i] = derivedIdentity{role: roleInterCity, key: d.TodoKey}
		switch kind {
		case "stay":
			out[i].role = roleStay
			if c := strings.ToLower(strings.TrimSpace(d.Destination)); c != "" {
				stayCities[c] = true
			}
		case "transport":
			// Only rows that already speak the derived-leg grammar are
			// candidates. A transport row keyed some other way is not part of
			// the itinerary derivation (an agent- or hand-added leg, or an
			// older client's private key), so rewriting its identity would be
			// a rename nobody asked for — and it must not count toward
			// "first"/"last" either.
			if isDerivedTransportKey(d.TodoKey) {
				transportIdx = append(transportIdx, i)
			}
		default:
			// "other" rows carry no leg semantics; role stays inter_city and
			// the key is whatever the client sent.
			out[i].role = ""
		}
	}
	// No stay rows means no itinerary to be outside of, so nothing can be
	// recognized as a home leg. Guessing here is how an inter-city leg would
	// get promoted to "the flight home".
	if len(stayCities) == 0 || len(transportIdx) == 0 {
		return out
	}

	classify := func(i int, first, last bool) {
		d := derived[i]
		o := strings.ToLower(strings.TrimSpace(strPtrVal(d.Origin)))
		dest := strings.ToLower(strings.TrimSpace(d.Destination))
		if o == "" || dest == "" {
			return
		}
		// Outbound is checked first, so a lone transport row whose BOTH
		// endpoints sit outside the itinerary reads as the departure.
		if first && !stayCities[o] {
			out[i] = derivedIdentity{role: roleHomeOutbound, key: transportTodoKey(homeEndpointToken, dest)}
			return
		}
		if last && !stayCities[dest] {
			out[i] = derivedIdentity{role: roleHomeReturn, key: transportTodoKey(o, homeEndpointToken)}
		}
	}
	firstT, lastT := transportIdx[0], transportIdx[len(transportIdx)-1]
	classify(firstT, true, firstT == lastT)
	if lastT != firstT {
		classify(lastT, false, true)
	}

	// Canonicalization must never make two rows collide: the batch upsert
	// collapses duplicate keys last-wins, which would silently drop a leg.
	// A loser keeps the literal key the client posted and reads as inter_city
	// — never a home role with a non-canonical key, which the CHECK
	// constraints would reject. The migration's backfill has the identical
	// fallback, so the two paths agree.
	seen := make(map[string]int, len(out))
	for i := range out {
		key := out[i].key
		if prev, dup := seen[key]; dup && prev != i {
			if isHomeRole(out[i].role) {
				out[i] = derivedIdentity{role: roleInterCity, key: derived[i].TodoKey}
			}
			continue
		}
		seen[key] = i
	}
	return out
}

// tripEndpointLabels returns the labels this trip's two home legs must carry,
// one explicit ladder per direction:
//
//	that direction's airport -> the origin the traveler stated in words -> the
//	trip OWNER's saved home airport
//
// The owner's, never the viewer's: a collaborator's device re-deriving with
// their own airport is how a shared trip's legs used to get rewritten out from
// under its owner. Empty means "nothing to say", and the label the client
// posted is then left alone.
//
// origin_airport and return_airport are written together or not at all (CHECK
// trips_endpoint_airport_pair), so NULL here never has to be read as "same as
// the other direction" — it means only that this trip never stated an airport.
func tripEndpointLabels(trip store.Trip, ownerHomeAirport *string) (departure, arrival string) {
	stated := strings.TrimSpace(strPtrVal(trip.Origin))
	home := strings.TrimSpace(strPtrVal(ownerHomeAirport))
	pick := func(airport *string) string {
		if code := strings.TrimSpace(strPtrVal(airport)); code != "" {
			return strings.ToUpper(code)
		}
		if stated != "" {
			return stated
		}
		return home
	}
	return pick(trip.OriginAirport), pick(trip.ReturnAirport)
}

// displayBookingTodoKey maps a storage key back to the endpoint-labelled key
// the client derives and matches on (its per-leg mode overrides, its Find
// Flights prefill, and the analytics todo_key history are all keyed that way).
// Storage key = identity; wire key = display.
//
// This is a deliberate divergence — two spellings of one key — and it is the
// price of changing identity without a client flag day. It dies at the
// specs/server-booking-todos flip, when the client stops deriving keys at all;
// keep it to this one function so that deletion is a one-file diff.
func displayBookingTodoKey(t store.BookingTodo) string {
	if !isHomeRole(strPtrVal(t.Role)) {
		return t.TodoKey
	}
	o, d := strings.TrimSpace(strPtrVal(t.OriginLabel)), strings.TrimSpace(strPtrVal(t.DestinationLabel))
	if o == "" || d == "" {
		return t.TodoKey
	}
	return transportTodoKey(o, d)
}
