# Plan: Sign in with Google

Server-side OAuth 2.0 authorization-code flow with PKCE, handled entirely by
the Go API — no Flutter plugins, no new Go dependencies. Works because the
nginx gateway keeps the API and the app same-origin.

## Flow

```
Browser                       API (Go)                          Google
  |  click "Continue with Google" (same-tab nav)
  |----> GET /api/v1/auth/google
  |         set cookie google_oauth_state=<state>.<verifier>
  |<---- 302 accounts.google.com/o/oauth2/v2/auth?...state&code_challenge(S256)
  |----------------------------------------------------------> consent
  |<---------------------------- 302 /api/v1/auth/google/callback?code&state
  |----> GET callback (cookie rides along, SameSite=Lax top-level GET)
  |         state != cookie state --> 303 /sso/error
  |         POST token endpoint (code+verifier+secret) ---------->
  |         <--------------------------------- {id_token,...}
  |         decode+validate claims; find-or-create user (linking rules)
  |         one-time code: email_tokens purpose='sso', TTL 60s
  |<---- 303 {PUBLIC_BASE_URL}{PUBLIC_APP_PATH}sso/<code>
  |  Flutter onGenerateRoute -> SsoCallbackScreen
  |----> POST /api/v1/auth/google/exchange {code}
  |<---- 200 {user, token} -> adoptSession -> AuthGate (quiz if new)
```

## Design decisions

- **Hand-rolled OAuth client** (`google_oauth.go`): one redirect URL, one form
  POST, one JSON decode — same isolated-provider pattern as
  `duffel_service.go`, with `GOOGLE_OAUTH_AUTH_URL`/`GOOGLE_OAUTH_TOKEN_URL`
  env overrides as the test seam (like `ANTHROPIC_BASE_URL`).
- **ID token: claims validated, signature not verified.** The token arrives
  directly from Google's token endpoint over TLS (server-to-server), where
  Google documents signature verification as unnecessary. Checked: `iss`,
  `aud` == client id, `exp`, `sub` non-empty. Keeps tests trivial (the fake
  mints unsigned JWTs).
- **State + PKCE verifier in an HttpOnly cookie** (`google_oauth_state`,
  `<state>.<verifier>`, SameSite=Lax, Secure iff PUBLIC_BASE_URL is https,
  Path=/api/v1/auth/google, 10 min). Double-submit compare on the callback;
  no DB row or signing key needed.
- **Session handoff via one-time code** reusing `email_tokens` (purpose
  `sso`, 60s TTL, sha256-hashed, single-use) because the code transits a URL.
  Fragment tokens leak into history; cookie sessions would fork the app's
  bearer-header auth model.
- **`users.password_hash` nullable** (migration 00032) → sqlc regenerates as
  `*string`; `hasPassword`/`checkUserPassword` helpers guard the four
  credential call sites.
- **Linking rules** (`findOrCreateGoogleUser`): known (provider, sub) → sign
  in; verified matching email → auto-link + mark verified; verified new email
  → create SSO-only user (`user_registered` event, `{"method":"google"}`);
  unverified Google email → refuse (takeover guard).

## Key files

- API: `google_oauth.go`, `google_auth_handler.go`,
  `migrations/00032_google_sso.sql`, `query/auth_identities.sql`, route block
  in `main.go`, nil-hash handling in `auth_handler.go` / `account_handler.go`
  / `auth_service.go`.
- Tests: `fake_google_test.go` (fake token endpoint),
  `google_auth_integration_test.go` (11 cases: flow, linking, guards,
  SSO-only policies).
- Flutter: `widgets/google_sign_in_button.dart` (availability-gated, same-tab
  `launchUrl`), `screens/sso_callback_screen.dart`, `/sso/<code>` route in
  `main.dart`, `googleSsoAvailableProvider`, `exchangeSsoCode` in
  `services/auth_service.dart`, official G logo at
  `assets/images/google_g_logo.png`.

## Configuration

`GOOGLE_OAUTH_CLIENT_ID` + `GOOGLE_OAUTH_CLIENT_SECRET` (API `.env`, prod
`.env`). Create a **Web application** OAuth client at
https://console.cloud.google.com/apis/credentials and register
`<PUBLIC_BASE_URL>/api/v1/auth/google/callback` as an authorized redirect URI
— `http://localhost:3000/api/v1/auth/google/callback` for dev,
`https://anemos.travel/api/v1/auth/google/callback` for prod. Unset ⇒
degraded mode: button hidden, `/auth/google` answers 503, everything else
unaffected.
