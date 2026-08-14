# Plan: Sign in with Apple

Sibling of specs/google-sso — same server-side redirect flow, `/sso/<code>`
handoff, and linking rules, implemented in `apple_oauth.go` +
`apple_auth_handler.go` with zero new dependencies. Ships dark until Apple
Developer Program enrollment (see Ops runbook below).

## Deltas vs Google

1. **ES256 client-secret JWT** (`appleClientSecret` in apple_oauth.go): Apple
   has no static secret; we sign `{iss: TEAM_ID, sub: SERVICES_ID, aud:
   appleid.apple.com, iat, exp: +5min}` with the `.p8` P-256 key using
   stdlib `crypto/ecdsa`. The signature is **raw r||s, each half left-padded
   to 32 bytes — not ASN.1 DER** (`ecdsa.SignASN1` would be wrong). The fake
   token endpoint verifies the JWT with `ecdsa.Verify`, so a regression
   fails tests.
2. **form_post callback**: requesting `scope=name email` requires
   `response_mode=form_post`, so `/auth/apple/callback` is a **POST** and the
   state cookie (`apple_oauth_state`) is **SameSite=None; Secure** — Lax
   cookies don't ride cross-site POSTs. Secure is unconditional: Apple
   rejects http/localhost return URLs, so a local browser flow is impossible
   regardless; integration tests attach the cookie to httptest requests.
3. **No PKCE** — Apple doesn't support it; the fake rejects `code_verifier`
   at the wire. CSRF = state cookie + one-time code + client-secret JWT.
4. **Name arrives once**: first authorization only, via the `user` form
   field (`parseAppleUserField`); fallback `defaultDisplayName(email)`.
5. **flexBool**: `email_verified` / `is_private_email` arrive as bool or
   string. Relay addresses get no special casing — they're verified, real,
   deliverable-via-relay addresses that simply never match existing accounts.
6. **No id_token signature verification** — same server-to-server TLS trust
   decision as `parseGoogleIDToken`, same unsigned-JWT test fake.
7. **Exchange generalized**: `googleExchangeHandler` → `ssoExchangeHandler`
   at `/auth/sso/exchange` (Flutter now calls this); `/auth/google/exchange`
   kept as an alias for handoff codes in-flight across the deploy.

## Key files

- API: `apple_oauth.go`, `apple_auth_handler.go`,
  `migrations/00048_apple_sso.sql` (provider CHECK → `('google','apple')`;
  down deletes only stranded Apple-only accounts), routes in `main.go`.
- Tests: `fake_apple_test.go` (in-test P-256 key; verifies the client-secret
  JWT cryptographically), `apple_auth_integration_test.go` (13 cases).
- Flutter: `widgets/sso_buttons.dart` (shared divider + both buttons),
  `widgets/apple_sign_in_button.dart` (HIG black button, `Icons.apple` glyph
  — no asset needed), `appleSsoAvailableProvider`, `appleSignInAvailable` +
  `exchangeSsoCode`→`/auth/sso/exchange` in `services/auth_service.dart`.

## Configuration

`APPLE_TEAM_ID`, `APPLE_CLIENT_ID` (the Services ID), `APPLE_KEY_ID`,
`APPLE_PRIVATE_KEY` (.p8 base64-encoded to one line). Any missing ⇒ degraded
mode. Test seams: `APPLE_AUTH_URL` / `APPLE_TOKEN_URL`.

## Ops runbook (post-enrollment)

1. Enroll in the Apple Developer Program (developer.apple.com, $99/yr; the
   Golden Tempo LLC route needs a D-U-N-S number — allow days to weeks).
2. Certificates, Identifiers & Profiles → Identifiers → create an **App ID**
   (primary), then a **Services ID** `com.goldentempotravel.web` with
   "Sign In with Apple" enabled → this is `APPLE_CLIENT_ID`.
3. Configure the Services ID: register domain `anemos.travel` and
   Return URL exactly `https://anemos.travel/api/v1/auth/apple/callback`.
   (The Services ID identifier itself stays `com.goldentempotravel.web` —
   already registered with Apple; only the domain/return URL are new.)
4. Keys → create a key with "Sign In with Apple" → download
   `AuthKey_<KEY_ID>.p8` (**one-time download** — store it in the password
   manager), note the Key ID and the Team ID (console top-right).
5. On the Pi: `base64 -i AuthKey_<KEY_ID>.p8 | tr -d '\n'` → set the four
   `APPLE_*` vars in `/opt/goldentempo/.env`, recreate the api container,
   confirm `curl https://anemos.travel/api/v1/auth/apple/availability`
   → `{"available":true}` and the button appears.
6. **Email relay**: Certificates → Services → "Sign In with Apple for Email
   Communication" → register the transactional-email sending domain/address
   (SPF/DKIM must pass) so password-reset mail reaches
   `@privaterelay.appleid.com` users.
7. Smoke: full prod sign-in; name capture (to re-trigger the first-auth
   consent, revoke the grant at appleid.apple.com → Sign-In & Security →
   Sign in with Apple); a Hide-My-Email signup; auto-link with an existing
   email+password account.
