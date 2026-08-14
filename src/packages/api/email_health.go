package main

import (
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
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

// --- send-result tracking -----------------------------------------------
//
// The domain check above is static: it catches a sender pointing at the wrong
// domain, but not a right-looking domain the provider no longer accepts. Only
// a real send result sees that, so — exactly as ai_health.go does for the
// Anthropic call sites — the one place that sends mail classifies the error it
// already observes, and the ops health verdict reads the result.
//
// Same class rules as the AI tracker, for the same reasons: a permanent SMTP
// rejection is deterministic, is never retried, and does not heal on its own,
// so it alerts. Anything transient or unrecognized is counted and never
// alerts — a misread error that pages someone at 3am teaches people to ignore
// the pager.
//
// Known circularity, stated so nobody relies on the wrong channel: the alert
// path itself sends email (ops_monitor.go alertTransition), so a broken sender
// cannot page by email. The same transition also emits a Sentry-teed
// slog.Error and an in-app notification per admin, and those are what actually
// carry this one.

type emailErrorClass string

const (
	emailClassOK        emailErrorClass = "ok"
	emailClassFatal     emailErrorClass = "fatal"     // permanent rejection — alerts
	emailClassTransient emailErrorClass = "transient" // network/greylist — never alerts
	emailClassUnknown   emailErrorClass = "unknown"   // unrecognized — never alerts
)

// classifyEmailError maps one send result to a class plus a short human
// reason. Pure.
//
// It leads with the SMTP reply code, not the message text, because the text is
// provider-specific prose ("domain is not verified", "sender address rejected")
// that changes without notice while the codes are RFC 5321. An unrecognized
// error is deliberately NOT fatal: we would rather miss one outage than raise
// false alarms, which is the same call ai_health.go makes for unfamiliar
// provider envelopes.
func classifyEmailError(err error) (emailErrorClass, string) {
	if err == nil {
		return emailClassOK, ""
	}
	msg := err.Error()
	switch smtpReplyCode(msg) {
	case 535:
		return emailClassFatal, "authentication"
	case 550, 553:
		// What an unverified or unknown sending domain answers.
		return emailClassFatal, "sender rejected"
	case 554:
		return emailClassFatal, "transaction failed"
	case 421, 450, 451, 452:
		// 4xx is "try later" by definition.
		return emailClassTransient, "temporary"
	}
	// No parsable reply code: a dial/TLS/timeout failure, or something new.
	if isTransportError(msg) {
		return emailClassTransient, "transport"
	}
	return emailClassUnknown, ""
}

// smtpReplyCode reads the leading three-digit reply code from an SMTP error.
// Go's net/smtp renders these as "550 5.7.1 ..." — returns 0 when absent.
func smtpReplyCode(msg string) int {
	s := strings.TrimSpace(msg)
	if len(s) < 3 {
		return 0
	}
	code := 0
	for i := 0; i < 3; i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0
		}
		code = code*10 + int(s[i]-'0')
	}
	// Guard against matching a bare number inside prose.
	if len(s) > 3 && s[3] != ' ' && s[3] != '-' {
		return 0
	}
	return code
}

func isTransportError(msg string) bool {
	m := strings.ToLower(msg)
	for _, hint := range []string{
		"timeout", "timed out", "connection refused", "no such host",
		"network is unreachable", "broken pipe", "connection reset", "eof",
		"i/o timeout", "tls",
	} {
		if strings.Contains(m, hint) {
			return true
		}
	}
	return false
}

type emailHealthTracker struct {
	mu              sync.Mutex
	lastSuccessAt   time.Time
	lastFatalAt     time.Time
	lastFatalReason string
	successTotal    int64
	transientTotal  int64
	fatalTotal      int64
}

var emailHealth = &emailHealthTracker{}

// emailHealthState is a consistent read snapshot; a plain value struct so
// computeHealthState stays pure and tests construct it literally.
type emailHealthState struct {
	Failing        bool
	Reason         string
	LastFatalAt    time.Time
	LastSuccessAt  time.Time
	SuccessTotal   int64
	TransientTotal int64
	FatalTotal     int64
}

// record folds one classified send in. Transient/unknown results touch neither
// timestamp, so a blip during a real outage cannot fake a recovery.
func (t *emailHealthTracker) record(now time.Time, class emailErrorClass, reason string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	switch class {
	case emailClassOK:
		t.lastSuccessAt = now
		t.successTotal++
	case emailClassFatal:
		t.lastFatalAt = now
		t.lastFatalReason = reason
		t.fatalTotal++
	case emailClassTransient, emailClassUnknown:
		t.transientTotal++
	}
}

// state returns the snapshot the health verdict and metrics read. Failing
// clears only on the next successful send — with no mail traffic a fatal state
// persists, which is correct: a rejected sender does not fix itself, and this
// whole file exists because a silent two-week version of exactly that went
// unnoticed.
func (t *emailHealthTracker) state() emailHealthState {
	t.mu.Lock()
	defer t.mu.Unlock()
	return emailHealthState{
		Failing:        !t.lastFatalAt.IsZero() && t.lastFatalAt.After(t.lastSuccessAt),
		Reason:         t.lastFatalReason,
		LastFatalAt:    t.lastFatalAt,
		LastSuccessAt:  t.lastSuccessAt,
		SuccessTotal:   t.successTotal,
		TransientTotal: t.transientTotal,
		FatalTotal:     t.fatalTotal,
	}
}

// recordEmailResult is the one-liner the send site uses, exactly once per send
// attempt (nil err records a success).
func recordEmailResult(err error) (emailErrorClass, string) {
	class, reason := classifyEmailError(err)
	emailHealth.record(time.Now(), class, reason)
	return class, reason
}
