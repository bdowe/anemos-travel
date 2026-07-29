package main

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"time"

	"travel-route-planner/store"
)

// local_recs_service.go serves published, locally-sourced recommendations to the
// agent and the public browse endpoints. It flattens the pin + its attribution
// (the named local) into one shape callers can hand straight to the client.

// LocalRec is the wire/agent shape: the pin plus who vouched for it.
type LocalRec struct {
	ID                string   `json:"id"`
	Name              string   `json:"name"`
	City              string   `json:"city"`
	Neighborhood      string   `json:"neighborhood,omitempty"`
	Category          string   `json:"category,omitempty"`
	Address           string   `json:"address,omitempty"`
	PlaceID           string   `json:"place_id,omitempty"`
	Latitude          *float64 `json:"latitude,omitempty"`
	Longitude         *float64 `json:"longitude,omitempty"`
	Tip               string   `json:"tip,omitempty"`
	Quote             string   `json:"quote,omitempty"`
	Tags              []string `json:"tags"`
	SourceName        string   `json:"source_name"`
	SourceBio         string   `json:"source_bio,omitempty"`
	SourcePhotoURL    string   `json:"source_photo_url,omitempty"`
	SourceExpertise   string   `json:"source_expertise,omitempty"`
	SourceCredibility string   `json:"source_credibility,omitempty"`

	// PhotoRef/PhotoAttribution are the VENUE's Google photo, resolved from
	// place_id by enrichLocalRecPhotos on the agent SSE path only — distinct
	// from SourcePhotoURL (the human recommender's headshot). omitempty keeps
	// the public /local/* browse responses, which never enrich, byte-identical.
	PhotoRef         string `json:"photo_ref,omitempty"`
	PhotoAttribution string `json:"photo_attribution,omitempty"`
}

// enrichLocalRecPhotos fills venue photo refs for recs that carry a place_id.
// Bounded concurrency (4 in flight) and a hard time-box keep a city full of
// uncached recs from holding the local_recs SSE event — and the agent loop
// behind it — hostage; the 24h photoRefCache makes every later turn free.
// Failures and photo-less venues are silently skipped (missing photo ≠ error).
func enrichLocalRecPhotos(ctx context.Context, recs []LocalRec) {
	ctx, cancel := context.WithTimeout(ctx, 2500*time.Millisecond)
	defer cancel()
	sem := make(chan struct{}, 4)
	var wg sync.WaitGroup
	for i := range recs {
		if recs[i].PlaceID == "" {
			continue
		}
		wg.Add(1)
		sem <- struct{}{}
		r := &recs[i]
		safeGo("enrichLocalRecPhotos", func() {
			defer wg.Done()
			defer func() { <-sem }()
			ref, attr, err := placesService.GetPlacePhotoRef(ctx, r.PlaceID)
			if err != nil || ref == "" {
				return
			}
			r.PhotoRef, r.PhotoAttribution = ref, attr
		})
	}
	wg.Wait()
}

// LocalRecsService is a stateless singleton (like eventsService) that reads the
// process-wide dbPool at call time.
type LocalRecsService struct{}

var localRecsService = &LocalRecsService{}

// SearchByCity returns published recommendations for a city, optionally filtered
// to a category ('attraction'/'restaurant'). Returns an empty slice in degraded
// mode rather than erroring, so the agent tool degrades gracefully.
func (s *LocalRecsService) SearchByCity(ctx context.Context, city, category string) ([]LocalRec, error) {
	if dbPool == nil {
		return []LocalRec{}, nil
	}
	rows, err := store.New(dbPool).ListPublishedRecommendationsByCity(ctx, city)
	if err != nil {
		return nil, err
	}
	category = strings.ToLower(strings.TrimSpace(category))
	out := make([]LocalRec, 0, len(rows))
	for _, r := range rows {
		if category != "" && (r.Category == nil || strings.ToLower(*r.Category) != category) {
			continue
		}
		out = append(out, localRecFromRow(r))
	}
	return out, nil
}

func localRecFromRow(r store.ListPublishedRecommendationsByCityRow) LocalRec {
	rec := LocalRec{
		ID:         r.ID.String(),
		Name:       r.Name,
		City:       r.City,
		Latitude:   r.Latitude,
		Longitude:  r.Longitude,
		Tags:       r.Tags,
		SourceName: r.SourceName,
	}
	if rec.Tags == nil {
		rec.Tags = []string{}
	}
	rec.Neighborhood = strPtrVal(r.Neighborhood)
	rec.Category = strPtrVal(r.Category)
	rec.Address = strPtrVal(r.Address)
	rec.PlaceID = strPtrVal(r.PlaceID)
	rec.Tip = strPtrVal(r.Tip)
	rec.Quote = strPtrVal(r.Quote)
	rec.SourceBio = strPtrVal(r.SourceBio)
	rec.SourcePhotoURL = strPtrVal(r.SourcePhotoUrl)
	rec.SourceExpertise = strPtrVal(r.SourceExpertise)
	rec.SourceCredibility = strPtrVal(r.SourceCredibility)
	return rec
}

// summarizeLocalRecs renders the recs into compact text for the model's tool
// result, always naming the local so the agent can cite them in prose. Each line
// carries the id so the model can pass local_recommendation_id into create_itinerary.
func summarizeLocalRecs(city string, recs []LocalRec) string {
	if len(recs) == 0 {
		return "No local recommendations are published for " + city + " yet. Fall back to search_places."
	}
	var b strings.Builder
	fmt.Fprintf(&b, "%d local recommendation(s) for %s (prefer these; cite the local by name):\n", len(recs), city)
	for _, r := range recs {
		fmt.Fprintf(&b, "- %s", r.Name)
		if r.Category != "" {
			fmt.Fprintf(&b, " (%s)", r.Category)
		}
		fmt.Fprintf(&b, " — recommended by %s", r.SourceName)
		if r.SourceCredibility != "" {
			fmt.Fprintf(&b, ", %s", r.SourceCredibility)
		}
		if r.Tip != "" {
			fmt.Fprintf(&b, ". Tip: %s", r.Tip)
		}
		fmt.Fprintf(&b, " [id=%s", r.ID)
		if r.Latitude != nil && r.Longitude != nil {
			fmt.Fprintf(&b, ", lat=%g, lng=%g", *r.Latitude, *r.Longitude)
		}
		if r.PlaceID != "" {
			fmt.Fprintf(&b, ", place_id=%s", r.PlaceID)
		}
		b.WriteString("]\n")
	}
	return b.String()
}
