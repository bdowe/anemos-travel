package main

// PATCH /trips/{id}'s `summary` — the trip page's half of specs/trip-description.
// The interesting cases are the ones UpdateTrip's COALESCE set could not express
// (an explicit clear) and the ones a second write implementation would get wrong
// (parity with the chat tool).

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"
)

func TestPatchTripSetsAndClearsDescription(t *testing.T) {
	requireDB(t)
	resetDB(t)
	user, token := createTestUser(t, "patchdesc@example.com")
	trip := createTestTrip(t, user.ID, 1)
	id := trip.ID.String()

	rec := doJSON(t, "PATCH", "/api/v1/trips/"+id, token,
		map[string]any{"summary": "  Ten days circling Sicily.  "})
	if rec.Code != http.StatusOK {
		t.Fatalf("set summary = %d: %s", rec.Code, rec.Body.String())
	}
	// The response is the post-state, not an echo: the handler writes the summary
	// inside the same transaction as UpdateTrip so its RETURNING row carries it.
	if got, _ := decode(t, rec)["summary"].(string); got != "Ten days circling Sicily." {
		t.Fatalf("response summary = %q, want the trimmed description", got)
	}
	got, source := summaryOf(t, id)
	if got == nil || *got != "Ten days circling Sicily." {
		t.Fatalf("stored summary = %v", got)
	}
	if source == nil || *source != summarySourceTraveler {
		t.Fatalf("summary_source = %v, want %q — the page's writes are the traveler's", source, summarySourceTraveler)
	}

	// The case UpdateTrip's COALESCE could never express. An omitted key still
	// means "leave it alone", so the two must not be conflated.
	rec = doJSON(t, "PATCH", "/api/v1/trips/"+id, token, map[string]any{"title": "Sicily"})
	if rec.Code != http.StatusOK {
		t.Fatalf("patch title = %d: %s", rec.Code, rec.Body.String())
	}
	if got, _ := summaryOf(t, id); got == nil {
		t.Fatal("an omitted summary key cleared the description")
	}

	rec = doJSON(t, "PATCH", "/api/v1/trips/"+id, token, map[string]any{"summary": ""})
	if rec.Code != http.StatusOK {
		t.Fatalf("clear summary = %d: %s", rec.Code, rec.Body.String())
	}
	if _, ok := decode(t, rec)["summary"]; ok {
		t.Fatal("a cleared description still rides the response")
	}
	got, source = summaryOf(t, id)
	if got != nil {
		t.Fatalf("stored summary = %v, want NULL — \"\" is one representation of empty, not a second", got)
	}
	// NULL prose + 'traveler' source is the pair that says "removed on purpose".
	if source == nil || *source != summarySourceTraveler {
		t.Fatalf("summary_source = %v, want %q so the planner leaves it removed", source, summarySourceTraveler)
	}
}

func TestPatchTripRejectsOverlongDescription(t *testing.T) {
	requireDB(t)
	resetDB(t)
	user, token := createTestUser(t, "patchdesclong@example.com")
	trip := createTestTrip(t, user.ID, 0)

	rec := doJSON(t, "PATCH", "/api/v1/trips/"+trip.ID.String(), token,
		map[string]any{"summary": strings.Repeat("x", maxSummaryLen+1)})
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("overlong summary = %d, want 400: %s", rec.Code, rec.Body.String())
	}
	if got, _ := summaryOf(t, trip.ID.String()); got != nil {
		t.Fatalf("stored summary = %v after a rejected patch", got)
	}
}

// A co-planner edits the trip's content, and its description is content. The
// owner's row scope is satisfied by the OWNER's id off the authorized row, so
// this is the same path the title takes.
func TestPatchTripDescriptionByEditorAndViewer(t *testing.T) {
	requireDB(t)
	resetDB(t)
	owner, ownerToken := createTestUser(t, "descowner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	id := trip.ID.String()

	_, editorToken := createTestUser(t, "desceditor@example.com")
	if rec := joinShare(t, editorToken, createShare(t, ownerToken, id, "editor")); rec.Code >= 300 {
		t.Fatalf("editor join = %d: %s", rec.Code, rec.Body.String())
	}

	rec := doJSON(t, "PATCH", "/api/v1/trips/"+id, editorToken,
		map[string]any{"summary": "Co-planned: ten days in Sicily."})
	if rec.Code != http.StatusOK {
		t.Fatalf("editor patch = %d: %s", rec.Code, rec.Body.String())
	}
	if got, _ := summaryOf(t, id); got == nil || *got != "Co-planned: ten days in Sicily." {
		t.Fatalf("editor's description not stored: %v", got)
	}

	_, strangerToken := createTestUser(t, "descstranger@example.com")
	rec = doJSON(t, "PATCH", "/api/v1/trips/"+id, strangerToken,
		map[string]any{"summary": "Not mine to write."})
	if rec.Code != http.StatusNotFound {
		t.Fatalf("stranger patch = %d, want 404: %s", rec.Code, rec.Body.String())
	}
	if got, _ := summaryOf(t, id); got == nil || *got != "Co-planned: ten days in Sicily." {
		t.Fatalf("a stranger changed the description: %v", got)
	}
}

// Every save INSERTs a new row, so without the carry-forward a version save that
// supplies no summary silently dropped the description — a trip losing its
// overview with no UPDATE statement existing anywhere.
func TestPersistTripCarriesTheDescriptionAcrossVersions(t *testing.T) {
	requireDB(t)
	resetDB(t)
	user, token := createTestUser(t, "descversion@example.com")
	ctx := context.Background()

	first, _, err := persistTrip(ctx, user.ID, "chat-desc-versions",
		"Sicily Loop", "Ten days circling Sicily.", "2026-09-12", "2026-09-22", "", tripEndpoints{},
		[]map[string]any{{"name": "Teatro Massimo", "city": "Palermo"}})
	if err != nil {
		t.Fatalf("persistTrip v1: %v", err)
	}
	// The traveler rewrites it, so the carry-forward has to preserve the AUTHOR
	// too — laundering it back to 'agent' would unprotect their words.
	if rec := doJSON(t, "PATCH", "/api/v1/trips/"+first, token,
		map[string]any{"summary": "Our 10th anniversary in Sicily."}); rec.Code != http.StatusOK {
		t.Fatalf("patch summary = %d: %s", rec.Code, rec.Body.String())
	}

	second, newLineage, err := persistTrip(ctx, user.ID, "chat-desc-versions",
		"Sicily Loop", "", "2026-09-12", "2026-09-22", "", tripEndpoints{},
		[]map[string]any{{"name": "Teatro Massimo", "city": "Palermo"}})
	if err != nil {
		t.Fatalf("persistTrip v2: %v", err)
	}
	if newLineage {
		t.Fatal("second save reported a new lineage")
	}
	got, source := summaryOf(t, second)
	if got == nil || *got != "Our 10th anniversary in Sicily." {
		t.Fatalf("new version's summary = %v, want the previous version's carried forward", got)
	}
	if source == nil || *source != summarySourceTraveler {
		t.Fatalf("new version's summary_source = %v, want %q carried with the prose", source, summarySourceTraveler)
	}

	// A version save that DOES supply prose still replaces it — the carry-forward
	// is a fallback, not an override.
	third, _, err := persistTrip(ctx, user.ID, "chat-desc-versions",
		"Sicily Loop", "Now with Catania.", "2026-09-12", "2026-09-22", "", tripEndpoints{},
		[]map[string]any{{"name": "Teatro Massimo", "city": "Palermo"}})
	if err != nil {
		t.Fatalf("persistTrip v3: %v", err)
	}
	if got, source := summaryOf(t, third); got == nil || *got != "Now with Catania." ||
		source == nil || *source != summarySourceAgent {
		t.Fatalf("v3 summary/source = %v/%v, want the supplied prose stamped agent", got, source)
	}
}

// A co-planner's trip cards showed no blurb where the owner's did: the row
// carried the description and the shared-with-me query never selected it.
func TestSharedWithMeCarriesTheDescription(t *testing.T) {
	requireDB(t)
	resetDB(t)
	owner, ownerToken := createTestUser(t, "descshareowner@example.com")
	trip := createTestTrip(t, owner.ID, 0)
	if rec := doJSON(t, "PATCH", "/api/v1/trips/"+trip.ID.String(), ownerToken,
		map[string]any{"summary": "Ten days circling Sicily."}); rec.Code != http.StatusOK {
		t.Fatalf("patch summary = %d: %s", rec.Code, rec.Body.String())
	}
	_, editorToken := createTestUser(t, "descshareeditor@example.com")
	if rec := joinShare(t, editorToken, createShare(t, ownerToken, trip.ID.String(), "editor")); rec.Code >= 300 {
		t.Fatalf("editor join = %d: %s", rec.Code, rec.Body.String())
	}

	rec := doJSON(t, "GET", "/api/v1/trips/shared-with-me", editorToken, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("shared-with-me = %d: %s", rec.Code, rec.Body.String())
	}
	rows := decodeList(t, rec)
	if len(rows) != 1 {
		t.Fatalf("shared rows = %d, want 1", len(rows))
	}
	if got, _ := rows[0]["summary"].(string); got != "Ten days circling Sicily." {
		t.Fatalf("shared row summary = %q, want the trip's description", got)
	}
}

// The parity contract for the extraction: the chat tool and the page's PATCH
// call ONE implementation, so the same input has to leave two trips in the same
// state — prose, author and all. Two paths that can disagree about what a
// description means is what applyTripSummary exists to prevent.
func TestPageAndChatWriteTheSameDescription(t *testing.T) {
	requireDB(t)
	resetDB(t)
	user, token := createTestUser(t, "paritydesc@example.com")

	viaChat := createTestTrip(t, user.ID, 0)
	viaPage := createTestTrip(t, user.ID, 0)

	s, _ := testPlanSession(true, user.ID)
	s.boundTripID = &viaChat.ID
	if msg, isErr := runSetTripDescriptionTool(s, descriptionInput(
		"Ten days circling Sicily.", summaryReasonAsked)); isErr {
		t.Fatalf("set_trip_description errored: %s", msg)
	}
	if rec := doJSON(t, "PATCH", "/api/v1/trips/"+viaPage.ID.String(), token,
		map[string]any{"summary": "Ten days circling Sicily."}); rec.Code != http.StatusOK {
		t.Fatalf("patch = %d: %s", rec.Code, rec.Body.String())
	}

	chatText, chatSource := summaryOf(t, viaChat.ID.String())
	pageText, pageSource := summaryOf(t, viaPage.ID.String())
	if strPtrVal(chatText) != strPtrVal(pageText) {
		t.Fatalf("stored prose diverges: chat %v vs page %v", chatText, pageText)
	}
	// The sources differ BY DESIGN and that is the one asymmetry: whose words
	// they are is exactly what the two surfaces disagree about.
	if strPtrVal(chatSource) != summarySourceAgent || strPtrVal(pageSource) != summarySourceTraveler {
		t.Fatalf("sources = chat %v / page %v, want agent / traveler", chatSource, pageSource)
	}

	// Both surfaces must also agree on clearing, which is the write COALESCE
	// could not do.
	if rec := doJSON(t, "PATCH", "/api/v1/trips/"+viaPage.ID.String(), token,
		map[string]any{"summary": ""}); rec.Code != http.StatusOK {
		t.Fatalf("clear = %d: %s", rec.Code, rec.Body.String())
	}
	if msg, isErr := runSetTripDescriptionTool(s, descriptionInput("", summaryReasonAsked)); isErr {
		t.Fatalf("chat clear errored: %s", msg)
	}
	chatText, _ = summaryOf(t, viaChat.ID.String())
	pageText, _ = summaryOf(t, viaPage.ID.String())
	if chatText != nil || pageText != nil {
		t.Fatalf("clearing diverges: chat %v vs page %v", chatText, pageText)
	}
}

// The tool's shape must stay reachable through the registry — a tool nothing
// dispatches is a tool that doesn't exist.
func TestSetTripDescriptionIsDispatchable(t *testing.T) {
	tool, ok := planToolByName["set_trip_description"]
	if !ok || tool.run == nil {
		t.Fatal("set_trip_description is not dispatchable through the registry")
	}
	if tool.enabled == nil || tool.enabled(&planSession{}) {
		t.Fatal("set_trip_description must be authed-gated: the anonymous tools array has to stay byte-identical")
	}
	if !tool.enabled(&planSession{authed: true, uid: uuid.New()}) {
		t.Fatal("set_trip_description must be offered to authed sessions")
	}
}
