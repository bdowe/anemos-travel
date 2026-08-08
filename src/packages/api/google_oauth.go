package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// Server-side Google OAuth client (specs/google-sso): authorization-code flow
// with PKCE, hand-rolled like the other providers (duffel_service.go). Env is
// read lazily per request so tests can t.Setenv, and the endpoint URLs have
// overrides as a test seam (same idea as ANTHROPIC_BASE_URL).

var googleOAuthHTTPClient = newUpstreamClient(15 * time.Second)

func googleOAuthClientID() string     { return os.Getenv("GOOGLE_OAUTH_CLIENT_ID") }
func googleOAuthClientSecret() string { return os.Getenv("GOOGLE_OAUTH_CLIENT_SECRET") }

func googleOAuthConfigured() bool {
	return googleOAuthClientID() != "" && googleOAuthClientSecret() != ""
}

func googleAuthURL() string {
	if u := os.Getenv("GOOGLE_OAUTH_AUTH_URL"); u != "" {
		return u
	}
	return "https://accounts.google.com/o/oauth2/v2/auth"
}

func googleTokenURL() string {
	if u := os.Getenv("GOOGLE_OAUTH_TOKEN_URL"); u != "" {
		return u
	}
	return "https://oauth2.googleapis.com/token"
}

// googleRedirectURI must exactly match an authorized redirect URI registered
// on the Google Cloud OAuth client.
func googleRedirectURI() string {
	return publicBaseURL() + "/api/v1/auth/google/callback"
}

// randomURLToken returns 32 random bytes as unpadded base64url, safe for both
// URLs and PKCE verifiers (RFC 7636 §4.1 alphabet).
func randomURLToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

func pkceChallenge(verifier string) string {
	sum := sha256.Sum256([]byte(verifier))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

type googleClaims struct {
	Iss           string `json:"iss"`
	Aud           string `json:"aud"`
	Sub           string `json:"sub"`
	Email         string `json:"email"`
	EmailVerified bool   `json:"email_verified"`
	Name          string `json:"name"`
	Exp           int64  `json:"exp"`
}

// exchangeGoogleCode swaps the authorization code for tokens and returns the
// validated ID-token claims. The id_token arrives directly from Google's token
// endpoint over TLS, so signature verification is unnecessary (per Google's
// docs); claim validation still guards iss/aud/exp/sub.
func exchangeGoogleCode(ctx context.Context, code, verifier string) (googleClaims, error) {
	form := url.Values{
		"code":          {code},
		"client_id":     {googleOAuthClientID()},
		"client_secret": {googleOAuthClientSecret()},
		"redirect_uri":  {googleRedirectURI()},
		"grant_type":    {"authorization_code"},
		"code_verifier": {verifier},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, googleTokenURL(), strings.NewReader(form.Encode()))
	if err != nil {
		return googleClaims{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := googleOAuthHTTPClient.Do(req)
	if err != nil {
		return googleClaims{}, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return googleClaims{}, err
	}
	if resp.StatusCode != http.StatusOK {
		return googleClaims{}, fmt.Errorf("token endpoint returned %d: %s", resp.StatusCode, body)
	}
	var tok struct {
		IDToken string `json:"id_token"`
	}
	if err := json.Unmarshal(body, &tok); err != nil {
		return googleClaims{}, err
	}
	return parseGoogleIDToken(tok.IDToken)
}

func parseGoogleIDToken(idToken string) (googleClaims, error) {
	parts := strings.Split(idToken, ".")
	if len(parts) != 3 {
		return googleClaims{}, errors.New("id_token is not a JWT")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return googleClaims{}, fmt.Errorf("id_token payload: %w", err)
	}
	var claims googleClaims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return googleClaims{}, fmt.Errorf("id_token claims: %w", err)
	}
	if claims.Iss != "https://accounts.google.com" && claims.Iss != "accounts.google.com" {
		return googleClaims{}, fmt.Errorf("unexpected issuer %q", claims.Iss)
	}
	if claims.Aud != googleOAuthClientID() {
		return googleClaims{}, errors.New("id_token audience mismatch")
	}
	if claims.Exp <= time.Now().Unix() {
		return googleClaims{}, errors.New("id_token expired")
	}
	if claims.Sub == "" {
		return googleClaims{}, errors.New("id_token missing sub")
	}
	return claims, nil
}
