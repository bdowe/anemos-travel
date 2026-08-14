package main

import (
	"net/http"
	"net/url"
	"strings"
)

// Does the address we send mail FROM belong to the site we are? A cheap,
// static, network-free sanity check on two env vars — and the one that would
// have caught a two-week outage.
//
// Prod ran with SMTP_FROM=alerts@goldentempo.co while the site served
// goldentempotravel.com. That domain had been removed from the mail provider
// months earlier, so every verification and password-reset send was rejected.
// Nothing noticed: emailService.Configured() reports whether SMTP_FROM is
// SET, never whether it can send, so the API wasn't degraded; the send errors
// are log.Printf, which never reach Sentry; and at this traffic level nobody
// hit a reset. It was introduced by a server rebuild that recreated .env from
// a dev copy, silently reverting a fix — exactly the kind of drift a
// deployment check exists to catch.
//
// What this DOESN'T catch, deliberately stated so nobody trusts it too far:
// a from-domain that still matches the site but is no longer verified with
// the provider. Only a real send result can see that (see the recordAIResult
// pattern in ai_health.go for the shape that would).
const (
	senderCheckOK       = "ok"
	senderCheckMismatch = "mismatch"
	senderCheckSkipped  = "skipped"
)

// senderDomainState compares SMTP_FROM's domain with the public base URL's
// host. Pure: both inputs are passed in so this is testable without env.
//
// "skipped" is a real answer, not a failure — it means the question isn't
// meaningful here (no sender configured, or a localhost base URL in dev),
// and it must stay distinguishable from "ok" so a deployment check can't read
// "we never looked" as "we looked and it was fine".
func senderDomainState(from, baseURL string) string {
	sender := senderDomain(from)
	site := siteHost(baseURL)
	if sender == "" || site == "" || isLocalHost(site) {
		return senderCheckSkipped
	}
	if domainsAlign(sender, site) {
		return senderCheckOK
	}
	return senderCheckMismatch
}

// senderDomain pulls the domain out of an SMTP_FROM value. Bare addresses are
// the documented form (a `Name <addr>` display form breaks the envelope with a
// 501 — see dockerize/production/REHOME.md), but parse the angle-bracket shape
// anyway rather than silently reporting a mismatch for it.
func senderDomain(from string) string {
	s := strings.TrimSpace(from)
	if i := strings.LastIndex(s, "<"); i >= 0 {
		if j := strings.Index(s[i:], ">"); j > 0 {
			s = s[i+1 : i+j]
		}
	}
	at := strings.LastIndex(s, "@")
	if at < 0 {
		return ""
	}
	return strings.ToLower(strings.TrimSpace(s[at+1:]))
}

// siteHost is the public base URL's hostname, with a leading www. dropped so
// www.example.com and example.com are the same site.
func siteHost(baseURL string) string {
	u, err := url.Parse(strings.TrimSpace(baseURL))
	if err != nil {
		return ""
	}
	return strings.TrimPrefix(strings.ToLower(u.Hostname()), "www.")
}

func isLocalHost(host string) bool {
	return host == "localhost" || host == "127.0.0.1" || host == "::1"
}

// domainsAlign accepts an exact match or either side being a subdomain of the
// other, because sending from a subdomain (mail.example.com) is ordinary
// practice. The dot boundary is what keeps notexample.com from matching
// example.com.
func domainsAlign(sender, site string) bool {
	if sender == "" || site == "" {
		return false
	}
	return sender == site ||
		strings.HasSuffix(sender, "."+site) ||
		strings.HasSuffix(site, "."+sender)
}

// EmailAvailabilityResponse mirrors the other */availability endpoints
// (google, apple, transcribe, mcp): public, unauthenticated, and carrying only
// derived verdicts — never the address, host, or credentials themselves.
type EmailAvailabilityResponse struct {
	Available bool `json:"available"`
	// "ok" | "mismatch" | "skipped" — see senderDomainState.
	SenderDomainCheck string `json:"sender_domain_check"`
}

func emailAvailabilityHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, EmailAvailabilityResponse{
		Available:         emailService.Configured(),
		SenderDomainCheck: senderDomainState(emailService.From, publicBaseURL()),
	})
}
