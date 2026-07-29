package main

// places_photo_handler.go — GET /api/v1/places/photo, the redirect proxy that
// lets the chat's photo cards load Google Place photos without the API key
// ever reaching a client. The flow: validate ref → known-ref gate (only refs
// this process handed out are servable; unknown → 404 with zero Google spend)
// → resolve the Place Photo API's 302 → redirect the client to the
// googleusercontent URL. Image bytes never transit this server, and every
// Google call is billed, so the gate + caches in places_service.go are the
// cost controls.

import (
	"errors"
	"net/http"
)

// photoWidths is the allowlist for the w param. A fixed menu keeps the
// ref|width URL cache (and Google billing) at three variants per photo max.
var photoWidths = [...]int{200, 400, 800}

// clampPhotoWidth parses w and snaps it to the allowlist: the smallest
// allowed value that covers the request, 800 for anything larger, 400 when
// missing or garbage.
func clampPhotoWidth(raw string) int {
	if raw == "" {
		return 400
	}
	n := 0
	for _, r := range raw {
		if r < '0' || r > '9' {
			return 400
		}
		n = n*10 + int(r-'0')
		if n > 10000 {
			break
		}
	}
	if n == 0 {
		return 400
	}
	for _, w := range photoWidths {
		if n <= w {
			return w
		}
	}
	return photoWidths[len(photoWidths)-1]
}

// placesPhotoHandler answers GET /api/v1/places/photo?ref=<photo_reference>&w=<width>
// with a 302 to the actual image. Unauthenticated (the chat works anonymously)
// and DB-free (degraded mode unaffected).
func placesPhotoHandler(w http.ResponseWriter, r *http.Request) {
	ref := r.URL.Query().Get("ref")
	if ref == "" || len(ref) > 1024 {
		http.Error(w, "Missing or invalid 'ref'", http.StatusBadRequest)
		return
	}
	width := clampPhotoWidth(r.URL.Query().Get("w"))

	if !placesService.photoRefAllowed(ref) {
		http.Error(w, "Photo not found", http.StatusNotFound)
		return
	}

	imgURL, err := placesService.ResolvePhotoURL(r.Context(), ref, width)
	if err != nil {
		if errors.Is(err, errPhotoNotFound) {
			// Invalid/expired ref upstream: to the client this is just "no
			// image", same as an unknown ref — the card falls back to its icon.
			http.Error(w, "Photo not found", http.StatusNotFound)
			return
		}
		// Detail goes to the server log only: provider/internal error strings
		// must never reach an unauthenticated caller.
		ctxLog(r.Context()).Error("place photo resolve failed", "error", err)
		http.Error(w, "Failed to load photo", http.StatusBadGateway)
		return
	}

	// 6h browser cache — below the 12h server-side URL cache and the 24h
	// known-ref gate, so a revalidation almost always finds both still warm.
	w.Header().Set("Cache-Control", "public, max-age=21600")
	http.Redirect(w, r, imgURL, http.StatusFound)
}
