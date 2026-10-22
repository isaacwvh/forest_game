# F5a: Supabase login and iPhone game walkthrough

Implemented 23 October 2026. Email/password is the first test path; Google/Apple are opt-in integrations and can be configured later. Native build/XCTest, real Supabase delivery/login and physical iPhone acceptance must be recorded on a Mac/iPhone. Windows syntax checks and locally signed integration tokens do not establish those results.

The game database stays in local PostgreSQL. Supabase authenticates the player; FastAPI owns their game profile, garden, starter and activity accounting. No cloud database/asset migration, visitor currency or account merge is included.

## 1. Put configuration in these exact locations

| Artifact | Location | Notes |
| --- | --- | --- |
| Supabase project URL, publishable API key and private HTTPS game API origin | **`frontend/MovementForest/Configuration/Local.xcconfig` on the Mac** | Copy the adjacent `Local.xcconfig.example`. This file is ignored by Git. Values are compiled into the app, so rebuild after changing them. Use a `sb_publishable_...` key; secret/service-role and legacy JWT keys are rejected by this client configuration. |
| Supabase issuer, audience, public JWKS URL and signing algorithm | **`backend/.env` on the Windows backend computer** | Use `backend/.env.supabase.example` as the template. Keep the existing game database URL. The backend does not need the publishable key or a Supabase admin secret for normal authentication. |
| Email delivery credentials | **Supabase Dashboard → Authentication → SMTP settings** | Store sender/SMTP secrets here, not in the app. Configure your sending domain with the SMTP provider. |
| Google OAuth client ID/secret | **Google Auth Platform and Supabase → Authentication → Google provider** | Optional until section 6. No Google secret belongs in iOS configuration. |
| Native Apple App ID/bundle ID | **Apple Developer → Identifiers**, Xcode app signing, and **Supabase → Authentication → Apple provider** | Optional until section 7. The same native bundle ID must be accepted by Supabase. |
| Apple signing key/Services ID/client secret | **Provider configuration/secret storage only, if adding a web Apple flow later** | The implemented native Apple login/linking does not require a browser Services ID/client secret. |

For example, on the Mac copy the file, then replace these values:

```xcconfig
FOREST_SUPABASE_URL = https:/$()/YOUR_PROJECT_REF.supabase.co
FOREST_SUPABASE_PUBLISHABLE_KEY = sb_publishable_YOUR_PUBLIC_KEY
FOREST_GAME_API_URL = https:/$()/YOUR_WINDOWS_HOST.YOUR_TAILNET.ts.net
FOREST_AUTH_GOOGLE_ENABLED = NO
FOREST_AUTH_APPLE_ENABLED = NO
```

Keep the `$()` spelling: it expands away and stops `//` from being interpreted as an xcconfig comment. `Auth.xcconfig` supplies defaults and includes `Local.xcconfig` automatically in both Debug and Release. Do not put these values in source files or edit Info.plist manually. The callback scheme defaults to the app's actual bundle identifier.

On Windows edit `backend/.env` using the new template, preserving unrelated existing values:

```dotenv
FOREST_ENVIRONMENT=local
FOREST_AUTH_MODE=jwks
FOREST_AUTH_ISSUER=https://YOUR_PROJECT_REF.supabase.co/auth/v1
FOREST_AUTH_AUDIENCE=authenticated
FOREST_AUTH_JWKS_URL=https://YOUR_PROJECT_REF.supabase.co/auth/v1/.well-known/jwks.json
FOREST_AUTH_ALGORITHM=ES256
```

Match `ES256`/`RS256` to the project's active asymmetric signing key. JWKS must expose that key. Do not use a legacy HS256 signing secret with this verifier. Docker Compose now forwards these settings; its database connection still points to the local `db` service. Host Uvicorn instead reads the local database URL in `backend/.env`.

## 2. Configure ordinary email/password in Supabase

1. Create/select a development project, initially on Free if eligible. Record its project URL and publishable key. No paid database move is needed.
2. Enable Email/password in Authentication provider settings. Keep email confirmation enabled. Set a password policy compatible with the app's minimum eight characters; stricter server requirements still apply.
3. Configure custom SMTP for real test addresses beyond project-team emails. Supabase's built-in email sender is restricted and is not an external-test mail service. Leave Google/Apple flags `NO` while testing email.
4. Choose the app's unique bundle identifier in Xcode, for example `com.yourname.movementforest`. In Supabase Authentication URL Configuration allow **both** `com.yourname.movementforest://auth/callback` and `com.yourname.movementforest://auth/reset-password`, substituting your actual ID. Set the development Site URL to the normal callback. An explicitly configured callback scheme must match the scheme compiled into the app.
5. Keep standard confirmation/recovery templates with the Supabase confirmation link. Signup/reset calls supply the correct redirect. Open the newest email link on the **same iPhone/app installation** that requested it because this flow uses PKCE; a Mac or different installation does not have its verifier.

See [password authentication](https://supabase.com/docs/guides/auth/passwords), [SMTP](https://supabase.com/docs/guides/auth/auth-smtp) and [mobile redirects](https://supabase.com/docs/guides/auth/native-mobile-deep-linking).

## 3. Start the game backend and private connection

From `C:\Users\Isaac\forest_game\backend` on Windows, with Docker Desktop running:

```powershell
# Edit the existing .env first; do not overwrite it blindly.
docker compose up -d db
docker compose build api migrate
docker compose run --rm migrate
docker compose run --rm -T api forest seed-dev
docker compose up -d --wait --wait-timeout 90 api
Invoke-RestMethod http://127.0.0.1:8000/health/ready
```

No new migration is required beyond the existing `0002_b4_b5`; seed-dev is repeat-safe and configures test catalogue values, not approved balance. Preserve the database volume. Restart/recreate the API after changing `.env`; a plain process restart may retain old container environment values. Compose's `up` recreates it when configuration changes.

Keep Windows/iPhone on the same authorised Tailscale network. Reuse the existing HTTPS Serve configuration from [F5 section 2](F5_ACCEPTANCE.md#2-reach-the-windows-api-privately-through-tailscale). On iPhone Safari, verify `https://YOUR_PRIVATE_HOST/health/ready` returns `{"status":"ready"}`. Use that origin in `FOREST_GAME_API_URL`. Supabase's provider callback points to **Supabase**, not this private API address.

Generated development tokens are not used in this flow and will be rejected in JWKS mode. Existing generated-token gardens have a different identity; use a fresh Supabase test account. No old gardens, growth, queues or database rows are reset/rebound automatically.

## 4. Build and test email login on iPhone

1. Transfer the entire updated repository to the Mac, including root assets/spec examples. Use **Xcode 16.3 or later (Swift 6.1+)**, and a newer compatible Xcode if your phone's iOS requires it. The app deployment target remains iOS 16.
2. Create `Local.xcconfig` using section 1. Open the existing Xcode project and let Swift Package Manager resolve the pinned **supabase-swift 2.55.4, Auth product**. Do not add a second copy of the SDK. Choose your signing team and unique bundle ID; keep HealthKit enabled. Do not enable Apple sign-in capability for email-only testing.
3. Remove `--fixture-health`, `--empty-health`, `--failed-health` from Run arguments and ensure `FOREST_DISABLE_AUTH` is absent from the Run environment. These test-only switches prevent real login/uploads in synthetic tests. Select the physical iPhone, build and run. Before device testing run `bash frontend/scripts/test-mac.sh` for native unit/UI tests and a Release build; the scheme isolates synthetic tests from live Auth.
4. Open **Settings → Account and sign-in → New here? Create an account**. Enter email, password and matching confirmation. No game profile/starter is created until authentication establishes a session.
5. Open the confirmation email on this iPhone. It should return to Movement Forest. If the confirmation page completes without reopening the app, return to **Account**, choose Sign in and use the confirmed email/password. A failed link can be replaced using **Resend confirmation email**.
6. When asked, enter a unique **Game username** (3–32 ASCII letters/digits/underscores) and display name. Tap **Create account and starter**. Expected: one profile, one garden and one stored starter. The username is separate from your email login. Dismiss Settings with **Done**.
7. In **Garden → Edit → Storage**, place the starter on a valid spot and apply. Select it to inspect server-confirmed progress/attraction. Move, rotate and store/replant it; the owned plant ID and progress must remain unchanged.
8. Open **Activity → Sync steps with my garden**, opt in and grant Health access. First readable current-day steps establish a baseline and award no old history. Walk with the phone, allow Health to update, then **Sync now**. Only planted copies grow; unchanged totals grant no more growth. Activity awards no tokens/tickets.
9. Force-close/reopen: the session restores from Keychain; the same game returns and no new starter is granted. Token renewal is automatic. A rejected refresh asks you to sign in again; saved activity/edit requests retain their exact bytes and UUIDs.
10. From Account choose **Sign out**. The previous private garden disappears from the visible connected UI. Sign in to the same account: the same garden and pending operations recover. Sign in to a different account: it gets its own profile, consent and queue; it must not receive the first account's data.

To test password recovery, enter the email in the signed-out Account screen, choose **Forgot password?**, and open the newest email on the same iPhone. Return to **Settings → Account and sign-in** if needed, set/confirm the new password, then verify a subsequent email/password login. During password recovery game requests are paused. Signed-in social accounts can add password access in **Email and password access → Set or change password**, using their verified account email, without registering another garden.

## 5. Recovery and ownership acceptance

Record actual Mac/Xcode/iOS versions and evidence; do not include bearer tokens, passwords or private Health payloads.

- [ ] Debug native XCTest/UI tests and Release build pass with the pinned SDK.
- [ ] Email signup, confirmation, sign-in, resend and password reset work on the physical iPhone.
- [ ] Only explicit `account_required` enters game provisioning; offline/auth failures do not create another account.
- [ ] Account/starter retries and repeated login preserve one starter and the same garden/plant IDs.
- [ ] Real steps, baseline, duplicate totals, stored plants, stage/transform preservation and recaps follow the existing F5 rules.
- [ ] Losing connectivity during an edit/sync retains its original request; same-account login/retry confirms it without double growth.
- [ ] Offline cold launch may show the previous account's confirmed cache, while writes wait for fresh `/v1/me` identity confirmation. Sign-out hides that private cache. No queued mutation is replayed solely on a cached profile.
- [ ] Sign out/switch while a request is in flight: its late result does not update the next garden or clear the old request. Returning as the original account resolves it.
- [ ] Login/provider changes on this same installation preserve activity enrolment/baseline; actual reinstall/device replacement still requires the existing explicit policy.
- [ ] Invalid/expired/wrong-project tokens and disabled game users cannot access owner operations.

The JWT regression suite uses locally generated asymmetric keys and Supabase-shaped claims. It verifies game identity/ownership and receipts, but does not prove the hosted provider's linking behaviour. Do not mark the next two sections accepted until using actual provider credentials.

## 6. Enable Google later

1. In Google Auth Platform configure branding, consent/audience and test users. Create a **Web application** OAuth client for the implemented system-browser flow.
2. Register the exact Supabase callback `https://YOUR_PROJECT_REF.supabase.co/auth/v1/callback` as an authorised redirect URI. Save the client ID/secret in Supabase's Google provider configuration and enable that provider.
3. Enable **Manual Linking** in Supabase Authentication settings. This is needed for linking a different provider email to an existing account.
4. Set `FOREST_AUTH_GOOGLE_ENABLED = YES` in the Mac's `Local.xcconfig`, rebuild and run. No Google SDK/client secret or separate iOS client ID is needed for this browser implementation.
5. Sign in to the existing email account first, then use **Account → Link Google**. Afterwards sign out and use **Continue with Google**: the garden, starter count, baseline, plants and pending operations must match. Also test a Google identity already belonging to another Supabase user; it must fail linking without merging gardens.

See [Google setup](https://supabase.com/docs/guides/auth/social-login/auth-google) and [manual linking](https://supabase.com/docs/guides/auth/auth-identity-linking). Supabase currently labels manual linking beta; live acceptance is required.

## 7. Enable native Apple later

1. Use an Apple Developer team with Sign in with Apple capability. Register the app's actual bundle ID/App ID and enable that capability in Apple Developer. Keep this ID stable for the test installation.
2. Enable Apple in Supabase and add the native bundle ID to its accepted client IDs. The implemented SDK supports native Apple ID-token linking, so a web Services ID/client secret is not required for this app flow.
3. In `Local.xcconfig` set `FOREST_AUTH_APPLE_ENABLED = YES` and `CODE_SIGN_ENTITLEMENTS = MovementForest/Configuration/MovementForestApple.entitlements`. Choose the matching developer team/provisioning in Xcode, then rebuild. The optional entitlement file includes both HealthKit and Sign in with Apple; email-only builds keep the original HealthKit-only file.
4. Enable manual linking in Supabase. Sign in to the existing garden and choose the Apple button in **Link another sign-in method**. Confirm Apple's native prompt, then sign out and test ordinary native Apple login.
5. Include **Hide My Email** and an email differing from Google/email login. All linked methods must resolve to the same Supabase user and game garden. If you first create a separate Apple account instead of linking, the app does not merge that garden with your email account.

See [Apple setup](https://supabase.com/docs/guides/auth/social-login/auth-apple). Register an [Apple private-relay email sender](https://developer.apple.com/help/account/capabilities/configure-private-email-relay-service/) if sending verification/recovery mail to Apple relay addresses. If a web Apple flow is added later, provision its Services ID/signing key/client secret separately and manage secret expiry then.

## 8. Changed and added code

| Files | Change |
| --- | --- |
| `Services/AuthConfiguration.swift` | Validates build-time URLs/publishable key, feature flags and exact callback destinations. |
| `Services/AuthenticationStore.swift` | Testable session/user model, identity-bound token scopes, login/signup/reset/link actions, recovery gating and immediate local logout isolation. |
| `Services/SupabaseAuthService.swift` | Pinned official SDK adapter, project-scoped Keychain persistence, refresh/events, Google system browser and native Apple login/linking. |
| `Features/AccountScreen.swift` | Email-first account UI, game provisioning, password/email changes, conditional provider/link controls and sign-out. |
| `Services/APIClient.swift` | Async token retrieval and at most one 401 refresh/retry with identical mutation bytes/UUID; checks identity before sending and accepting responses. |
| `Services/GardenConnection.swift` | Connects verified Supabase identities to the existing game API, restores scoped confirmed cache, scopes pending signup requests by issuer/subject, and safely detaches on logout/switch. |
| `Services/GardenEditorStore.swift`, `Services/ActivitySyncCoordinator.swift` | Ignore late detached-account responses while retaining unresolved journals; updated reauthentication messages. |
| `App/MovementForestApp.swift`, `Features/SettingsScreen.swift` | App callback/foreground handling and account access in Debug/Release. |
| `Configuration/Auth.xcconfig`, `Local.xcconfig.example`, `Info.plist`, `MovementForestApple.entitlements` | Explicit client settings, URL routing and optional native Apple capability. The original HealthKit-only entitlement remains the default. |
| `scripts/generate_project.py`, checked-in Xcode project/scheme | Exact SDK dependency, source inclusion/config wiring and isolated test auth environment. |
| `MovementForestTests/AuthenticationTests.swift`, existing API/editor/activity tests | Session/refresh/ownership/recovery/configuration and late-response regressions for native execution. |
| `backend/compose.yaml`, `backend/.env.supabase.example`, `.gitignore` | Docker forwards managed-auth settings; provides a tracked nonsecret template while local `.env`/`Local.xcconfig` remain ignored. |
| `backend/tests/test_supabase_auth.py` | Real verifier/routes/PostgreSQL tests with local EC keys, provider-shaped claims, key changes, preserved activity receipts and ownership rejection. |

Documentation/setup/validation records are updated separately. Game accounting formulas, balance, database schema, ownership keys and asset delivery are unchanged.
