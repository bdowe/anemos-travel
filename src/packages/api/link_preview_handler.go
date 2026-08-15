package main

import (
	"net/http"
	"strings"
)

// linkPreviewHandler reads the OpenGraph tags off a pasted booking link so the
// save-an-option sheet can prefill itself (specs/booking-shortlist).
//
// AUTH IS REQUIRED, unlike /places/photo's anonymous 302 proxy: that one is
// safe unauthenticated only because knownPhotoRefs limits it to refs this
// process handed out. There is no equivalent gate on an arbitrary URL, so
// without auth this would be an open fetch proxy and an internal port scanner.
//
// It answers 200 with {"ok":false,"reason":...} for every lookup failure. A
// blocked, slow or bot-walled site is the EXPECTED case (Airbnb refuses
// datacenter egress), not an error the sheet should have to handle — the
// traveler just types the title in. Only a missing url param, which is a
// programmer error the client cannot produce, is a 400.
func linkPreviewHandler(w http.ResponseWriter, r *http.Request) {
	raw := strings.TrimSpace(r.URL.Query().Get("url"))
	if raw == "" {
		writeJSONError(w, http.StatusBadRequest, "url is required")
		return
	}
	writeJSON(w, http.StatusOK, fetchLinkPreview(r.Context(), raw))
}
