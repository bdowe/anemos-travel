package main

import (
	"html/template"
	"net/http"
	"strings"

	"travel-route-planner/store"
)

// Link previews for shared trips. Crawlers (Slack/iMessage/WhatsApp/Twitter…)
// don't execute JS, so the SPA share page renders blank for them. The
// deployment nginx UA-sniffs known bots on /app/share/* and rewrites here;
// humans keep the clean app URL and never touch this page (the meta-refresh
// below is only a fallback for bot-like browsers).

// sharePreviewTmpl uses html/template — all fields are auto-escaped; never
// build this page with fmt.Sprintf.
var sharePreviewTmpl = template.Must(template.New("share-preview").Parse(`<!DOCTYPE html>
<html lang="{{.Lang}}">
<head>
  <meta charset="utf-8">
  <title>{{.Title}} — Anemos</title>
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="Anemos">
  <meta property="og:title" content="{{.Title}}">
  <meta property="og:description" content="{{.Description}}">
  <meta property="og:url" content="{{.URL}}">
  <meta property="og:image" content="{{.Image}}">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="{{.Title}}">
  <meta name="twitter:description" content="{{.Description}}">
  <meta http-equiv="refresh" content="0;url={{.URL}}">
</head>
<body>
  <p><a href="{{.URL}}">{{.Title}}</a> — {{.Description}}</p>
</body>
</html>`))

type sharePreviewData struct {
	Lang        string
	Title       string
	Description string
	URL         string
	Image       string
}

// previewBaseURL reconstructs the public origin from the proxy headers the
// nginx gateway already sets; falls back to the request host.
func previewBaseURL(r *http.Request) string {
	scheme := r.Header.Get("X-Forwarded-Proto")
	if scheme == "" {
		scheme = "http"
	}
	return scheme + "://" + r.Host
}

// truncatePreview keeps OG text within preview-card limits at a rune
// boundary.
func truncatePreview(s string, max int) string {
	runes := []rune(strings.TrimSpace(s))
	if len(runes) <= max {
		return string(runes)
	}
	return strings.TrimSpace(string(runes[:max-1])) + "…"
}

// sharePreviewHandler is GET /api/v1/share-preview/{token}: a minimal HTML
// page with OG tags for link-preview crawlers. Same data path and 404
// posture as sharedTripHandler; no new queries.
func sharePreviewHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	// Crawlers rarely send a useful Accept-Language, but localeMiddleware also
	// honors the ?lang= a localized share link carries.
	locale := requestLocale(r.Context())
	if dbPool == nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		w.Write([]byte("<html lang=\"" + locale + "\"><body><h2>" +
			template.HTMLEscapeString(tr(locale, "share.temporarilyUnavailable")) + "</h2></body></html>"))
		return
	}
	share, trip, ok := resolveShare(r)
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		w.Write([]byte("<html lang=\"" + locale + "\"><body><h2>" +
			template.HTMLEscapeString(tr(locale, "share.unavailableTitle")) + "</h2><p>" +
			template.HTMLEscapeString(tr(locale, "share.unavailableBody")) + "</p></body></html>"))
		return
	}

	ownerName := tr(locale, "share.aTraveler")
	if owner, err := store.New(dbPool).GetUserByID(r.Context(), share.OwnerID); err == nil &&
		owner.DisplayName != nil && *owner.DisplayName != "" {
		ownerName = *owner.DisplayName
	}

	var descParts []string
	if trip.StartDate.Valid && trip.EndDate.Valid {
		descParts = append(descParts,
			localizedDate(locale, trip.StartDate.Time, dateStyleMonthDay)+" – "+
				tr(locale, "share.dateWithYear",
					localizedDate(locale, trip.EndDate.Time, dateStyleMonthDay), trip.EndDate.Time.Year()))
	}
	descParts = append(descParts, tr(locale, "share.plannedBy", ownerName))
	if trip.Summary != nil {
		if first := strings.TrimSpace(strings.SplitN(*trip.Summary, "\n", 2)[0]); first != "" {
			descParts = append(descParts, first)
		}
	}

	base := previewBaseURL(r)
	data := sharePreviewData{
		Lang:        locale,
		Title:       truncatePreview(trip.Title, 70),
		Description: truncatePreview(strings.Join(descParts, " · "), 200),
		URL:         base + "/app/share/" + share.Token,
		Image:       base + "/app/og-card.png",
	}
	if err := sharePreviewTmpl.Execute(w, data); err != nil {
		// Headers already sent; nothing sensible left to do.
		return
	}
}
