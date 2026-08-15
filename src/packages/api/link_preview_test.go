package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
)

// link_preview_test.go — the guard on the one place this API fetches a URL the
// user chose. Every case here asserts the same two things: nothing internal is
// ever reached, and a refusal is a well-formed answer rather than an error.

func TestAddrAllowedRefusesInternalAddresses(t *testing.T) {
	blocked := []string{
		"127.0.0.1",        // loopback
		"::1",              // loopback v6
		"10.0.0.1",         // RFC1918
		"172.16.5.4",       // RFC1918
		"192.168.1.1",      // RFC1918
		"169.254.169.254",  // cloud metadata — the one everybody tests
		"fd00:ec2::254",    // cloud metadata v6
		"fd00::1",          // IPv6 unique-local
		"fe80::1",          // IPv6 link-local
		"100.64.0.1",       // CGNAT
		"0.0.0.0",          // unspecified
		"224.0.0.1",        // multicast
		"192.0.2.5",        // TEST-NET-1
		"198.51.100.5",     // TEST-NET-2
		"203.0.113.5",      // TEST-NET-3
		"198.18.0.5",       // benchmarking
		"::ffff:127.0.0.1", // v4-mapped loopback — must not slip past as "v6"
		"::ffff:10.0.0.1",  // v4-mapped RFC1918
	}
	for _, s := range blocked {
		addr, err := netip.ParseAddr(s)
		if err != nil {
			t.Fatalf("bad fixture %q: %v", s, err)
		}
		if addrAllowed(addr) {
			t.Errorf("addrAllowed(%s) = true, want false — this is reachable from the droplet", s)
		}
	}
	for _, s := range []string{"1.1.1.1", "93.184.216.34", "2606:2800:220:1::"} {
		addr, _ := netip.ParseAddr(s)
		if !addrAllowed(addr) {
			t.Errorf("addrAllowed(%s) = false, want true — ordinary public address", s)
		}
	}
}

func TestCheckPreviewURLRefusesBadShapes(t *testing.T) {
	cases := []struct {
		url    string
		reason string
	}{
		{"file:///etc/passwd", reasonUnsupportedScheme},
		{"gopher://example.com/", reasonUnsupportedScheme},
		{"ftp://example.com/x", reasonUnsupportedScheme},
		{"http://user:pw@example.com/", reasonBlockedHost},
		{"http://example.com:22/", reasonUnsupportedPort},
		{"http://example.com:6379/", reasonUnsupportedPort},
		{"http://example.com:8080/", reasonUnsupportedPort},
	}
	for _, c := range cases {
		got := fetchLinkPreview(context.Background(), c.url)
		if got.OK {
			t.Errorf("%s: ok = true, want a refusal", c.url)
			continue
		}
		if got.Reason == nil || *got.Reason != c.reason {
			t.Errorf("%s: reason = %v, want %s", c.url, got.Reason, c.reason)
		}
	}
}

// A blocked address must be refused at DIAL time, so a hostname that resolves
// to loopback cannot get through.
func TestFetchRefusesLoopbackTarget(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Error("the preview fetcher reached a loopback server — the dial guard did not fire")
		w.Write([]byte("<html><head><meta property=\"og:title\" content=\"leaked\"></head></html>"))
	}))
	defer srv.Close()

	got := fetchLinkPreview(context.Background(), srv.URL)
	if got.OK {
		t.Fatalf("ok = true for a loopback URL: %+v", got)
	}
	// The port httptest picks is arbitrary, so either guard may fire first —
	// both are correct refusals.
	if got.Reason == nil || (*got.Reason != reasonBlockedHost && *got.Reason != reasonUnsupportedPort) {
		t.Fatalf("reason = %v, want blocked_host or unsupported_port", got.Reason)
	}
}

func TestParseHeadMetaReadsOpenGraph(t *testing.T) {
	doc := `<html><head>
		<title>Fallback &amp; Co</title>
		<meta property="og:title" content="Loft near Old Town">
		<meta property='og:image' content='https://img.example/1.jpg'>
		<meta name="og:price:amount" content="118.50">
		<meta name="og:price:currency" content="eur">
		<meta property="og:title" content="A duplicate that must lose">
		</head><body><meta property="og:title" content="body tag ignored"></body></html>`
	meta := parseHeadMeta(doc)
	if meta["og:title"] != "Loft near Old Town" {
		t.Fatalf("og:title = %q (first occurrence must win)", meta["og:title"])
	}
	if meta["og:image"] != "https://img.example/1.jpg" {
		t.Fatalf("single-quoted attr not parsed: %q", meta["og:image"])
	}
	if meta["title"] != "Fallback & Co" {
		t.Fatalf("entities must be decoded: %q", meta["title"])
	}
}

func TestPreviewFromBodyParsesOpenGraph(t *testing.T) {
	got := previewFromBody(LinkPreview{URL: "https://airbnb.com/rooms/1"}, `<html><head>
		<meta property="og:title" content="Riverside studio">
		<meta property="og:image" content="https://img.example/2.jpg">
		<meta property="og:price:amount" content="96">
		<meta property="og:price:currency" content="usd">
	</head></html>`)
	if !got.OK {
		t.Fatalf("ok = false: %+v", got)
	}
	if got.Title == nil || *got.Title != "Riverside studio" {
		t.Fatalf("title = %v", got.Title)
	}
	if got.Price == nil || *got.Price != 96 || got.Currency == nil || *got.Currency != "USD" {
		t.Fatalf("price/currency = %v %v (currency must be normalized)", got.Price, got.Currency)
	}
}

// Half a price is worth less than none: it cannot be summed, and this app has
// no FX to guess with.
func TestPreviewFromBodyDropsPriceWithoutCurrency(t *testing.T) {
	got := previewFromBody(LinkPreview{}, `<html><head><meta property="og:title" content="X">
		 <meta property="og:price:amount" content="120"></head></html>`)
	if !got.OK {
		t.Fatalf("ok = false: %+v", got)
	}
	if got.Price != nil || got.Currency != nil {
		t.Fatalf("price survived without a currency: %v %v", got.Price, got.Currency)
	}
	// ...and an unusable currency code is dropped too, not truncated into one.
	got = previewFromBody(LinkPreview{}, `<html><head><meta property="og:title" content="X">
		 <meta property="og:price:amount" content="120">
		 <meta property="og:price:currency" content="dollars"></head></html>`)
	if got.Price != nil {
		t.Fatalf("price survived a bogus currency code: %v", got.Currency)
	}
}

func TestPreviewFromBodyReportsNoMetadata(t *testing.T) {
	got := previewFromBody(LinkPreview{}, `<html><head></head><body>hi</body></html>`)
	if got.OK || got.Reason == nil || *got.Reason != reasonNoMetadata {
		t.Fatalf("reason = %v, want no_metadata", got.Reason)
	}
}

// Only the <head> is scanned, so a page that repeats OG tags in its body (or an
// injected one) cannot override the real answer.
func TestPreviewFromBodyIgnoresBodyTags(t *testing.T) {
	got := previewFromBody(LinkPreview{}, `<html><head>
		<meta property="og:title" content="Real title"></head>
		<body><meta property="og:title" content="Injected"></body></html>`)
	if got.Title == nil || *got.Title != "Real title" {
		t.Fatalf("title = %v", got.Title)
	}
}

func TestLinkProviderForHost(t *testing.T) {
	cases := map[string]string{
		"www.airbnb.com":      "airbnb",
		"www.airbnb.co.uk":    "airbnb",
		"www.booking.com":     "booking",
		"www.kayak.com":       "kayak",
		"www.ferryhopper.com": "ferry",
		"example.com":         "", // unknown hosts get no invented slug
	}
	for host, want := range cases {
		if got := linkProviderForHost(host); got != want {
			t.Errorf("linkProviderForHost(%s) = %q, want %q", host, got, want)
		}
	}
}

// A refused fetch still brands the card: provider comes from the host, so a
// blocked Airbnb link is still recognizably an Airbnb.
func TestRefusedFetchStillCarriesProvider(t *testing.T) {
	got := fetchLinkPreview(context.Background(), "http://www.airbnb.com:22/rooms/1")
	if got.OK {
		t.Fatalf("ok = true for a blocked port")
	}
	if got.Provider == nil || *got.Provider != "airbnb" {
		t.Fatalf("provider = %v, want airbnb even on a refusal", got.Provider)
	}
}
