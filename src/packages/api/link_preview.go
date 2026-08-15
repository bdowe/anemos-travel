package main

import (
	"context"
	"fmt"
	"html"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// link_preview.go — reads the OpenGraph tags off a pasted booking link so the
// save-an-option sheet can prefill a title, image and price
// (specs/booking-shortlist).
//
// This is the first place in the codebase that fetches a URL the USER chose,
// which makes it an SSRF surface: without a guard it is an open proxy into the
// droplet's own network and a scanner for anything listening on localhost or
// the cloud metadata endpoint. Everything below exists for that.
//
// It is also expected to FAIL often and that is fine: Airbnb in particular
// blocks datacenter egress hard. The contract is that a failure returns a
// well-formed "no" with a reason, never an error the sheet has to handle — the
// traveler just types the title themselves.

type LinkPreview struct {
	OK          bool     `json:"ok"`
	URL         string   `json:"url"`
	Title       *string  `json:"title,omitempty"`
	Description *string  `json:"description,omitempty"`
	ImageURL    *string  `json:"image_url,omitempty"`
	SiteName    *string  `json:"site_name,omitempty"`
	Provider    *string  `json:"provider,omitempty"`
	Price       *float64 `json:"price,omitempty"`
	Currency    *string  `json:"currency,omitempty"`
	// Reason names WHY a lookup came back empty. Closed vocabulary; it is the
	// explicit silencing that keeps `ok:false` from being a swallowed error.
	Reason *string `json:"reason,omitempty"`
}

const (
	linkPreviewTimeout   = 5 * time.Second
	linkPreviewMaxBytes  = 512 << 10 // enough for any <head>; caps a hostile body
	linkPreviewMaxRedirs = 3
	linkPreviewUA        = "AnemosBot/1.0 (+https://anemos.travel; link preview)"
)

// Failure reasons. Every early return names one.
const (
	reasonUnsupportedScheme = "unsupported_scheme"
	reasonUnsupportedPort   = "unsupported_port"
	reasonBlockedHost       = "blocked_host"
	reasonTimeout           = "timeout"
	reasonTooLarge          = "too_large"
	reasonNotHTML           = "not_html"
	reasonUpstreamError     = "upstream_error"
	reasonNoMetadata        = "no_metadata"
)

// blockedPrefixes are the ranges a preview fetch must never reach, on top of
// the flags netip exposes directly (loopback, private, link-local, multicast,
// unspecified). Named individually so each is greppable and self-documenting.
var blockedPrefixes = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),       // "this network"
	netip.MustParsePrefix("100.64.0.0/10"),   // CGNAT — a carrier's private space
	netip.MustParsePrefix("192.0.0.0/24"),    // IETF protocol assignments
	netip.MustParsePrefix("192.0.2.0/24"),    // TEST-NET-1
	netip.MustParsePrefix("198.18.0.0/15"),   // benchmarking
	netip.MustParsePrefix("198.51.100.0/24"), // TEST-NET-2
	netip.MustParsePrefix("203.0.113.0/24"),  // TEST-NET-3
	netip.MustParsePrefix("fc00::/7"),        // IPv6 unique-local
	netip.MustParsePrefix("fe80::/10"),       // IPv6 link-local
}

// The cloud metadata services. Both already fall inside link-local, but a
// reviewer looking for "is 169.254.169.254 handled" should find it by name.
var metadataAddrs = []netip.Addr{
	netip.MustParseAddr("169.254.169.254"),
	netip.MustParseAddr("fd00:ec2::254"),
}

// addrAllowed decides whether a resolved address may be dialed.
func addrAllowed(addr netip.Addr) bool {
	if addr.Is4In6() {
		addr = addr.Unmap()
	}
	if !addr.IsValid() || addr.IsLoopback() || addr.IsPrivate() ||
		addr.IsUnspecified() || addr.IsMulticast() ||
		addr.IsLinkLocalUnicast() || addr.IsLinkLocalMulticast() ||
		addr.IsInterfaceLocalMulticast() {
		return false
	}
	for _, a := range metadataAddrs {
		if addr == a {
			return false
		}
	}
	for _, p := range blockedPrefixes {
		if p.Contains(addr) {
			return false
		}
	}
	return true
}

// errBlockedHost is returned from the dialer's Control hook.
var errBlockedHost = fmt.Errorf("blocked host")

// linkPreviewClient is a PRIVATE client, deliberately not on sharedTransport:
// the whole point is a dialer that refuses internal addresses, and putting that
// on the process-wide transport would change every other upstream's behaviour.
// (http_client.go's own comment sanctions per-site clients for exactly this.)
//
// The guard lives in Control rather than in a hostname check because Control
// runs AFTER DNS resolution, on the address actually being connected to, for
// every connection including each redirect hop. A pre-flight lookup can be
// beaten by a name that resolves to a public address once and to 127.0.0.1 the
// second time (DNS rebinding); Control cannot.
var linkPreviewClient = &http.Client{
	Timeout: linkPreviewTimeout,
	Transport: &http.Transport{
		DialContext: (&net.Dialer{
			Timeout:   linkPreviewTimeout,
			KeepAlive: 30 * time.Second,
			Control: func(network, address string, _ syscall.RawConn) error {
				host, _, err := net.SplitHostPort(address)
				if err != nil {
					return errBlockedHost
				}
				addr, err := netip.ParseAddr(host)
				if err != nil || !addrAllowed(addr) {
					return errBlockedHost
				}
				return nil
			},
		}).DialContext,
		MaxIdleConns:        8,
		IdleConnTimeout:     30 * time.Second,
		TLSHandshakeTimeout: linkPreviewTimeout,
	},
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= linkPreviewMaxRedirs {
			return fmt.Errorf("too many redirects")
		}
		// Re-run the shape check per hop; the dialer re-runs the address check
		// on its own.
		if err := checkPreviewURL(req.URL); err != "" {
			return fmt.Errorf("blocked redirect: %s", err)
		}
		return nil
	},
}

// checkPreviewURL returns a failure reason, or "" when the URL's SHAPE is
// acceptable. Address-level checks happen at dial time.
func checkPreviewURL(u *url.URL) string {
	if u.Scheme != "http" && u.Scheme != "https" {
		return reasonUnsupportedScheme
	}
	if u.Host == "" {
		return reasonBlockedHost
	}
	// Credentials in a URL are both a leak (they would ride into our logs) and
	// an auth-bypass trick against internal services.
	if u.User != nil {
		return reasonBlockedHost
	}
	// An OG scraper has no business on any port but the web ones; refusing the
	// rest kills most internal-service probing before DNS is even consulted.
	switch u.Port() {
	case "", "80", "443":
	default:
		return reasonUnsupportedPort
	}
	return ""
}

// fetchLinkPreview is the whole lookup. It never returns an error: a failure is
// a LinkPreview with OK false and a reason, because that is what the caller can
// actually do something with.
func fetchLinkPreview(ctx context.Context, raw string) LinkPreview {
	out := LinkPreview{URL: raw}
	fail := func(reason string) LinkPreview {
		out.OK = false
		out.Reason = &reason
		return out
	}

	if len(raw) > maxURLLen {
		return fail(reasonUnsupportedScheme)
	}
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return fail(reasonUnsupportedScheme)
	}
	// Derived from the host alone and set BEFORE any refusal, so it survives a
	// failed fetch — a blocked Airbnb link still brands its card correctly, and
	// Airbnb is the link most likely to be blocked.
	if p := linkProviderForHost(u.Hostname()); p != "" {
		out.Provider = &p
	}
	if reason := checkPreviewURL(u); reason != "" {
		return fail(reason)
	}

	ctx, cancel := context.WithTimeout(ctx, linkPreviewTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return fail(reasonUpstreamError)
	}
	req.Header.Set("User-Agent", linkPreviewUA)
	req.Header.Set("Accept", "text/html,application/xhtml+xml")
	req.Header.Set("Accept-Language", "en")

	resp, err := linkPreviewClient.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return fail(reasonTimeout)
		}
		if strings.Contains(err.Error(), errBlockedHost.Error()) ||
			strings.Contains(err.Error(), "blocked redirect") {
			return fail(reasonBlockedHost)
		}
		return fail(reasonUpstreamError)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fail(reasonUpstreamError)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "" &&
		!strings.Contains(ct, "text/html") && !strings.Contains(ct, "application/xhtml") {
		return fail(reasonNotHTML)
	}
	if resp.ContentLength > linkPreviewMaxBytes {
		return fail(reasonTooLarge)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, linkPreviewMaxBytes))
	if err != nil {
		if ctx.Err() != nil {
			return fail(reasonTimeout)
		}
		return fail(reasonUpstreamError)
	}

	return previewFromBody(out, string(body))
}

// previewFromBody turns a fetched document into the answer. Split out from the
// network path so the parsing rules — which tags win, what makes a price usable
// — are testable without a socket.
func previewFromBody(out LinkPreview, body string) LinkPreview {
	meta := parseHeadMeta(body)
	out.Title = firstMetaValue(meta, "og:title", "twitter:title", "title")
	out.Description = firstMetaValue(meta, "og:description", "twitter:description", "description")
	out.ImageURL = firstMetaValue(meta, "og:image", "og:image:secure_url", "twitter:image")
	out.SiteName = firstMetaValue(meta, "og:site_name", "application-name")

	// Price only when BOTH halves are present and the currency is a real code.
	// A bare number would be unsummable at the other end (no FX anywhere in
	// this app), so half a price is worth less than none.
	amountStr := firstMetaValue(meta, "og:price:amount", "product:price:amount")
	currency := firstMetaValue(meta, "og:price:currency", "product:price:currency")
	if amountStr != nil && currency != nil {
		if amount, err := strconv.ParseFloat(strings.TrimSpace(*amountStr), 64); err == nil && amount >= 0 {
			c := strings.ToUpper(strings.TrimSpace(*currency))
			if len(c) == 3 {
				out.Price = &amount
				out.Currency = &c
			}
		}
	}

	if out.Title == nil && out.ImageURL == nil && out.Price == nil {
		reason := reasonNoMetadata
		out.OK, out.Reason = false, &reason
		return out
	}
	out.OK = true
	return out
}

// linkProviderForHost maps a host to the provider vocabulary the client already
// brands booking rows with (booking_todo_card.dart's _providerBrand). An
// unknown host gets no provider rather than an invented slug.
func linkProviderForHost(host string) string {
	h := strings.ToLower(host)
	switch {
	case strings.Contains(h, "airbnb."):
		return "airbnb"
	case strings.Contains(h, "booking.com"):
		return "booking"
	case strings.Contains(h, "kayak."):
		return "kayak"
	case strings.Contains(h, "google.") && strings.Contains(h, "flights"):
		return "google_flights"
	case strings.Contains(h, "rome2rio."):
		return "rome2rio"
	case strings.Contains(h, "ferryhopper."):
		return "ferry"
	case strings.Contains(h, "vrbo.") || strings.Contains(h, "expedia."):
		return "expedia"
	case strings.Contains(h, "hotels.com"):
		return "hotels"
	}
	return ""
}

// --- minimal <meta> scanning -------------------------------------------------
//
// Hand-rolled rather than pulling in golang.org/x/net/html: go.mod has no
// direct dependency on it today, and six tag lookups do not justify one (same
// dependency-free reasoning as cache.go). Everything below is table-testable.

var (
	headEndRe  = regexp.MustCompile(`(?is)</head\s*>`)
	metaTagRe  = regexp.MustCompile(`(?is)<meta\s+[^>]*>`)
	attrRe     = regexp.MustCompile(`(?is)(property|name|content)\s*=\s*("([^"]*)"|'([^']*)'|([^\s"'>]+))`)
	titleTagRe = regexp.MustCompile(`(?is)<title[^>]*>(.*?)</title>`)
)

// parseHeadMeta collects the <head>'s meta property/name -> content pairs, plus
// a synthetic "title" key from <title>. First occurrence of a key wins, which
// matches how browsers treat duplicated OG tags.
func parseHeadMeta(doc string) map[string]string {
	head := doc
	if loc := headEndRe.FindStringIndex(doc); loc != nil {
		head = doc[:loc[0]]
	}
	out := map[string]string{}
	for _, tag := range metaTagRe.FindAllString(head, -1) {
		var key, content string
		var haveContent bool
		for _, m := range attrRe.FindAllStringSubmatch(tag, -1) {
			val := m[3] + m[4] + m[5] // exactly one of the three alternatives matched
			switch strings.ToLower(m[1]) {
			case "property", "name":
				if key == "" {
					key = strings.ToLower(strings.TrimSpace(val))
				}
			case "content":
				content, haveContent = val, true
			}
		}
		if key == "" || !haveContent {
			continue
		}
		if _, seen := out[key]; !seen {
			out[key] = html.UnescapeString(strings.TrimSpace(content))
		}
	}
	if m := titleTagRe.FindStringSubmatch(head); m != nil {
		if _, seen := out["title"]; !seen {
			out["title"] = html.UnescapeString(strings.TrimSpace(m[1]))
		}
	}
	return out
}

// firstMetaValue returns the first non-empty value among keys, or nil.
func firstMetaValue(meta map[string]string, keys ...string) *string {
	for _, k := range keys {
		if v, ok := meta[k]; ok && strings.TrimSpace(v) != "" {
			s := strings.TrimSpace(v)
			return &s
		}
	}
	return nil
}
