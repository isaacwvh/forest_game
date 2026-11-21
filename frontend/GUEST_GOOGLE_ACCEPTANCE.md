# Guest and Google auth delivery

## Immediate title/guest follow-up — 22 November 2026

The title geometry now ignores safe areas before sizing its artwork, covering
the screen bottom. Anonymous signup returns its confirmed AuthUserInfo directly;
the store applies that result through its normal identity transition rather than
overwriting it from a possibly signed-out cache snapshot. Guest setup failures
use short guest-specific guidance instead of the saved-request sign-in message.
Regression source covers stale signup cache and full-window title bounds.
Portable frontend checks and all 117 Swift syntax parses pass. Native XCTest,
screen bounds and real guest signup still require Mac/iPhone retesting.

Implementation: 22 November 2026, Asia/Singapore. No push/CI or cloud changes.

## Implemented

- Explicit guest entry with a real Supabase anonymous identity; no creation on
  title display, logout, temporary failure or an unresolved restore.
- Atomic `POST /v1/accounts/bootstrap`, using the existing registration lock and
  provisioning transaction. Generated names, exactly one starter, unchanged old
  accounts, bounded collision retry and compact-receipt recovery.
- A separate identity/server-scoped journal preserves bootstrap UUID/body bytes;
  existing manual-registration and gameplay journals retain their formats.
- Approved Concept 02 title artwork with native Play / Continue your garden /
  Sign back in controls, recovery states and confirmed Start a new garden.
- Account & save, optional profile names, Google linking and explicit switching.
  Google/email target authentication uses a separate Keychain and PKCE context.
  The destination profile/garden is verified before Open this garden commits.
- Session adoption keeps rollback credentials until one atomic verified Keychain
  replacement. Retired SDK storage writers are revoked. Demand-driven refreshes
  are coalesced; a forced refresh cannot merely reuse an ordinary lookup.
- Short guest-loss/conflict/logout warnings, cancellation, separate guest-history
  routing hints, durable password-recovery gating, cold callback routing and
  duplicate-success callback suppression.
- Existing account/server-scoped Health consent, daily baselines, reporting-phone
  selection, reward queues and caches remain under their existing owners. Title,
  linking and switching gate active visitors and entry presentations.

Apple and the recurring Health setup / one-time tutorial remain deferred. A guest
save already exists on the game server; linking adds a reusable access method.
Switching removes its active access on this installation, not its server garden.

## Before native testing

1. Run the new backend source before a guest-enabled app. The route is additive;
   no new database migration or player-data reset is required. Keep the existing
   JWKS settings, database and private HTTPS API route.
2. Confirm Anonymous Sign-Ins and Manual Linking in the existing Supabase project.
   The user already reported successful registered-account Google linking.
3. Pull/copy this work to Mac when explicitly ready. In the ignored Local.xcconfig,
   retain working URLs/key and use `FOREST_AUTH_GOOGLE_ENABLED = YES`,
   `FOREST_AUTH_GUEST_ENABLED = YES`, `FOREST_AUTH_APPLE_ENABLED = NO`.
   The callback scheme is com.example.movementforest for the verified installation.
4. Rebuild/update the installed app without deleting it. Remove synthetic auth/
   Health launch arguments from the real-provider test run.

## Main device flow

| Action | Expected result |
| --- | --- |
| Open the existing linked garden; record account/garden IDs and plants | Establish the original save. |
| Settings -> Account & save -> Sign out | Title shows Sign back in; no guest is created. |
| Start a new garden -> confirm | One guest identity, profile, garden and stored starter. |
| Place the starter and let the save confirm | Record this guest's actual save/IDs. |
| Fully close/reopen -> Continue your garden, twice | Same guest, placement and starter; no new identity/grant. |
| Account & save -> Sign in another way | Short guest-access warning; current guest remains active. |
| Continue to sign in -> Google -> original Google identity | Separate target login; original garden preview is shown. |
| Open this garden | Original linked garden replaces the active guest. No merge/delete or inherited consent. |
| Fully close/reopen -> Continue your garden | Same linked garden again. |
| Sign out -> original email/password | Original email access still opens that same garden. |

## Additional native checks

- Cancel switching/browser login: guest and its pending work remain usable.
- Wrong password/expired callback/wrong URL: no stale destination confirmation.
- Temporary network loss or locked Keychain: Retry; no fresh guest on failure.
- Interrupt bootstrap after transmission: resume the saved identity/request and
  confirm one garden/starter. Never replace an uncertain operation UUID.
- Try Link Google with the original account's already-used Google identity:
  clear conflict; optional explicit switching, never garden merging.
- Use a separate disposable guest and unused Google identity for successful guest
  upgrade. Subject, game/garden IDs, owned plants, consent and baseline remain.
- Use disposable accounts for reporting-phone replacement; replacement remains
  explicit and establishes a fresh daily baseline without lifetime catch-up.
- Check small iPhone, largest text, VoiceOver, Reduce Motion, background/provider
  returns, recovery emails, disabled guest flag and partial configuration.

## Validation evidence

The focused PostgreSQL auth suite passed 41 tests before the added anonymous-to-
Google token case. The full suite then passed **795 tests**, with three opt-in
storage benchmarks skipped, and all four real-HTTP walkthroughs passed.
Details are recorded in backend/VALIDATION.md.
Portable frontend asset/project/plist checks, Swift syntax parsing, and backend
lint/format checks passed during implementation.

XCTest cases were added for title history, guest persistence/staging, cancellation,
failed adoption, old-token rejection, lost-guest hints and exact bootstrap replay
bytes. Isolated Debug UI fixtures cover first-use/guest/linked/signed-out/loading/
unavailable states and large-text warnings; they cannot contact real services.

Windows has no Xcode/Apple SDK. Native XCTest/UI runs, Debug/Release builds,
screenshots/VoiceOver/Health and live guest/provider acceptance are **not run**.
Use `bash frontend/scripts/test-mac.sh` on Mac, followed by the device flows above.
The user's earlier Google success proves the previous registered-account flow,
not acceptance of this new integrated build. A7 remains open until that evidence.
