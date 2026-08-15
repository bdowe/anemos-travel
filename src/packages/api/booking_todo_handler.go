package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/google/uuid"
	"github.com/gorilla/mux"
	"github.com/jackc/pgx/v5/pgtype"

	"travel-route-planner/store"
)

var allowedBookingKinds = map[string]bool{"stay": true, "transport": true, "other": true}

// allowedLegModes are the per-leg transport-mode overrides a transport todo
// accepts. Deliberately narrower than allowedSegmentModes: no "other" (a leg
// always has a concrete way to travel) and no "mixed" (mixed is the absence of
// a trip-wide mode, not a leg-level choice).
var allowedLegModes = map[string]bool{"flight": true, "car": true, "train": true, "bus": true, "ferry": true}

// transportModeLink maps a per-leg mode to its preferred provider and builds
// the matching search link. Ferry legs get a Ferryhopper deep link — the
// transport provider list has no ferry entry, so bookingSearchURL's fallback
// would silently store google_flights; ground modes prefer rome2rio; flight
// keeps the google_flights default. Returns ("", provider) when the link
// cannot be built (blank origin/destination).
func transportModeLink(mode, destination string, origin, departDate *string, passengers int) (string, string) {
	if strings.TrimSpace(strPtrVal(origin)) == "" || strings.TrimSpace(destination) == "" {
		return "", ""
	}
	if mode == "ferry" {
		return ferryService.ferryhopperURL(strPtrVal(origin), destination, strPtrVal(departDate)), "ferry"
	}
	preferred := "google_flights"
	if mode == "car" || mode == "train" || mode == "bus" {
		preferred = "rome2rio"
	}
	return bookingSearchURL("transport", destination, origin, departDate, nil, 0, passengers, &preferred)
}

type BookingTodoResponse struct {
	ID         string  `json:"id"`
	Kind       string  `json:"kind"`
	TodoKey    string  `json:"todo_key"`
	Title      string  `json:"title"`
	Subtitle   *string `json:"subtitle,omitempty"`
	Provider   *string `json:"provider,omitempty"`
	SearchURL  *string `json:"search_url,omitempty"`
	DepartDate *string `json:"depart_date,omitempty"`
	ReturnDate *string `json:"return_date,omitempty"`
	Mode       *string `json:"mode,omitempty"`
	// Which leg of the journey this row is: home_outbound | home_return |
	// inter_city | stay (booking_todo_identity.go). The server computes it as
	// identity; emitting it stops the client re-inferring "which row is the
	// flight home" — an inference that would be wrong in exactly the case the
	// server already handles, where a key collision demotes a home leg to
	// inter_city and no relabel will ever reach it.
	Role     *string `json:"role,omitempty"`
	Booked   bool    `json:"booked"`
	Auto     bool    `json:"auto"`
	Position int     `json:"position"`
}

func toBookingTodoResponse(t store.BookingTodo) BookingTodoResponse {
	return BookingTodoResponse{
		ID:   t.ID.String(),
		Kind: t.Kind,
		// The endpoint-labelled key, not the storage key — see
		// displayBookingTodoKey (booking_todo_identity.go).
		TodoKey:    displayBookingTodoKey(t),
		Title:      t.Title,
		Subtitle:   t.Subtitle,
		Provider:   t.Provider,
		SearchURL:  t.SearchUrl,
		DepartDate: dateToPtr(t.DepartDate),
		ReturnDate: dateToPtr(t.ReturnDate),
		Mode:       t.Mode,
		Role:       strPtrOrNil(strPtrVal(t.Role)),
		Booked:     t.Booked,
		Auto:       t.Auto,
		Position:   int(t.Position),
	}
}

// DerivedBookingTodo is one auto-generated checklist entry sent by the client.
// The client supplies the itinerary-derived metadata plus the inputs needed to
// build the search link; the server resolves search_url via the existing
// provider link builders so URL construction stays in one place.
type DerivedBookingTodo struct {
	Kind        string  `json:"kind"`
	TodoKey     string  `json:"todo_key"`
	Title       string  `json:"title"`
	Subtitle    *string `json:"subtitle"`
	Provider    *string `json:"provider"`
	Position    int     `json:"position"`
	DepartDate  *string `json:"depart_date"` // stay check-in / transport depart
	ReturnDate  *string `json:"return_date"` // stay check-out
	Destination string  `json:"destination"`
	Origin      *string `json:"origin"`
	Guests      int     `json:"guests"`
	Passengers  int     `json:"passengers"`
}

// bookingSearchURL resolves the search link for a derived/custom TODO using the
// shared provider builders. It returns the URL and the provider name actually
// used (which may differ from a requested provider if that one isn't available).
func bookingSearchURL(kind, destination string, origin *string, departDate, returnDate *string, guests, passengers int, preferred *string) (string, string) {
	pref := ""
	if preferred != nil {
		pref = *preferred
	}
	switch kind {
	case "stay":
		if strings.TrimSpace(destination) == "" {
			return "", ""
		}
		links := providerLinks(AccommodationQuery{
			Destination: destination,
			CheckIn:     strPtrVal(departDate),
			CheckOut:    strPtrVal(returnDate),
			Guests:      guests,
		})
		return pickProviderLink(links, pref)
	case "transport":
		o := strPtrVal(origin)
		if strings.TrimSpace(o) == "" || strings.TrimSpace(destination) == "" {
			return "", ""
		}
		// No mode filter: the candidate list must include ground providers
		// (rome2rio) so a ground-trip preference is honorable; the fallback
		// stays links[0] = google_flights, preserving legacy behavior when no
		// (or an unknown) provider is preferred.
		links := transportLinks(TransportQuery{
			Origin:      o,
			Destination: destination,
			DepartDate:  strPtrVal(departDate),
			Passengers:  passengers,
		})
		out := make([]ProviderLink, 0, len(links))
		for _, l := range links {
			out = append(out, ProviderLink{Provider: l.Provider, URL: l.URL})
		}
		return pickProviderLink(out, pref)
	default:
		return "", ""
	}
}

// pickProviderLink returns the URL+name for the preferred provider, falling back
// to the first available link.
func pickProviderLink(links []ProviderLink, preferred string) (string, string) {
	if len(links) == 0 {
		return "", ""
	}
	for _, l := range links {
		if l.Provider == preferred {
			return l.URL, l.Provider
		}
	}
	return links[0].URL, links[0].Provider
}

func strPtrVal(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func strPtrOrNil(s string) *string {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return &s
}

// syncBookingTodosHandler upserts the client's itinerary-derived auto-TODOs and
// prunes any auto rows whose legs no longer exist, preserving the booked flag
// across syncs. Returns the full ordered list.
//
// Two things happen here that the client cannot do for itself (00064):
// classifyDerivedTodos rewrites the two home legs onto their canonical @home
// keys, so whoever posts — a stale tab, an old cached bundle, a collaborator's
// device — lands on the SAME row; and the home legs' endpoint labels are then
// taken from the TRIP rather than from the poster, so a collaborator's saved
// airport can no longer retitle the owner's flights.
func syncBookingTodosHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	tripID := trip.ID
	var derived []DerivedBookingTodo
	if err := json.NewDecoder(r.Body).Decode(&derived); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}

	q := store.New(dbPool)
	idents := classifyDerivedTodos(derived)
	// The owner's saved airport is the last rung of the endpoint ladder, so it
	// is read only when a home leg exists and the trip states nothing itself.
	var departureLabel, arrivalLabel string
	if hasHomeLeg(idents) {
		var ownerHome *string
		if strings.TrimSpace(strPtrVal(trip.Origin)) == "" && strings.TrimSpace(strPtrVal(trip.OriginAirport)) == "" {
			if prefs, err := q.GetPreferences(r.Context(), trip.UserID); err == nil {
				ownerHome = prefs.HomeAirport
			}
		}
		departureLabel, arrivalLabel = tripEndpointLabels(trip, ownerHome)
	}
	// Adopt any home leg still stored under its endpoint-labelled key before
	// the upsert, so a row the 00064 backfill missed (or one an older binary
	// wrote mid-deploy) is RENAMED rather than pruned out from under its booked
	// flag. A no-op for every already-canonical row.
	for i, d := range derived {
		if !isHomeRole(idents[i].role) || idents[i].key == d.TodoKey {
			continue
		}
		if _, err := q.AdoptLegacyHomeBookingTodo(r.Context(), store.AdoptLegacyHomeBookingTodoParams{
			TripID: tripID, OldKey: d.TodoKey, NewKey: idents[i].key,
		}); err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not save booking todo")
			return
		}
	}
	keys := make([]string, 0, len(derived))
	// One batch upsert instead of a round trip per row. The batch statement
	// cannot touch the same (trip_id, todo_key) twice, so duplicate keys are
	// collapsed last-wins — the same final state sequential upserts produced.
	rows := make([]store.UpsertBookingTodoParams, 0, len(derived))
	rowIdx := make(map[string]int, len(derived))
	for i, d := range derived {
		kind := strings.TrimSpace(d.Kind)
		if !allowedBookingKinds[kind] || strings.TrimSpace(d.TodoKey) == "" || strings.TrimSpace(d.Title) == "" {
			writeJSONError(w, http.StatusBadRequest, "each todo needs a valid kind, todo_key, and title")
			return
		}
		depart, err := parseDateParam(d.DepartDate)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, "depart_date must be YYYY-MM-DD")
			return
		}
		ret, err := parseDateParam(d.ReturnDate)
		if err != nil {
			writeJSONError(w, http.StatusBadRequest, "return_date must be YYYY-MM-DD")
			return
		}
		ident := idents[i]
		// The endpoints actually stored. For the two home legs the trip's own
		// answer overrides whatever the posting device derived — that is the
		// whole point of holding the endpoints on the trip. Resolved BEFORE
		// the link builders so the search URL, the title and the labels can
		// never disagree with each other.
		origin, destination := d.Origin, d.Destination
		title := strings.TrimSpace(d.Title)
		switch {
		case ident.role == roleHomeOutbound && departureLabel != "":
			origin = &departureLabel
			title = departureLabel + " → " + destination
		case ident.role == roleHomeReturn && arrivalLabel != "":
			destination = arrivalLabel
			title = strPtrVal(origin) + " → " + arrivalLabel
		}
		url, provider := bookingSearchURL(kind, destination, origin, d.DepartDate, d.ReturnDate, d.Guests, d.Passengers, d.Provider)
		if kind == "transport" && strPtrVal(d.Provider) == "ferry" {
			// pickProviderLink has no ferry candidate, so the fallback would
			// store google_flights for a derived ferry leg; keep the ferry
			// provider and its Ferryhopper deep link instead.
			if u, p := transportModeLink("ferry", destination, origin, d.DepartDate, d.Passengers); u != "" {
				url, provider = u, p
			}
		}
		providerPtr := strPtrOrNil(provider)
		if providerPtr == nil {
			providerPtr = d.Provider
		}
		row := store.UpsertBookingTodoParams{
			TripID:           tripID,
			Kind:             kind,
			TodoKey:          ident.key,
			Title:            title,
			Subtitle:         d.Subtitle,
			Provider:         providerPtr,
			SearchUrl:        strPtrOrNil(url),
			DepartDate:       depart,
			ReturnDate:       ret,
			Position:         int32(d.Position),
			Role:             strPtrOrNil(ident.role),
			OriginLabel:      strPtrOrNil(strPtrVal(origin)),
			DestinationLabel: strPtrOrNil(destination),
		}
		if j, seen := rowIdx[ident.key]; seen {
			rows[j] = row
		} else {
			rowIdx[ident.key] = len(rows)
			rows = append(rows, row)
		}
		keys = append(keys, ident.key)
	}
	if len(rows) > 0 {
		if err := q.UpsertBookingTodosBatch(r.Context(), upsertBookingTodosBatchParams(tripID, rows)); err != nil {
			writeJSONError(w, http.StatusInternalServerError, "could not save booking todo")
			return
		}
	}

	// Demote before delete, and never the other way round: a stale row the
	// traveler has booked, given a mode, or spent money against becomes an
	// ordinary manual row (it then falls outside the DELETE, which only sees
	// auto rows) instead of being destroyed along with its expense link.
	if _, err := q.DemoteStaleAutoBookingTodos(r.Context(), store.DemoteStaleAutoBookingTodosParams{
		TripID: tripID,
		Keys:   keys,
	}); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not prune booking todos")
		return
	}
	if _, err := q.DeleteStaleAutoBookingTodos(r.Context(), store.DeleteStaleAutoBookingTodosParams{
		TripID: tripID,
		Keys:   keys,
	}); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not prune booking todos")
		return
	}

	writeBookingTodos(w, r, tripID)
}

// hasHomeLeg reports whether any posted row was recognized as a journey
// endpoint — the only case where the trip's endpoint labels are needed.
func hasHomeLeg(idents []derivedIdentity) bool {
	for _, id := range idents {
		if isHomeRole(id.role) {
			return true
		}
	}
	return false
}

// upsertBookingTodosBatchParams flattens per-row upsert params into the
// parallel arrays UpsertBookingTodosBatch takes. sqlc types text[] as
// []string (no NULL elements), so each nullable text column travels as a
// value array plus a bool null mask — the statement restores NULLs, keeping
// stored rows byte-identical to what per-row UpsertBookingTodo wrote.
func upsertBookingTodosBatchParams(tripID uuid.UUID, rows []store.UpsertBookingTodoParams) store.UpsertBookingTodosBatchParams {
	p := store.UpsertBookingTodosBatchParams{
		TripID:         tripID,
		Kinds:          make([]string, len(rows)),
		TodoKeys:       make([]string, len(rows)),
		Titles:         make([]string, len(rows)),
		Subtitles:      make([]string, len(rows)),
		SubtitleNulls:  make([]bool, len(rows)),
		Providers:      make([]string, len(rows)),
		ProviderNulls:  make([]bool, len(rows)),
		SearchUrls:     make([]string, len(rows)),
		SearchUrlNulls: make([]bool, len(rows)),
		DepartDates:    make([]pgtype.Date, len(rows)),
		ReturnDates:    make([]pgtype.Date, len(rows)),
		Positions:      make([]int32, len(rows)),
		// role/origin_label/destination_label need no null mask: the statement
		// NULLIFs the empty string, and a label has no meaningful empty value.
		Roles:             make([]string, len(rows)),
		OriginLabels:      make([]string, len(rows)),
		DestinationLabels: make([]string, len(rows)),
	}
	for i, r := range rows {
		p.Kinds[i] = r.Kind
		p.TodoKeys[i] = r.TodoKey
		p.Titles[i] = r.Title
		if r.Subtitle != nil {
			p.Subtitles[i] = *r.Subtitle
		} else {
			p.SubtitleNulls[i] = true
		}
		if r.Provider != nil {
			p.Providers[i] = *r.Provider
		} else {
			p.ProviderNulls[i] = true
		}
		if r.SearchUrl != nil {
			p.SearchUrls[i] = *r.SearchUrl
		} else {
			p.SearchUrlNulls[i] = true
		}
		p.DepartDates[i] = r.DepartDate
		p.ReturnDates[i] = r.ReturnDate
		p.Positions[i] = r.Position
		p.Roles[i] = strPtrVal(r.Role)
		p.OriginLabels[i] = strPtrVal(r.OriginLabel)
		p.DestinationLabels[i] = strPtrVal(r.DestinationLabel)
	}
	return p
}

type AddBookingTodoRequest struct {
	Kind        string  `json:"kind"`
	Title       string  `json:"title"`
	Provider    *string `json:"provider"`
	SearchURL   *string `json:"search_url"`
	Subtitle    *string `json:"subtitle"`
	Destination *string `json:"destination"`
	Origin      *string `json:"origin"`
	DepartDate  *string `json:"depart_date"`
	ReturnDate  *string `json:"return_date"`
	Guests      int     `json:"guests"`
	Passengers  int     `json:"passengers"`
}

// addBookingTodoHandler creates a user-defined (auto=false) checklist entry. A
// search_url may be supplied directly, or built from a destination via the
// provider link builders.
func addBookingTodoHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	tripID := trip.ID
	var req AddBookingTodoRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	kind := strings.TrimSpace(req.Kind)
	if !allowedBookingKinds[kind] {
		writeJSONError(w, http.StatusBadRequest, "kind must be one of: stay, transport, other")
		return
	}
	if strings.TrimSpace(req.Title) == "" {
		writeJSONError(w, http.StatusBadRequest, "title is required")
		return
	}
	if _, err := boundedString("title", req.Title, maxNameLen); err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := boundedOptional("subtitle", req.Subtitle, maxNameLen); err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := boundedOptional("provider", req.Provider, maxProviderLen); err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	if err := boundedOptional("search_url", req.SearchURL, maxURLLen); err != nil {
		writeJSONError(w, http.StatusBadRequest, err.Error())
		return
	}
	depart, err := parseDateParam(req.DepartDate)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "depart_date must be YYYY-MM-DD")
		return
	}
	ret, err := parseDateParam(req.ReturnDate)
	if err != nil {
		writeJSONError(w, http.StatusBadRequest, "return_date must be YYYY-MM-DD")
		return
	}
	if existing, err := store.New(dbPool).ListBookingTodosByTrip(r.Context(), tripID); err == nil &&
		len(existing) >= maxBookingTodosPerTrip() {
		writeJSONError(w, http.StatusUnprocessableEntity,
			fmt.Sprintf("booking todo limit reached (max %d) — remove one first", maxBookingTodosPerTrip()))
		return
	}

	url := strPtrVal(req.SearchURL)
	provider := strPtrVal(req.Provider)
	if strings.TrimSpace(url) == "" && req.Destination != nil {
		url, provider = bookingSearchURL(kind, strPtrVal(req.Destination), req.Origin, req.DepartDate, req.ReturnDate, req.Guests, req.Passengers, req.Provider)
	}

	todo, err := store.New(dbPool).CreateBookingTodo(r.Context(), store.CreateBookingTodoParams{
		TripID:     tripID,
		Kind:       kind,
		TodoKey:    "custom:" + uuid.NewString(),
		Title:      strings.TrimSpace(req.Title),
		Subtitle:   req.Subtitle,
		Provider:   strPtrOrNil(provider),
		SearchUrl:  strPtrOrNil(url),
		DepartDate: depart,
		ReturnDate: ret,
		Position:   9999,
	})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not save booking todo")
		return
	}
	// Best-effort attribution/freshness bump — the todo itself committed.
	// (syncBookingTodosHandler must NEVER stamp: it runs on every trip load.)
	_ = store.New(dbPool).TouchTrip(r.Context(), touchedBy(tripID, r))
	writeJSON(w, http.StatusCreated, toBookingTodoResponse(todo))
}

// PatchBookingTodoRequest is a partial update. Booked-only requests (the
// original contract) work on any row, including auto ones; content fields
// apply to custom (auto = false) rows only. destination/origin are never
// persisted — when a destination is present and no explicit search_url, the
// search link + provider are rebuilt via bookingSearchURL, like the add path.
// Mode is a third, standalone lane (transport rows only, auto included): it
// stores the per-leg override and rebuilds provider + search_url to match,
// without ever touching booked/auto — it cannot be combined with other fields.
type PatchBookingTodoRequest struct {
	Mode        *string `json:"mode"`
	Booked      *bool   `json:"booked"`
	Kind        *string `json:"kind"`
	Title       *string `json:"title"`
	Subtitle    *string `json:"subtitle"`
	Destination *string `json:"destination"`
	Origin      *string `json:"origin"`
	DepartDate  *string `json:"depart_date"`
	ReturnDate  *string `json:"return_date"`
	SearchURL   *string `json:"search_url"`
	Provider    *string `json:"provider"`
	Guests      int     `json:"guests"`
	Passengers  int     `json:"passengers"`
}

func (req *PatchBookingTodoRequest) hasContentEdit() bool {
	return req.Kind != nil || req.Title != nil || req.Subtitle != nil ||
		req.Destination != nil || req.DepartDate != nil || req.ReturnDate != nil ||
		req.SearchURL != nil
}

func patchBookingTodoHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	tripID := trip.ID
	todoID, err := uuid.Parse(mux.Vars(r)["todoId"])
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "booking todo not found")
		return
	}
	var req PatchBookingTodoRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}

	var todo store.BookingTodo
	if req.Mode != nil {
		// origin/destination/depart_date/passengers are the link-rebuild
		// inputs (never persisted, as everywhere else); everything that would
		// actually edit content — or flip booked — is rejected alongside mode.
		if req.Kind != nil || req.Title != nil || req.Subtitle != nil ||
			req.ReturnDate != nil || req.SearchURL != nil || req.Booked != nil {
			writeJSONError(w, http.StatusBadRequest, "mode cannot be combined with other fields")
			return
		}
		mode := strings.TrimSpace(*req.Mode)
		if !allowedLegModes[mode] {
			writeJSONError(w, http.StatusBadRequest, "mode must be one of: flight, car, train, bus, ferry")
			return
		}
		url, provider := transportModeLink(mode, strPtrVal(req.Destination), req.Origin, req.DepartDate, req.Passengers)
		if url == "" {
			writeJSONError(w, http.StatusBadRequest, "origin and destination are required to set mode")
			return
		}
		// kind = 'transport' is enforced in the query's WHERE; a stay/other
		// row (or a foreign id) falls through to the shared 404 below.
		todo, err = store.New(dbPool).SetBookingTodoMode(r.Context(), store.SetBookingTodoModeParams{
			ID:        todoID,
			TripID:    tripID,
			Mode:      &mode,
			Provider:  strPtrOrNil(provider),
			SearchUrl: strPtrOrNil(url),
		})
	} else if !req.hasContentEdit() {
		// Booked-only: must stay on SetBookingTodoBooked — UpdateBookingTodo
		// excludes auto rows, but the checkbox works on itinerary-derived
		// todos too.
		if req.Booked == nil {
			writeJSONError(w, http.StatusBadRequest, "booked is required")
			return
		}
		todo, err = store.New(dbPool).SetBookingTodoBooked(r.Context(), store.SetBookingTodoBookedParams{
			ID:     todoID,
			TripID: tripID,
			Booked: *req.Booked,
		})
	} else {
		var kind, title *string
		if req.Kind != nil {
			k := strings.TrimSpace(*req.Kind)
			if !allowedBookingKinds[k] {
				writeJSONError(w, http.StatusBadRequest, "kind must be one of: stay, transport, other")
				return
			}
			kind = &k
		}
		if req.Title != nil {
			t := strings.TrimSpace(*req.Title)
			if t == "" {
				writeJSONError(w, http.StatusBadRequest, "title cannot be empty")
				return
			}
			if _, err := boundedString("title", t, maxNameLen); err != nil {
				writeJSONError(w, http.StatusBadRequest, err.Error())
				return
			}
			title = &t
		}
		if err := boundedOptional("subtitle", req.Subtitle, maxNameLen); err != nil {
			writeJSONError(w, http.StatusBadRequest, err.Error())
			return
		}
		if err := boundedOptional("search_url", req.SearchURL, maxURLLen); err != nil {
			writeJSONError(w, http.StatusBadRequest, err.Error())
			return
		}
		depart, derr := parseDateParam(req.DepartDate)
		if derr != nil {
			writeJSONError(w, http.StatusBadRequest, "depart_date must be YYYY-MM-DD")
			return
		}
		ret, rerr := parseDateParam(req.ReturnDate)
		if rerr != nil {
			writeJSONError(w, http.StatusBadRequest, "return_date must be YYYY-MM-DD")
			return
		}

		url := strPtrVal(req.SearchURL)
		provider := strPtrVal(req.Provider)
		if strings.TrimSpace(url) == "" && req.Destination != nil {
			if kind == nil {
				writeJSONError(w, http.StatusBadRequest, "kind is required when destination is set")
				return
			}
			url, provider = bookingSearchURL(*kind, strPtrVal(req.Destination), req.Origin, req.DepartDate, req.ReturnDate, req.Guests, req.Passengers, req.Provider)
		}

		todo, err = store.New(dbPool).UpdateBookingTodo(r.Context(), store.UpdateBookingTodoParams{
			ID:         todoID,
			TripID:     tripID,
			Kind:       kind,
			Title:      title,
			Subtitle:   req.Subtitle,
			DepartDate: depart,
			ReturnDate: ret,
			SearchUrl:  strPtrOrNil(url),
			Provider:   strPtrOrNil(provider),
			Booked:     req.Booked,
		})
	}
	if err != nil {
		// Wrong id, wrong trip, or a content edit on an auto row.
		writeJSONError(w, http.StatusNotFound, "booking todo not found")
		return
	}
	if req.Booked != nil && *req.Booked {
		user, _ := userFromContext(r.Context())
		// The endpoint-labelled key, so this event stays comparable with the
		// years of booking_marked_booked rows recorded before 00064.
		meta := map[string]any{"kind": todo.Kind, "todo_key": displayBookingTodoKey(todo)}
		if todo.Provider != nil {
			meta["provider"] = *todo.Provider
		}
		safeGo("recordEvent", func() { recordEvent(user.ID, "booking_marked_booked", &tripID, meta) })
	}
	_ = store.New(dbPool).TouchTrip(r.Context(), touchedBy(tripID, r))
	writeJSON(w, http.StatusOK, toBookingTodoResponse(todo))
}

type ReorderBookingTodosRequest struct {
	TodoIDs []string `json:"todo_ids"`
}

// reorderBookingTodosHandler reassigns positions 0..n-1 to the submitted todo
// ids — a subset of the trip's todos, not a full permutation. The client only
// sends its draggable residual ("Other bookings") list: city-grouped todos
// render slot-matched by todo_key regardless of position, and their positions
// are re-upserted from the derived payload on every sync anyway. Residual rows
// are durably custom (auto = false), which sync never rewrites, so the order
// set here sticks.
func reorderBookingTodosHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	tripID := trip.ID
	var req ReorderBookingTodosRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "invalid JSON")
		return
	}
	if len(req.TodoIDs) == 0 {
		writeJSONError(w, http.StatusBadRequest, "todo_ids is required")
		return
	}

	ctx := r.Context()
	tx, err := dbPool.Begin(ctx)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not reorder booking todos")
		return
	}
	defer tx.Rollback(ctx)
	q := store.New(tx)

	// Serialize against concurrent syncs/reorders so the stale-set 409 below
	// stays reliable between this read and commit.
	if _, err := q.GetTripForUpdate(ctx, tripID); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not reorder booking todos")
		return
	}
	todos, err := q.ListBookingTodosByTrip(ctx, tripID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load booking todos")
		return
	}
	existing := make(map[uuid.UUID]bool, len(todos))
	for _, t := range todos {
		existing[t.ID] = true
	}
	ordered := make([]uuid.UUID, 0, len(req.TodoIDs))
	seen := make(map[uuid.UUID]bool, len(req.TodoIDs))
	for _, raw := range req.TodoIDs {
		id, err := uuid.Parse(raw)
		if err != nil || !existing[id] || seen[id] {
			writeJSONError(w, http.StatusConflict, "booking list is out of date; reload the trip")
			return
		}
		seen[id] = true
		ordered = append(ordered, id)
	}
	positions := make([]int32, len(ordered))
	for pos := range ordered {
		positions[pos] = int32(pos)
	}
	if err := q.SetBookingTodoPositionsBatch(ctx, store.SetBookingTodoPositionsBatchParams{
		TripID: tripID, Ids: ordered, Positions: positions,
	}); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not reorder booking todos")
		return
	}
	if err := q.TouchTrip(ctx, touchedBy(tripID, r)); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not reorder booking todos")
		return
	}
	if err := tx.Commit(ctx); err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not reorder booking todos")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func deleteBookingTodoHandler(w http.ResponseWriter, r *http.Request) {
	trip, ok := editableTrip(w, r)
	if !ok {
		return
	}
	tripID := trip.ID
	todoID, err := uuid.Parse(mux.Vars(r)["todoId"])
	if err != nil {
		writeJSONError(w, http.StatusNotFound, "booking todo not found")
		return
	}
	rows, err := store.New(dbPool).DeleteBookingTodo(r.Context(),
		store.DeleteBookingTodoParams{ID: todoID, TripID: tripID})
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not delete booking todo")
		return
	}
	if rows == 0 {
		writeJSONError(w, http.StatusNotFound, "booking todo not found")
		return
	}
	_ = store.New(dbPool).TouchTrip(r.Context(), touchedBy(tripID, r))
	w.WriteHeader(http.StatusNoContent)
}

func writeBookingTodos(w http.ResponseWriter, r *http.Request, tripID uuid.UUID) {
	todos, err := store.New(dbPool).ListBookingTodosByTrip(r.Context(), tripID)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "could not load booking todos")
		return
	}
	resp := make([]BookingTodoResponse, 0, len(todos))
	for _, t := range todos {
		resp = append(resp, toBookingTodoResponse(t))
	}
	writeJSON(w, http.StatusOK, resp)
}
