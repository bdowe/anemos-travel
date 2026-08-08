package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// Server-side Sign in with Apple client (specs/apple-sso), the sibling of
// google_oauth.go. Same hand-rolled style and lazy-env/test-seam conventions.
// Apple differences: the client_secret is an ES256-signed JWT built from a
// .p8 key (not a static string), PKCE is not supported, and the callback is a
// form_post POST (see apple_auth_handler.go).

var appleOAuthHTTPClient = newUpstreamClient(15 * time.Second)

func appleTeamID() string   { return os.Getenv("APPLE_TEAM_ID") }
func appleClientID() string { return os.Getenv("APPLE_CLIENT_ID") } // the Services ID
func appleKeyID() string    { return os.Getenv("APPLE_KEY_ID") }

// applePrivateKeyB64 is the .p8 file base64-encoded to survive env_file's
// single-line rule: base64 -i AuthKey_<KEY_ID>.p8 | tr -d '\n'
func applePrivateKeyB64() string { return os.Getenv("APPLE_PRIVATE_KEY") }

func appleOAuthConfigured() bool {
	return appleTeamID() != "" && appleClientID() != "" &&
		appleKeyID() != "" && applePrivateKeyB64() != ""
}

func appleAuthURL() string {
	if u := os.Getenv("APPLE_AUTH_URL"); u != "" {
		return u
	}
	return "https://appleid.apple.com/auth/authorize"
}

func appleTokenURL() string {
	if u := os.Getenv("APPLE_TOKEN_URL"); u != "" {
		return u
	}
	return "https://appleid.apple.com/auth/token"
}

// appleRedirectURI must exactly match a Return URL registered on the Apple
// Services ID.
func appleRedirectURI() string {
	return publicBaseURL() + "/api/v1/auth/apple/callback"
}

// appleClientSecret builds the ES256-signed JWT Apple requires as the
// client_secret. Generated fresh per request with a short exp — Apple allows
// up to 6 months but caching buys nothing at our volume.
func appleClientSecret(now time.Time) (string, error) {
	pemBytes, err := base64.StdEncoding.DecodeString(applePrivateKeyB64())
	if err != nil {
		return "", fmt.Errorf("APPLE_PRIVATE_KEY is not base64: %w", err)
	}
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return "", errors.New("APPLE_PRIVATE_KEY does not decode to PEM")
	}
	keyAny, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return "", fmt.Errorf("APPLE_PRIVATE_KEY: %w", err)
	}
	key, ok := keyAny.(*ecdsa.PrivateKey)
	if !ok {
		return "", errors.New("APPLE_PRIVATE_KEY is not an ECDSA key")
	}

	header, err := json.Marshal(map[string]string{"alg": "ES256", "kid": appleKeyID()})
	if err != nil {
		return "", err
	}
	payload, err := json.Marshal(map[string]any{
		"iss": appleTeamID(),
		"sub": appleClientID(),
		"aud": "https://appleid.apple.com",
		"iat": now.Unix(),
		"exp": now.Add(5 * time.Minute).Unix(),
	})
	if err != nil {
		return "", err
	}
	signingInput := base64.RawURLEncoding.EncodeToString(header) + "." +
		base64.RawURLEncoding.EncodeToString(payload)
	sum := sha256.Sum256([]byte(signingInput))
	r, s, err := ecdsa.Sign(rand.Reader, key, sum[:])
	if err != nil {
		return "", err
	}
	// JWT ES256 signatures are raw r||s with each half left-padded to 32
	// bytes — not the ASN.1 DER that ecdsa.SignASN1 produces.
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}

// flexBool tolerates Apple sending booleans as JSON bools or as the strings
// "true"/"false" (both occur in the wild for email_verified/is_private_email).
type flexBool bool

func (b *flexBool) UnmarshalJSON(data []byte) error {
	v, err := strconv.ParseBool(strings.Trim(string(data), `"`))
	if err != nil {
		return fmt.Errorf("not a boolean: %s", data)
	}
	*b = flexBool(v)
	return nil
}

type appleClaims struct {
	Iss            string   `json:"iss"`
	Aud            string   `json:"aud"`
	Sub            string   `json:"sub"`
	Email          string   `json:"email"`
	EmailVerified  flexBool `json:"email_verified"`
	IsPrivateEmail flexBool `json:"is_private_email"`
	Exp            int64    `json:"exp"`
}

// exchangeAppleCode swaps the authorization code for tokens and returns the
// validated ID-token claims. No PKCE verifier — Apple doesn't support it; the
// ES256 client secret authenticates us instead. Signature verification is
// skipped for the same reason as Google's: the token arrives directly from
// Apple's token endpoint over TLS.
func exchangeAppleCode(ctx context.Context, code string) (appleClaims, error) {
	secret, err := appleClientSecret(time.Now())
	if err != nil {
		return appleClaims{}, err
	}
	form := url.Values{
		"code":          {code},
		"client_id":     {appleClientID()},
		"client_secret": {secret},
		"redirect_uri":  {appleRedirectURI()},
		"grant_type":    {"authorization_code"},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, appleTokenURL(), strings.NewReader(form.Encode()))
	if err != nil {
		return appleClaims{}, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := appleOAuthHTTPClient.Do(req)
	if err != nil {
		return appleClaims{}, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return appleClaims{}, err
	}
	if resp.StatusCode != http.StatusOK {
		return appleClaims{}, fmt.Errorf("token endpoint returned %d: %s", resp.StatusCode, body)
	}
	var tok struct {
		IDToken string `json:"id_token"`
	}
	if err := json.Unmarshal(body, &tok); err != nil {
		return appleClaims{}, err
	}
	return parseAppleIDToken(tok.IDToken)
}

func parseAppleIDToken(idToken string) (appleClaims, error) {
	parts := strings.Split(idToken, ".")
	if len(parts) != 3 {
		return appleClaims{}, errors.New("id_token is not a JWT")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return appleClaims{}, fmt.Errorf("id_token payload: %w", err)
	}
	var claims appleClaims
	if err := json.Unmarshal(payload, &claims); err != nil {
		return appleClaims{}, fmt.Errorf("id_token claims: %w", err)
	}
	if claims.Iss != "https://appleid.apple.com" {
		return appleClaims{}, fmt.Errorf("unexpected issuer %q", claims.Iss)
	}
	if claims.Aud != appleClientID() {
		return appleClaims{}, errors.New("id_token audience mismatch")
	}
	if claims.Exp <= time.Now().Unix() {
		return appleClaims{}, errors.New("id_token expired")
	}
	if claims.Sub == "" {
		return appleClaims{}, errors.New("id_token missing sub")
	}
	return claims, nil
}

// parseAppleUserField extracts a display name from the `user` form field
// Apple posts on the FIRST authorization only (never in the id_token).
// Best-effort: any parse failure just yields "".
func parseAppleUserField(raw string) string {
	if raw == "" {
		return ""
	}
	var u struct {
		Name struct {
			FirstName string `json:"firstName"`
			LastName  string `json:"lastName"`
		} `json:"name"`
	}
	if err := json.Unmarshal([]byte(raw), &u); err != nil {
		return ""
	}
	return strings.TrimSpace(strings.TrimSpace(u.Name.FirstName) + " " + strings.TrimSpace(u.Name.LastName))
}
