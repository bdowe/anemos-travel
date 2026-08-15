package main

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"
)

// specs/traveler-baggage — the payoff of the whole feature: the traveler says
// once what they fly with, and the fares the planner quotes cover it. The model
// is NOT asked to carry the tier over from the system prompt; the dispatcher
// resolves it, so a turn where the model says nothing about bags still prices
// them.

func runFlightsTool(t *testing.T, s *planSession, input string) string {
	t.Helper()
	text, isErr := runSearchFlightsTool(s, json.RawMessage(input))
	if isErr {
		t.Fatalf("search_flights errored: %s", text)
	}
	return text
}

// sseBaggage pulls the tier off the `flights` side event the chat receives.
func sseBaggage(t *testing.T, body string) string {
	t.Helper()
	for _, line := range strings.Split(body, "\n") {
		data, ok := strings.CutPrefix(line, "data: ")
		if !ok {
			continue
		}
		// sendSSE nests the payload: {"type":"flights","data":{...}}.
		var ev struct {
			Type string `json:"type"`
			Data struct {
				Baggage string `json:"baggage"`
			} `json:"data"`
		}
		if err := json.Unmarshal([]byte(data), &ev); err == nil && ev.Type == "flights" {
			return ev.Data.Baggage
		}
	}
	t.Fatalf("no flights SSE event in:\n%s", body)
	return ""
}

func TestSearchFlightsUsesSavedBaggagePreference(t *testing.T) {
	cases := []struct {
		name  string
		saved *string
		input string
		want  string
	}{
		{"saved tier fills an omitted one", strPtr(baggageChecked),
			`{"origin":"AAA","destination":"BBB","depart_date":"2026-09-01"}`, baggageChecked},
		{"stated tier wins over the profile", strPtr(baggageChecked),
			`{"origin":"AAA","destination":"BBB","depart_date":"2026-09-01","baggage":"personal_item"}`, baggagePersonalItem},
		{"no profile means a cabin bag", nil,
			`{"origin":"AAA","destination":"BBB","depart_date":"2026-09-01"}`, baggageCarryOn},
		// An invented tier must not silently mean carry_on, which is what the
		// unvalidated pass-through used to do.
		{"invented tier falls back to the profile", strPtr(baggagePersonalItem),
			`{"origin":"AAA","destination":"BBB","depart_date":"2026-09-01","baggage":"suitcase"}`, baggagePersonalItem},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			swapSerpapiStub(t, func(w http.ResponseWriter, r *http.Request) {
				w.Write([]byte(serpapiBody([]string{
					serpapiItem(300, 120, [6]string{"AAA", "BBB", "TestAir", "TA 1", "2026-09-01 08:00", "2026-09-01 10:00"}),
				}, nil)))
			})
			s, rec := testPlanSession(true, uuid.New())
			s.bagPref = tc.saved

			text := runFlightsTool(t, s, tc.input)
			if got := sseBaggage(t, rec.Body.String()); got != tc.want {
				t.Fatalf("flights event baggage = %q, want %q", got, tc.want)
			}
			// The model's prose is the traveler's only record of what a fare
			// covers, so the tool result has to state the same basis.
			wantPhrase := map[string]string{
				baggagePersonalItem: "bare fares covering a personal item only",
				baggageCarryOn:      "prices cover a cabin bag",
				baggageChecked:      "NOT the checked-bag fee",
			}[tc.want]
			if !strings.Contains(text, wantPhrase) {
				t.Fatalf("tool result missing %q:\n%s", wantPhrase, text)
			}
		})
	}
}

// The saved tier reaches the PROVIDER, not just the labels: with the swap
// active that means Google prices the cabin bag into the quote, which is the
// only bag pricing available while the Duffel token is test-mode.
func TestSearchFlightsPricesBagsForSavedPreference(t *testing.T) {
	var query map[string]string
	swapSerpapiStub(t, func(w http.ResponseWriter, r *http.Request) {
		query = map[string]string{}
		for k, v := range r.URL.Query() {
			query[k] = v[0]
		}
		w.Write([]byte(serpapiBody([]string{
			serpapiItem(300, 120, [6]string{"AAA", "BBB", "TestAir", "TA 1", "2026-09-01 08:00", "2026-09-01 10:00"}),
		}, nil)))
	})
	s, _ := testPlanSession(true, uuid.New())
	s.bagPref = strPtr(baggageCarryOn)

	runFlightsTool(t, s, `{"origin":"AAA","destination":"BBB","depart_date":"2026-09-01","adults":2}`)
	if query["bags"] != "2" {
		t.Fatalf("bags = %q, want 2 (one per traveler)", query["bags"])
	}
}

// A traveler who says they travel light gets the bare fares back — the default
// is a fallback, not a policy.
func TestSearchFlightsPersonalItemSendsNoBags(t *testing.T) {
	var query map[string]string
	swapSerpapiStub(t, func(w http.ResponseWriter, r *http.Request) {
		query = map[string]string{}
		for k, v := range r.URL.Query() {
			query[k] = v[0]
		}
		w.Write([]byte(serpapiBody([]string{
			serpapiItem(300, 120, [6]string{"AAA", "BBB", "TestAir", "TA 1", "2026-09-01 08:00", "2026-09-01 10:00"}),
		}, nil)))
	})
	s, _ := testPlanSession(true, uuid.New())
	s.bagPref = strPtr(baggagePersonalItem)

	runFlightsTool(t, s, `{"origin":"AAA","destination":"BBB","depart_date":"2026-09-01"}`)
	if _, ok := query["bags"]; ok {
		t.Fatalf("bags = %q, want absent on a bare-fare search", query["bags"])
	}
}
