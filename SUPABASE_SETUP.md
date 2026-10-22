# Supabase development setup and F5a handoff

Updated 23 October 2026. Supports [specification v0.11](forest_game_v1_spec.md) sections 7.4–7.5 and the [F5a implementation plan](IMPLEMENTATION_PLAN.md). Auth source is implemented; cloud provisioning and native/live-provider acceptance are pending. **Use [F5A_AUTH_ACCEPTANCE.md](frontend/F5A_AUTH_ACCEPTANCE.md) for exact artifact locations and the current email-first iPhone walkthrough.** Dashboard labels can change; use the linked provider documentation for the current screens.

## 1. Create a development project now

1. Sign into [Supabase Dashboard](https://supabase.com/dashboard), create/select your organisation and create a project such as **movement-forest-dev**.
2. Start on the **Free** plan if the organisation is eligible. Real authentication does not require Pro. Choose a region near the expected initial players and a suitable future Cloud Run region; check both vendors' available regions before choosing production placement.
3. Generate a strong database password and save it privately. Project creation includes PostgreSQL, but F5a will continue using the existing local game database.
4. Record the project reference, project URL (`https://<project-ref>.supabase.co`) and **publishable API key** from the project's connection/API settings. The URL/key go into future iOS environment configuration; they are not player login credentials. Keep secret/service-role keys and the database password out of the app and Git.
5. Keep this project for development identities. Add separate staging/production projects when needed; do not assume moving a project URL preserves Auth user IDs.

Free currently costs US$0/month and can pause after inactivity. Pro currently starts at US$25/month; it is a later availability/quota/backup decision, not an auth setup fee. SMTP, Apple programme membership and Cloud Run have separate terms/costs. See [Supabase pricing](https://supabase.com/pricing).

## 2. Fix the app identifier and callback values

Before registering provider clients, choose a bundle ID controlled by your Apple developer team. The repository uses `com.example.movementforest` as a placeholder; select your own ID in Xcode for your device. The callback scheme defaults to that actual bundle ID. Put public client values in ignored `frontend/MovementForest/Configuration/Local.xcconfig`, copied from its adjacent example.

Use distinct values for the two callback hops:

| Value | Where it belongs | Proposed development value |
| --- | --- | --- |
| **Provider → Supabase callback** | Google authorised redirect URI; Apple web Return URL when used | `https://<project-ref>.supabase.co/auth/v1/callback` — copy the actual value from Supabase's provider panel |
| **Supabase → iOS callback** | Supabase Authentication URL Configuration redirect allowlist and the future app URL handler | `<chosen-bundle-id>://auth/callback` |
| **Supabase → iOS password recovery** | Redirect allowlist and future password-reset handler | `<chosen-bundle-id>://auth/reset-password` |

Add the exact chosen app URLs to Supabase's redirect allowlist. Set the Site URL to the intended default app return URL for this mobile development project; a production website can supply a web fallback later. Implemented signup/reset calls supply the allowed redirect. Info.plist registers the configured scheme; the app routes SDK confirmation/recovery callbacks using PKCE, and native Apple uses a fresh nonce. Do not put the local FastAPI/Tailscale origin in the provider callback field; it is the game API address, not an OAuth callback.

See [redirect configuration](https://supabase.com/docs/guides/auth/redirect-urls) and [mobile deep linking](https://supabase.com/docs/guides/auth/native-mobile-deep-linking). Rebuild after configuring the URLs and test email links on the same iPhone/app installation that requested them.

## 3. Enable email/password and email delivery

In Supabase **Authentication → Sign In / Providers** (or the equivalent provider settings), enable Email and keep email confirmation enabled. Configure confirmation and password-reset templates for the chosen app redirects. The game login label is **Email**, with a separate game username selected after authentication; no username/password lookup service is planned. See [password authentication](https://supabase.com/docs/guides/auth/passwords).

For signup/reset testing beyond the project's authorised team addresses, configure **custom SMTP** under Authentication: sender address, SMTP host/port/user/password and the sending provider's domain verification. Supabase's built-in sender is restricted to project-team addresses and currently has a very low email limit, so do not use it as the external-test email service. Test delivery, confirmation and password recovery on the actual phone during F5a. See [SMTP setup](https://supabase.com/docs/guides/auth/auth-smtp).

## 4. Configure Google

1. Create/select a Google Cloud project and configure **Google Auth Platform** branding, audience/consent and required support contact. Add development test users if the consent configuration is in testing mode.
2. Create a **Web application OAuth client** for the initial SDK browser flow and linking. Add the provider callback from step 2 as an authorised redirect URI.
3. Enable Google in Supabase and save that client ID and secret there. The secret stays in provider configuration.
4. Set `FOREST_AUTH_GOOGLE_ENABLED = YES` in the app's `Local.xcconfig` and rebuild when ready. The implemented system-browser login/linking needs no native Google SDK or iOS client ID. If a native Google flow is chosen later, register its additional client/callback configuration then.

Use the current [Supabase Google setup](https://supabase.com/docs/guides/auth/social-login/auth-google). Keep the feature flag `NO` for the first email/password test.

## 5. Configure Apple

1. In Apple Developer, register the chosen App ID and enable **Sign in with Apple**. Select the matching Xcode developer team/provisioning; the native `AuthenticationServices` flow is implemented.
2. Enable Apple in Supabase; allow the native bundle ID for ID-token exchange. Follow the [Apple provider setup](https://supabase.com/docs/guides/auth/social-login/auth-apple).
3. The pinned Swift SDK supports **native Apple ID-token linking**, which this app implements. Set `FOREST_AUTH_APPLE_ENABLED = YES` and use the supplied optional `MovementForestApple.entitlements` through `CODE_SIGN_ENTITLEMENTS` in `Local.xcconfig`. Keep the original HealthKit-only entitlement/flag `NO` for email-first testing. See the exact path in [F5a section 7](frontend/F5A_AUTH_ACCEPTANCE.md#7-enable-native-apple-later).

No web Services ID/client secret is required for this native Apple login/linking path. If adding browser Apple later, provision its Services ID/signing key/client secret separately and manage expiry then. If email is sent to Apple relay addresses, [register the outbound sender with Apple](https://developer.apple.com/help/account/capabilities/configure-private-email-relay-service/) and test delivery too.

## 6. Enable and test identity linking

Enable **Allow/Enable Manual Linking** in the project's Authentication settings. Supabase currently labels manual linking beta, so prove the chosen Swift flow during A1 before relying on it. Check the [Swift linking API](https://supabase.com/docs/reference/swift/auth-linkidentity); the operation requires a signed-in user and rejects an identity already owned elsewhere.

Use two deliberately different test scenarios during F5a:

- **One account with multiple methods:** sign in to the garden you want to keep, then choose **Link Google/Apple** from account settings. Prove sign-in through either method returns the same Supabase user ID and the same FastAPI game profile/garden. Include an Apple Hide My Email address differing from Google's email.
- **Two already-existing accounts:** deliberately create a separate second Auth user first, then attempt linking its provider to the first. Expect a conflict and unchanged gardens. Linking is not a garden-merge service.

Supabase may automatically link matching verified emails; do not use email matching as the game's ownership rule. For a social account that needs email/password access, use authenticated email verification/password setup rather than a fresh signup. See [identity behaviour](https://supabase.com/docs/guides/auth/auth-identity-linking).

## 7. Prepare FastAPI verification values

In the project's JWT signing-key settings, confirm an active **asymmetric** key supported by the backend: ES256 or RS256. Record which algorithm is actually active; the backend's current default is RS256, so an ES256 project needs an explicit matching setting. Do not copy the legacy JWT secret into the app or use HS256 with the JWKS verifier. See [signing keys](https://supabase.com/docs/guides/auth/signing-keys).

Put these **local integration environment** values in `backend/.env`, using `.env.supabase.example` as a template. Compose forwards them; no actual local `.env` or credentials have been written by this implementation:

| Setting | Intended value |
| --- | --- |
| `FOREST_ENVIRONMENT` | `local` |
| `FOREST_DATABASE_URL` | Keep the current Docker PostgreSQL URL, including `postgresql+psycopg` driver |
| `FOREST_AUTH_MODE` | `jwks` |
| `FOREST_AUTH_ISSUER` | `https://<project-ref>.supabase.co/auth/v1` |
| `FOREST_AUTH_AUDIENCE` | `authenticated` |
| `FOREST_AUTH_JWKS_URL` | `https://<project-ref>.supabase.co/auth/v1/.well-known/jwks.json` |
| `FOREST_AUTH_ALGORITHM` | Match the active key, normally `ES256` or `RS256` |

The app sends a Supabase **user access token**, not its publishable API key or Apple's/Google's raw ID token, to FastAPI. Verification uses public JWKS; no Supabase admin secret is needed for ordinary game requests. Generated-token test configurations remain separate. See [JWT verification](https://supabase.com/docs/guides/auth/jwts).

For local iPhone testing, retain the existing private HTTPS route to FastAPI described in [F5 acceptance](frontend/F5_ACCEPTANCE.md). Login and refresh contact hosted Supabase/provider services over the internet; game requests still reach the local API/database.

## 8. Keep the game database and assets local for F5a

Do not apply game migrations to the hosted database or upload runtime assets merely to test Auth. If the project's Data API is unused, disable it in API/Data API settings. Before a later game-schema migration, explicitly verify that `anon`/`authenticated` clients cannot reach private game tables or bypass FastAPI; private state is not exposed just because the app has a publishable key. See [Data API security](https://supabase.com/docs/guides/api/securing-your-api).

When B10 moves the database, take connection details from Supabase's **Connect** panel and validate TLS, network reachability, least-privilege runtime credentials and migrations. For transaction pooling, explicitly address psycopg prepared statements/session-state limitations; bound Cloud Run instances and per-instance pools together. Test migrations through an appropriate direct/session connection and exercise activity/placement concurrency before cutover. It is more than replacing a hostname. See [database connections](https://supabase.com/docs/guides/database/connecting-to-postgres).

When remote assets are implemented, create a public-read catalogue bucket such as `game-assets`; permit writes only to trusted publishing tooling. Use immutable versioned paths, manifests/checksums and the app's planned download cache. Basic Storage CDN works on Free; Smart CDN requires Pro or above. The current bundled-only asset resolver needs implementation before the app can use that delivery path. See [Storage CDN](https://supabase.com/docs/guides/storage/cdn/fundamentals) and [Smart CDN](https://supabase.com/docs/guides/storage/cdn/smart-cdn).

## 9. Configuration handoff and validation

Keep a private configuration record with:

- Development Supabase project URL/reference and publishable key.
- Chosen development bundle ID, exact app callback/reset URLs and private HTTPS game API origin.
- Active signing algorithm and the issuer/audience/JWKS values above.
- Enabled provider IDs, manual-linking setting and consent test-user list.
- SMTP sender/domain/provider and Apple web-secret expiry, if applicable; store secret values in the relevant provider/secret manager, not this repository or chat.

Email/password can be configured and tested first. Supabase source integration is implemented in Debug/Release when configured; generated tokens remain isolated Debug tooling for an unconfigured app. Complete the native and real-provider acceptance in [F5A_AUTH_ACCEPTANCE.md](frontend/F5A_AUTH_ACCEPTANCE.md) before calling F5a validated. No project or credentials were provisioned automatically.
