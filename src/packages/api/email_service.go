package main

import (
	"fmt"
	"log"
	"net/smtp"
	"os"
	"strings"
)

// EmailService sends transactional mail over SMTP configured via env
// (SMTP_HOST/PORT/USERNAME/PASSWORD/FROM). Any SMTP provider works (Resend,
// Postmark, SES...) — swapping providers is an env change, no code. Missing
// config is degraded mode, same convention as a missing DUFFEL_ACCESS_TOKEN:
// the API stays healthy, sends are skipped with a log line that includes the
// would-be message so local dev can complete verify/reset flows from logs.
type EmailService struct {
	Host     string
	Port     string
	Username string
	Password string
	From     string
}

var emailService = NewEmailService()

func NewEmailService() *EmailService {
	s := &EmailService{
		Host:     os.Getenv("SMTP_HOST"),
		Port:     os.Getenv("SMTP_PORT"),
		Username: os.Getenv("SMTP_USERNAME"),
		Password: os.Getenv("SMTP_PASSWORD"),
		From:     os.Getenv("SMTP_FROM"),
	}
	if s.Port == "" {
		s.Port = "587"
	}
	if !s.Configured() {
		fmt.Println("Warning: SMTP_HOST/SMTP_FROM not set; email delivery disabled (verify/reset tokens will be logged instead)")
	}
	return s
}

func (s *EmailService) Configured() bool {
	return s.Host != "" && s.From != ""
}

// Send delivers a plain-text transactional email (verify/reset). Left untouched
// by the marketing plumbing — transactional mail is never unsubscribable.
func (s *EmailService) Send(to, subject, body string) error {
	return s.SendWithHeaders(to, subject, body, nil)
}

// SendMarketing delivers a plain-text marketing email (reminders, weekly nudge)
// carrying the RFC 8058 one-click unsubscribe headers built from unsubscribeURL.
// The URL must be the public /api/v1/unsubscribe/<token> capability link. The
// List-Unsubscribe-Post header opts the message into one-click: a supporting
// mail client can POST that URL directly, no page visit, honoring the opt-out.
func (s *EmailService) SendMarketing(to, subject, body, unsubscribeURL string) error {
	return s.SendWithHeaders(to, subject, body, listUnsubscribeHeaders(unsubscribeURL))
}

// listUnsubscribeHeaders returns the ordered List-Unsubscribe + -Post header
// lines for a one-click unsubscribe URL, or nil when the URL is empty. Pure and
// deterministic (ordered slice, not a map) so header construction unit-tests
// cleanly. RFC 8058 requires both headers together for one-click to be honored.
func listUnsubscribeHeaders(unsubscribeURL string) []string {
	if strings.TrimSpace(unsubscribeURL) == "" {
		return nil
	}
	return []string{
		"List-Unsubscribe: <" + unsubscribeURL + ">",
		"List-Unsubscribe-Post: List-Unsubscribe=One-Click",
	}
}

// SendWithHeaders delivers a plain-text email with optional extra header lines
// (each "Key: value", CRLF is added by the framer). In degraded mode it logs the
// message and reports success so callers never surface delivery as a
// user-facing error.
func (s *EmailService) SendWithHeaders(to, subject, body string, extraHeaders []string) error {
	if !s.Configured() {
		// The full body carries verify/reset tokens and one-click unsubscribe
		// links — invaluable for grabbing a token in local dev, but a secret
		// leak if SMTP is ever unset in production. Log it only outside
		// production; production gets a masked, body-free line.
		if os.Getenv("GO_ENV") == "production" {
			log.Printf("email (not sent, SMTP unconfigured) to=%s subject=%q", maskEmail(to), subject)
		} else {
			log.Printf("email (not sent, SMTP unconfigured) to=%s subject=%q headers=%v body=%q", to, subject, extraHeaders, body)
		}
		return nil
	}
	msg := buildEmailMessage(s.From, to, subject, body, extraHeaders)

	var auth smtp.Auth
	if s.Username != "" {
		auth = smtp.PlainAuth("", s.Username, s.Password, s.Host)
	}
	return smtp.SendMail(s.Host+":"+s.Port, auth, s.From, []string{to}, []byte(msg))
}

// buildEmailMessage frames the RFC 5322 message (CRLF-delimited). Pure so the
// header block — including any List-Unsubscribe lines — is unit-testable without
// an SMTP server. extraHeaders sit after the fixed headers, before the blank
// line that separates headers from the body.
func buildEmailMessage(from, to, subject, body string, extraHeaders []string) string {
	lines := []string{
		"From: " + from,
		"To: " + to,
		"Subject: " + subject,
		"MIME-Version: 1.0",
		"Content-Type: text/plain; charset=utf-8",
	}
	lines = append(lines, extraHeaders...)
	lines = append(lines, "", body)
	return strings.Join(lines, "\r\n")
}

// maskEmail reduces an address to a low-PII form for logs: it keeps the first
// (and, when the local part is long enough, last) character of the local part
// and the full domain, so a line stays useful for delivery debugging without
// recording who the recipient is — e.g. "brian@gmail.com" -> "b***n@gmail.com".
// A value without a usable local part is dropped entirely.
func maskEmail(email string) string {
	at := strings.LastIndexByte(email, '@')
	if at <= 0 || at == len(email)-1 {
		return "[redacted-email]"
	}
	local, domain := email[:at], email[at+1:]
	if len(local) <= 2 {
		return local[:1] + "***@" + domain
	}
	return local[:1] + "***" + local[len(local)-1:] + "@" + domain
}
