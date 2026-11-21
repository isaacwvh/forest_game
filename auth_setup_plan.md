# Forestivity auth setup and implementation workfile

Created: 6 November 2026, Asia/Singapore.
Initial source inspection: 6 November 2026. Implementation review: 22 November 2026.
Planning update: 21 November 2026, Asia/Singapore; state-aware title entry and
the companion [sync and onboarding plan](sync_and_onboarding_plan.md).
The targeted source review for that companion plan does not revalidate the
6 November provider/configuration evidence below.
Status: guest + Google source implementation added on 22 November; native acceptance pending.
Current priority: validate the integrated auth build; no push or CI requested yet.
Active milestone: guest entry/restoration, Google linking/recovery, and finished auth UI.
Deferred provider: Apple, until the user decides to enroll in the Apple Developer Program.

Current delivery details and the device test flow are in
[GUEST_GOOGLE_ACCEPTANCE.md](frontend/GUEST_GOOGLE_ACCEPTANCE.md).
The original dated evidence below remains historical. On 22 November the user
reported verifying Supabase/Google configuration, using the
com.example.movementforest callback scheme, enabling Google in Mac Local.xcconfig,
and successfully linking/reopening the same test-account garden with Google.
This is not evidence that the new guest/switch/title build passed on iPhone.

This file is the self-contained handoff for resuming the auth work in another chat.
It records the agreed product behavior, what already exists, the user's completed
setup, unresolved configuration, implementation tasks, operator instructions,
acceptance tests, and release work. The original chat is not required.

Quick navigation:

- [Resume instructions](#0-resume-here)
- [Completed setup and outstanding work](#1-progress-and-setup-ledger-at-handoff)
- [Unresolved bundle/callback configuration](#3-critical-unresolved-configuration-bundle-id-versus-callback-scheme)
- [Approved screens and design](#4-approved-visual-direction-and-page-inventory)
- [State-aware title and entry flow](#51-entry-flow)
- [Companion sync and onboarding plan](sync_and_onboarding_plan.md)
- [Frontend changes](#6-frontend-implementation-map)
- [Backend contract](#7-backend-implementation-contract)
- [Console/Mac/backend setup](#9-operator-worksheet-and-exact-setup-steps)
- [Deferred Apple setup](#10-apple-deliberately-deferred-with-a-later-resume-checklist)
- [Delivery milestones](#11-delivery-sequence-dependencies-and-stopping-points)
- [Manual test flows](#12-acceptance-tests-exact-manual-flows)
- [Automated checks](#13-automated-verification-and-platform-boundaries)
- [Troubleshooting](#14-troubleshooting-guide-for-the-future-chat)
- [Separate release work](#15-release-work-intentionally-separate-from-the-active-milestone)
- [References](#16-reference-documents-and-official-sources)
- [Work log and definition of done](#17-future-work-log-and-final-completion-checklist)

Creating this document did not implement guest onboarding, change auth source,
modify any cloud setting, run native/provider acceptance, or deploy anything.
Do not treat planned behavior or proposed API/types below as already implemented.

## 0. Resume here

### 0.1 Current instruction and scope

The user resumed the full guest + Google milestone on 22 November 2026.
The original resume checklist below describes the pre-implementation handoff;
use the current delivery/acceptance document for implementation evidence and
remaining Mac/provider checks. The separate Health setup/tutorial plan remains
outside this auth implementation.

When the user explicitly returns to implement this plan:

1. Read this file completely, especially the evidence ledger and callback issue,
   plus sync_and_onboarding_plan.md for the post-garden handoff and its separate scope.
2. Read applicable current AGENTS.md and relevant skill instructions.
3. Inspect current code and git status. Gameplay changes may have landed since
   this snapshot. Preserve them and adapt file locations as necessary.
4. Start with milestone A0 below: refresh the implementation map and resolve the
   actual Mac bundle identifier/callback configuration.
5. Prove Google linking on the existing account before treating provider setup
   as validated. Continue independent local implementation while waiting for
   any Mac/operator evidence that cannot be collected from Windows.
6. Implement the bounded guest + Google milestone, including the polished UI.
7. Keep Apple disabled/deferred. Do not make paid membership an impediment to
   guest/Google development.
8. Record exact validation evidence and remaining operator work in this file.

A suitable future resume request is:

> Read auth_setup_plan.md and implement the guest-first + Google auth milestone.
> Keep Apple deferred. Preserve my current email/password account and all game
> data. Use title Concept 02 and polished botanical journal auth/settings pages.
> Start by checking the current source and resolving the callback scheme.

This request would authorize the relevant local implementation and validation;
cloud/account changes, purchases, deployment, or changes to real player data
still depend on the actual instructions in that future session. Do not invent
extra approval checkpoints for ordinary authorized local work.

### 0.2 Evidence labels used in this file

| Label | Meaning |
| --- | --- |
| Source verified | Inspected in the repository on 6 November 2026; recheck after later changes. |
| User reported | The user stated this in the chat; dashboard/build behavior was not independently inspected. |
| Screenshot observed | The supplied Supabase screenshot showed this; it is a dated snapshot, not live state. |
| Agreed | The user chose this behavior or design direction. |
| Proposed implementation | Concrete implementation direction from this planning session; not existing code. |
| Unverified | There is insufficient evidence to mark setup or acceptance complete. |
| Deferred | Deliberately excluded from the immediate milestone; it is not complete. |

### 0.3 First actions on resumption

- [ ] Confirm the user is resuming auth implementation rather than only reviewing the plan.
- [ ] Record the current branch/revision and existing working-tree changes.
- [ ] Re-read current auth, lifecycle, provisioning, activity, and design code.
- [ ] Confirm the existing Supabase project is the one containing the real email account.
- [ ] Confirm actual Mac bundle ID, callback scheme, and registered URL schemes.
- [ ] Confirm Google is enabled and Manual Linking is enabled in Supabase.
- [ ] Confirm Anonymous Sign-Ins toggle; its enabled state was not explicitly reported.
- [ ] Confirm Mac Google flag and exact Google/Supabase redirect values.
- [ ] Keep Apple flag NO and the HealthKit-only signing entitlement for now.
- [ ] Identify an unused Google test identity for guest-upgrade acceptance.
- [ ] Preserve the selected Concept 02 source image before preparing bundled assets.

## 1. Progress and setup ledger at handoff

### 1.1 User decisions already settled

- [x] Guest-first onboarding is the intended experience for new players.
- [x] A guest can keep playing on the same installation without a registration deadline.
- [x] Google/Apple recovery methods are optional additions to the same account.
- [x] Linking belongs under Settings, proposed destination: Account & save.
- [x] Existing email/password accounts must continue working without conversion.
- [x] One active activity-reporting installation per account remains the device policy.
- [x] Phone replacement uses a fresh daily baseline, not lifetime catch-up.
- [x] Title screen must follow saved Concept 02, including the caption.
- [x] New and existing auth surfaces must be polished when delivered.
- [x] Apple is deferred because the user currently uses a free Personal Team.
- [x] Gameplay features take priority before starting the auth implementation.
- [x] A resumable, detailed auth workfile is required; this file supplies it.
- [x] Title actions depend on resolved session/history: Play for first use,
      Continue your garden while signed in, Sign back in after logout.
- [x] Logout, expired credentials and recovery never silently create a fresh guest.
- [x] Start a new garden is a separate explicit choice, with confirmation when
      there is prior-play evidence or a current garden.
- [x] Garden entry precedes recurring Health setup and the separate one-time
      gameplay tutorial; details are in sync_and_onboarding_plan.md.

### 1.2 External setup: completion must not be overstated

| Item | Status at handoff | Evidence and next action |
| --- | --- | --- |
| Existing Supabase email/password account | User reported working; accepted email slice is also recorded in repository docs | Preserve this project/user/garden. |
| Hosted Supabase Auth integration | Source verified | Existing app and FastAPI use Supabase sessions/JWKS. |
| Google OAuth client creation | User reported complete | User downloaded a Google client-secret JSON. Reconfirm it is a Web application client for the implemented browser flow. |
| Google OAuth provider configured in Supabase | User reported complete | User said Google OAuth was configured and connected to Supabase. Credentials/settings were not inspected. |
| Google Cloud project display name | Intended naming discussed | User intended movementforest; do not assume the actual project name/ID without checking. |
| Public app brand | Agreed: Forestivity | Configure Google Auth Platform branding accordingly; internal movementforest naming is acceptable. |
| Google audience, scopes, test users | Unverified | Confirm before live tests. |
| Manual Linking in Supabase | Recommended, not explicitly confirmed enabled | Confirm; do not infer from Google provider being enabled. |
| Anonymous Sign-Ins in Supabase | Recommended, not explicitly confirmed enabled | User asked whether to enable it and was advised yes. No subsequent confirmation of saving that toggle. |
| Google attached to the user's existing account | Unverified | Provider configuration is not account-level linking. Perform Link Google and same-garden sign-in acceptance. |
| Google native iPhone acceptance | Unverified | Callback and feature flags still require confirmation. |
| Guest-first app implementation | Source added 22 November 2026 | Anonymous adapter, separate durable bootstrap journal/route, title entry and staged switching; native acceptance pending. |
| Custom SMTP provider | Unverified/deferred | Do not claim the actual sender is known. Settings live in Supabase. |
| Free/default SMTP usage | Suspected in initial discussion, not proven | Existing password login does not establish email delivery works. |
| Apple membership | User reported Personal Team only | Paid Apple Developer Program enrollment has not been completed in this chat. |
| Apple provider/capability acceptance | Deferred | Preserve source support but leave disabled for this milestone. |
| Cloud Run / hosted game DB / remote game assets | Separate deployment milestone | Auth work can run against current local game backend/database. |

### 1.3 What was inspected locally

- Repository root: C:/Users/Isaac/forest_game.
- iOS app: Swift/SwiftUI, current target/module name MovementForest.
- Game API: Python/FastAPI with SQLAlchemy/PostgreSQL.
- The Xcode project pins supabase-swift 2.55.4, using its Auth product.
- Checked-in app bundle ID: com.example.movementforest for the app configurations.
- Checked-in callback default: FOREST_AUTH_CALLBACK_SCHEME = $(PRODUCT_BUNDLE_IDENTIFIER).
- Checked-in Google flag: NO. Checked-in Apple flag: NO.
- The actual Mac Local.xcconfig is not present in this Windows checkout.
- The backend .env safe fields read as FOREST_ENVIRONMENT=local,
  FOREST_AUTH_MODE=jwks, FOREST_AUTH_ALGORITHM=ES256.
- These are file settings, not proof of the running process's environment.
- Secret values, project credentials, and live tokens were not copied into this document.
- Existing tests were inspected; no new auth tests or real provider tests were run
  while preparing this handoff.
- Many gameplay documentation changes and untracked assets/output already existed.
  Do not discard, reset, or attribute those changes to this auth workfile.

### 1.4 Completion checklist for the future active milestone

The source for A2-A6 was added on 22 November. Checkboxes below remain acceptance
gates, not claims that source work is absent. See the current delivery document
for the distinction between implemented code, automated results and native checks.

- [ ] A0: refreshed source/configuration inventory and callback decision.
- [ ] A1: Google linking and same-garden sign-in proven on existing account.
- [x] A2: additive, repeat-safe backend bootstrap implemented and verified on isolated PostgreSQL, 22 November 2026.
- [ ] A3: anonymous session creation/restore/recovery implemented.
- [ ] A4: title, guest entry, account settings and auth pages finished visually.
- [ ] A5: safe linking/conflict/account-switch behavior implemented.
- [ ] A6: lifecycle, Health consent, reporting phone and durable queue integration verified.
- [ ] A7: automated, native and live acceptance completed with separate evidence.
- [ ] Handoff/setup documentation updated without marking Apple complete.

## 2. Identity model and behaviors to preserve

### 2.1 Separate these concepts

| Concept | Meaning and ownership |
| --- | --- |
| Supabase user | Stable authentication identity within one Supabase project. Anonymous and registered users both have identities. |
| Provider identity | Email/password, Google or Apple attached to that Supabase user. Several methods can open one account. |
| Internal game user | Current users row identified by the verified auth issuer + subject; owns game state. |
| Garden | Server-owned garden associated with the internal game user. |
| Installation | Locally generated UUID representing this app installation, not a permanent physical-phone identity. |
| Session | Credentials allowing this installation to access one Supabase user. Persisted through the SDK's Keychain storage. |
| Health store | HealthKit data available on that device, independently of game login. |
| Reporting installation | The single installation currently authorized to submit new activity for the game account. |

The same email string is not an ownership key. A bundle identifier, phone UUID,
Google Cloud project name, or Apple Team ID is not the player's account ID.
Do not reassign existing game rows using any of those values.

### 2.2 Existing account compatibility

The user's existing email/password account is already a normal Supabase user.
It is not an incompatible legacy account format that needs rebuilding.

Required behavior:

1. Updating the existing installed app restores that session where available.
2. Play resumes the existing garden.
3. If reauthentication is needed, email/password opens the original account.
4. Link Google attaches a provider to that same Supabase user.
5. Subsequent Google sign-in resolves to that same internal user and garden.
6. Original email/password access remains functional unless the user explicitly
   changes those credentials through the existing account settings.
7. Linking never awards another starter or resets any activity state.

Generated development-token identities are a separate historical testing path.
Do not confuse those with the user's working Supabase email account or silently
rebind a development-token garden to a hosted Supabase subject.

### 2.3 Guest behavior

A guest is a real Supabase anonymous user with ordinary server-owned game state.
It is not a public shared account, an unauthenticated API key, or a username made
from the iPhone hardware ID.

- Create it on explicit new-garden intent, normally first-time Play.
- A first-time online connection is needed for anonymous signup and provisioning.
- Restore the same session on later launches; never call anonymous signup on
  every startup.
- Keep guest play available indefinitely under normal operation, without a
  forced link deadline.
- Persist credentials securely and renew short-lived access tokens using the SDK.
- Keep temporary network failures separate from terminal credential/session loss.
- Never interpret an arbitrary 401, timeout, startup nil event, 403, or server
  outage as permission to create another guest.
- Linking supplies a reusable recovery/login method; server saves already exist
  while the account is anonymous.
- A lost unlinked guest credential cannot be guaranteed recoverable. Do not
  promise reinstall, backup restore, or owning the same physical iPhone recovers it.
- A surviving Keychain session may restore after reinstall; that is not a product
  guarantee. Reconcile its new installation ID through the normal device policy.
- Fully offline new-account creation and an independent local-only game are not
  part of this milestone. Preserve current cached viewing and durable retry limits.
- After linking and then logging out, recover the same garden through Sign back
  in / I already have a garden and its linked method. Logout does not unlink,
  delete or reset that garden. A generic Play action must never bypass recovery
  and create a replacement guest; use the state-aware title rules in section 5.1.

### 2.4 Linking versus switching

Linking means adding an unused provider identity to the currently authenticated
Supabase user. The user ID and garden remain unchanged.

Switching means authenticating a different Supabase user and opening that user's
existing garden. The account-specific caches and queues remain separate.

An identity already belonging to another user must not silently merge gardens.
For the initial milestone, handle the conflict with a clear explanation and an
explicit existing-garden switch flow. No automatic garden merge, starter transfer,
wallet transfer, Health-history transfer, or local-journal reassignment.

Cancelling linking or switching must leave the current guest playable.
Before leaving an unlinked guest, explain that it has no reusable recovery method.
Only commit the switch after successful target authentication and deliberate
confirmation. Do not destroy guest access before knowing whether the destination
login succeeds.

## 3. Critical unresolved configuration: bundle ID versus callback scheme

### 3.1 Snapshot from the user's Supabase screenshot

The supplied screenshot showed:

~~~text
Site URL:
com.isaacwvh.movementforest.prototype://auth/callback

Redirect URLs:
com.isaacwvh.movementforest.prototype://auth/callback
com.isaacwvh.movementforest.prototype://auth/reset-password
~~~

The user reported that the installed app has long been bundled as the default
com.example version. The checked-in project currently agrees:
com.example.movementforest.

The screenshot is a historical observation. Inspect the current dashboard before
editing it; do not assume it has remained unchanged.

### 3.2 Why working email login does not settle the mismatch

Existing verified email/password login returns a session directly over the API.
Restoring and refreshing a saved session also do not need a browser callback.
Consequently those operations can work even if app-return URLs are incorrect.

| Operation | Depends on app-return callback in this implementation? |
| --- | --- |
| Existing email/password login | No |
| Session restore / refresh | No |
| Signup confirmation return | Yes |
| Password-reset return | Yes |
| Email-change confirmation return | Yes |
| Google browser sign-in / linking | Yes |
| Native Apple ID-token login / linking | No; actual Apple token audience/bundle configuration is checked separately |
| Proposed anonymous signup | No browser return needed |

A custom URL scheme is independent of the bundle identifier. An app bundled as
com.example.movementforest can intentionally register the older
com.isaacwvh.movementforest.prototype scheme.

This repo defaults the scheme to the bundle ID, but ignored Mac configuration
can override it. Either an intentional override exists or there is a real
callback mismatch. Neither possibility has been proven from this checkout.

### 3.3 Exact read-only Mac verification

In Xcode inspect:

1. App target -> Signing & Capabilities -> Bundle Identifier and Team.
2. App target -> Build Settings -> resolved PRODUCT_BUNDLE_IDENTIFIER.
3. Resolved FOREST_AUTH_CALLBACK_SCHEME for the configuration actually installed.
4. FOREST_AUTH_GOOGLE_ENABLED and selected CODE_SIGN_ENTITLEMENTS.
5. Built app Info.plist -> CFBundleURLTypes / CFBundleURLSchemes.
6. Built app Info.plist -> ForestAuth.CallbackScheme.

From the Mac clone's frontend directory, a focused build-settings query is:

~~~sh
xcodebuild -project MovementForest.xcodeproj -scheme MovementForest -configuration Debug -showBuildSettings | rg 'PRODUCT_BUNDLE_IDENTIFIER =|FOREST_AUTH_CALLBACK_SCHEME =|FOREST_AUTH_GOOGLE_ENABLED =|FOREST_AUTH_APPLE_ENABLED =|CODE_SIGN_ENTITLEMENTS ='
~~~

This intentionally filters out unrelated private configuration. If inspecting a
built .app, extract only the required fields rather than posting its whole plist:

~~~sh
plutil -extract CFBundleIdentifier raw -o - "$AUTH_APP_BUNDLE/Info.plist"
plutil -extract CFBundleURLTypes json -o - "$AUTH_APP_BUNDLE/Info.plist"
plutil -extract ForestAuth.CallbackScheme raw -o - "$AUTH_APP_BUNDLE/Info.plist"
~~~

AUTH_APP_BUNDLE is the actual built .app path on that Mac; obtain it from Xcode.
Do not assume a Windows path or guessed DerivedData directory works on the Mac.

### 3.4 Resolution rules

- The requested app-return URL, iOS registered scheme, handler expectation, and
  Supabase redirect allowlist must agree.
- Keeping the old scheme intentionally is valid if the built app registers it.
- Alternatively align the scheme and Supabase URLs to a selected stable identifier.
- Do not change the app bundle ID just to make email/password login work.
- Changing bundle ID is an installation/signing migration and may lose access to
  local session/cache locations; coordinate it rather than making an incidental edit.
- Changing Apple signing teams can also affect credential accessibility.
- Supabase issuer/subject and game ownership remain unchanged by a callback edit.
- Preserve still-used development callbacks until it is confirmed old builds no
  longer require them. Prefer exact URLs rather than broad wildcard allowlists.
- Record the final values and real Google callback result in the worksheet below.

## 4. Approved visual direction and page inventory

### 4.1 Title reference: settled, do not ask again

The user explicitly selected Concept 02 over Concept 01.

- [Approved title render](assets/auth/approved-concept-02.png)
- [Its generation/edit description](assets/auth/approved-concept-02-prompt.md)
- Exact public wordmark: forestivity.
- Exact caption: Good things grow with you.
- First-use primary action: Play.
- Signed-in primary action: Continue your garden.
- Known signed-out primary action: Sign back in.
- First-use returning-player action: I already have a garden.
- Start a new garden is secondary when another garden is known/current and
  requires confirmation. Section 5.1 defines routing and recovery states.

Preserve the reference's warm parchment, ample open space, green serif wordmark,
sprout, forest-green button, softly faceted oak, bluebells, fern and restrained
woodland composition. Do not invent a new title style or use Concept 01 instead.

The saved render includes baked-in text/button imagery. Production preparation
must account for that: preferred implementation uses approved artwork/wordmark
layers and a real native state-aware primary control matching the reference, without a duplicate
painted button. Preserve the original render. Use safe-area-aware layout and
display-sized assets; do not stretch the source to arbitrary aspect ratios.
Any alternative asset preparation must still yield real accessible controls and
the approved visual composition.

The source images currently live under an untracked output directory. Preserve
them in an appropriate durable project asset location when implementing; do not
assume they will survive an unrelated cleanup or fresh clone automatically.

### 4.2 Reuse the actual existing design system

Read current frontend/DESIGN.md on resumption; it may evolve with gameplay work.
The incumbent botanical journal system is the authority for auth/settings pages:

- Warm parchment background, pale sage surfaces, forest ink and green actions.
- System serif headings with native body/input text.
- Restrained olive vine corners/dividers.
- Generous readable spacing, quiet cards and clear action hierarchy.
- Native navigation, keyboard, password autofill, secure fields and accessibility.
- Existing JournalTheme, JournalPageBackground, JournalVines and
  JournalSectionHeading in Features/BotanicalJournal.swift.
- Existing display-sized asset loading in Services/Assets/PresentationAssets.swift.

Keep Google branding compliant and use the native Apple button when Apple is
enabled later. Platform permission sheets and provider-owned browser pages retain
their native/provider presentation.

Do not leave the new flow as a functional generic Form to be restyled in a later
milestone. Finished auth UI is part of the active guest + Google scope.
This does not authorize redesigning unrelated gameplay screens.

### 4.3 Screens and required states

| Surface | Content / behavior | Required variants |
| --- | --- | --- |
| Title | Concept 02 with state-aware Play / Continue your garden / Sign back in; existing-garden route and explicit secondary new start | Restoring, first use, resumable guest/registered account, explicit logout, credential recovery, offline/retry, unavailable resources |
| Existing-garden sign-in | Continue with Google; email/password; password recovery | Idle, submitting, cancelled, invalid credentials, offline, no garden found |
| Settings landing | Account & save, existing relevant settings destinations | Guest recovery not configured; account recoverable; connection paused |
| Guest account settings | Playing as guest; recovery explanation; Google link; deliberate existing-garden switch | Unlinked, linking, linked, conflict, cancellation, retry |
| Registered account settings | Display name, linked methods, optional additional method, email/password controls, sign-out | Email-only, Google-linked, future Apple-linked, recovery required |
| Optional profile naming | Generated default initially; later username/display-name edit | Validation, unavailable username, save pending, confirmed |
| Email signup and confirmation | Preserve existing secondary email path and recovery capabilities | Confirmation needed, resend cooldown/rate limit, invalid/expired link, success |
| Password/email controls | Forgot password, password replacement, email verification/change | Submitting, verification pending, callback recovery, failure and success |
| Account-switch confirmation | Which garden is being opened, guest recovery warning, confirm/cancel | Target verified, target missing, failed/cancelled authentication |
| Activity/reporting phone | Sync consent, reporter status, explicit replacement explanation | Sync off, this phone, another phone, unavailable Health, pending old upload |
| Session recovery | Clear retry/recover/start-new distinction | Temporary outage, terminal registered logout, unlinked guest credential loss |
| Future deletion | Scope and confirmation once server deletion exists | Deferred release work; no fake action before implementation |

Suggested player-facing copy is a starting point, not a need for another visual
direction round:

- Guest status: Playing as guest.
- Guest explanation: Your garden is saved. Link Google to recover it on another phone.
- Guest recovery status: Recovery not set up.
- Linked status: Recoverable with Google.
- Linking action group: Protect your garden.
- Conflict: This Google account already opens another garden.
- Switch action: Open my existing garden.
- Offline restore: Your garden is still here. Reconnect to finish syncing.

Avoid claiming a guest garden is stored only locally, or saying linking is the
first moment the garden is saved to the server. Avoid promising guaranteed
recovery for an unlinked guest. Technical IDs belong in developer tools, not
ordinary player pages.

### 4.4 Layout, accessibility and visual acceptance

- At least 44-point action targets; no image-only invisible navigation traps.
- Dynamic Type, including accessibility sizes; scroll forms without hiding actions.
- Smallest supported iPhone plus a typical current iPhone; respect notches/safe areas.
- Keyboard avoidance, appropriate content types, email autocapitalization off,
  password autofill and secure fields.
- VoiceOver reading order, useful labels, error focus and non-color-only state.
- Reduce Motion; no mandatory long animation before entering a garden.
- Clear pending versus confirmed state; prevent duplicate submissions.
- Cancellation returns to the correct prior page/account.
- Preserve existing light botanical visual world unless the current design says otherwise.
- Capture every material auth state in UI fixtures/screenshots and review together.
- Make one consolidated visual correction pass, then confirm the corrected screens.
- Portable checks do not establish actual native layout or Apple SDK correctness.

## 5. Planned application flow and state model

### 5.1 Entry flow

~~~mermaid
flowchart TD
    T["Cold launch: Concept 02 title"] --> S{"Resolve session and prior-play evidence"}
    S -->|Still restoring or temporarily unavailable|R["Progress, Retry or recovery; no new guest"]
    S -->|Existing guest or registered session|P["Continue your garden"]
    P --> G["Resume same garden"]
    S -->|Confirmed first use|F["Play"]
    F --> N["Create anonymous user; save session"]
    N --> B["Bootstrap one profile, garden, starter"]
    B --> G
    S -->|Known signed out or credentials lost|L["Sign back in / account recovery"]
    T --> E["I already have a garden"]
    E --> A["Authenticate Google or email"]
    L --> A
    A --> M{"Existing game profile?"}
    M -->|Yes|G
    M -->|No|Q["Explain; explicit choice before new garden"]
    S -->|Resolved state and explicit secondary new-start choice|X["Confirm Start a new garden"]
    X -->|Confirmed; protect prior session until safe handoff|N
    G --> H["Health setup first when incomplete; then one-time tutorial"]
    G --> C["Settings: Account & save"]
    C --> K["Link unused Google identity"]
    K --> G
~~~

No anonymous or game-account creation merely from opening the title.
A cold launch shows the title while restoring state; normal background returns
resume the current garden/page without replaying title onboarding.
The existing app can still retain deliberately isolated sample/fixture paths for
development; a sample garden must never masquerade as a persisted guest save.

State-aware title rules, agreed 21 November 2026:

| Resolved state | Primary action | Result |
| --- | --- | --- |
| Confirmed first use, no established session or prior-play evidence | Play | Explicit new-garden intent creates one guest and bootstraps its garden. I already have a garden opens returning-player sign-in. |
| Restored guest or registered session | Continue your garden | Open that same garden; do not create another identity, garden or starter. Settings supplies provider linking and deliberate account switching. |
| Previously played and explicitly logged out | Sign back in | Open existing-garden sign-in; secondary Start a new garden requires confirmation. |
| Known previous garden but credentials lost/revoked | Sign back in / appropriate recovery | Recover a linked account, or explain an unlinked guest's limitations; never manufacture a replacement save. |
| Restore unresolved or temporarily unavailable | Progress / Retry | Retain expected identity and intent. No first-use decision or automatic anonymous signup. |

The ordinary new-player journey is Play -> guest garden -> optional linking later
under Settings -> Account & save. The title's Google/email controls recover an
existing garden; they are not a link operation for a guest. Apple joins these
same sign-in/linking roles only when its deferred provider work is enabled.
Preserve the existing secondary email signup capability; if returning-player
authentication finds no garden, explain that result and ask for explicit
new-garden intent before provisioning the authenticated identity. Do not silently
replace it with an unrelated anonymous user.

For the specific guest -> link Google -> logout example, the next title shows
Sign back in. Google authentication returns the original garden. Even a stale
Play event must be routed from the resolved state, not directly to anonymous
signup. New-start confirmation explains that a separate garden will be created;
it does not delete, unlink or reset the previous garden. Starting over from an
unlinked guest must include the existing recovery warning and session safeguards.
If starting over while signed in, stage the new session/provisioning without
destroying access to the current garden. Commit the account handoff only when
the new session/save is durably usable; failed/cancelled setup retains the
original session. Apply the existing isolated-auth and callback discipline.

Persist only the non-secret prior-play/logout evidence needed to distinguish
known sign-out from first use. It is a routing hint, not authorization, and must
not expose the signed-out garden or its private cache. Restore valid SDK
credentials before deciding what the title permits. A wiped installation may
have neither credentials nor history; keep I already have a garden available,
because the app cannot discover an unknown previous account automatically.

After successful entry, hand the verified account/installation to
[sync_and_onboarding_plan.md](sync_and_onboarding_plan.md). Incomplete Health
setup is offered on each successful login or cold-launch garden entry; Maybe
later lasts for that entry/session only. The game tutorial is separately
account-scoped. These checks never authorize anonymous signup, bootstrap,
another starter, silent reporter transfer or an auth-provider link.

### 5.2 States the coordinator must distinguish

Suggested names are illustrative; adapt to current Swift conventions:

| State | Meaning | Permitted action |
| --- | --- | --- |
| Restoring | SDK/local state not yet resolved | Show progress; do not create guest |
| FirstUse | No established account/session evidence for this installation | Explicit Play can create guest |
| GuestSession | Anonymous user is established | Resume/provision its own garden; optional linking |
| RegisteredSession | Reusable login method exists | Resume/provision according to explicit intent |
| KnownSignedOut | Prior-play/logout evidence exists, no active session | Sign back in; separate confirmed new-start route, never implicit guest creation |
| ProvisioningPending | Session saved; game bootstrap unresolved | Retry same request; discover existing profile |
| TemporarilyUnavailable | Network/provider/game API unavailable | Retain identity; retry or cached viewing as supported |
| Linking | Provider attachment for a specific current identity | Guard expected identity and callback intent |
| Switching | Authenticate target in isolated context | Keep original account until deliberate successful commit |
| PasswordRecovery | Existing recovery transaction in progress | Suspend normal game mutation until password update completes |
| RecoveryRequired | Definitive lost/revoked/invalid session | Registered sign-in, or explicit explanation for unlinked guest |

Do not infer anonymous status from a missing email, an empty identities list, or
an untrusted metadata field. Expose the SDK's actual anonymous-user status.
If the backend needs that distinction for policy, use verified claims; ownership
remains issuer + subject.

### 5.3 Separate operation intents

Persist or route enough state to distinguish:

- Start a new garden.
- Restore/open an existing garden.
- Link a provider to the current garden.
- Switch to a different existing garden.
- Confirm email / change email.
- Recover a password.

These intents affect both callback routing and whether a missing game profile
may be provisioned. A provider can create a Supabase identity during first login;
the returning-player path must not silently create a second game save on that
basis alone.

## 6. Frontend implementation map

Paths below are repository-relative so the workfile also works in a Mac clone.
Line numbers are deliberately omitted because gameplay work can move code.

| Existing file | Current responsibility | Planned extension |
| --- | --- | --- |
| frontend/MovementForest/Services/SupabaseAuthService.swift | SDK adapter, Keychain storage, PKCE, email, Google browser login/link, native Apple token login/link | Anonymous signup; richer user status; controlled user refresh; safe staged auth contexts/callback dispatch as needed |
| frontend/MovementForest/Services/AuthenticationStore.swift | User/events, identity generations, token scoping, auth actions and logout | Guest/restore/recovery states; new anonymous method; durable intent boundaries; preserve same identity during upgrades |
| frontend/MovementForest/Services/AuthConfiguration.swift | Validates URLs/key/scheme and provider flags | Proposed guest rollout flag; backwards-compatible parsing/defaults |
| frontend/MovementForest/Services/GardenConnection.swift | Resolves /me, attaches account-scoped stores, explicit registration, cached profile restore | Automatic bootstrap for new-garden intent; interrupted provisioning recovery; attach/detach lifecycle gates |
| frontend/MovementForest/Services/AccountDiskStore.swift | Account/server partitioning and durable journals; local installation ID | Separate versioned bootstrap intent/operation; preserve old registration records and existing game journals |
| frontend/MovementForest/Services/APIClient.swift | Scoped bearer requests, one refresh retry, original request preservation | Reuse contracts; handle new bootstrap and switch repositories without leaking credentials |
| frontend/MovementForest/Models/GardenAPIModels.swift | Profile/account/garden request and response types | Bootstrap request model and existing account response reuse |
| frontend/MovementForest/App/MovementForestApp.swift | App/root navigation, URL callbacks, restore, scene lifecycle, settings and entry recaps | Title/entry coordinator integration; auth presentation blocks and correct callback routing |
| frontend/MovementForest/Services/AppResumeCoordinator.swift | Foreground/background/resume coordination | Preserve entry behavior while title/provider screens are visible |
| frontend/MovementForest/Services/AppEntryRecapCoordinator.swift | Saved growth recap entry lifecycle | No duplicate recap or acknowledgment caused by provider browser returns |
| frontend/MovementForest/Services/VisitorCoordinator.swift | Active garden visitor session lifecycle | Ensure title/link/switch transitions cannot keep a falsely active garden session |
| frontend/MovementForest/Services/ActivitySyncCoordinator.swift | Consent, local journal, reporter status, activity operations | Preserve user scope, consent and baseline across upgrade; coordinate source switch safely |
| frontend/MovementForest/Features/AccountScreen.swift | Existing native Form-based auth and provider linking | Finished journal UI, guest/registered branches, recovery and switch routes |
| frontend/MovementForest/Features/SettingsScreen.swift | Account entry, help, data and debug tools | Finished landing and Account & save recovery status; retain non-auth destinations |
| frontend/MovementForest/Features/BotanicalJournal.swift | Shared theme/layout helpers | Reuse and add narrowly reusable auth components where useful |
| frontend/MovementForest/Services/Assets/PresentationAssets.swift | Bounded bundled-image lookup/downsampling | Bundle/load title-derived assets through current resource conventions |
| frontend/MovementForest/Configuration/Auth.xcconfig | Defaults and optional local config include | Proposed guest flag default; keep provider gating |
| frontend/MovementForest/Configuration/Local.xcconfig.example | Safe public local-config template | Document guest flag and Google/Apple enablement correctly |
| frontend/MovementForest/Configuration/Info.plist | URL scheme and compiled auth settings | Add guest flag if used; preserve exact registered callback scheme |
| frontend/scripts/generate_project.py | Generates checked-in Xcode project | Register new source/resources through generator, retain intended signing overrides |

Proposed new responsibilities, with names to adapt rather than blindly create:

- AuthEntryCoordinator.swift: entry state and routing, separate from game stores.
- TitleScreen.swift: approved title and real actions.
- AccountSaveScreen.swift / shared auth views: polished settings and forms.
- AccountSwitchCoordinator.swift: isolated target authentication and safe commit.
- AuthEntryTests.swift / AccountBootstrapTests.swift: meaningful new state tests.

Keep the existing module/target and repository names unless there is a separate
reason to change them. Public branding Forestivity does not require renaming all
MovementForest symbols, Google Cloud resources, or the Supabase project.

### 6.1 Session persistence and restoration tasks

- [ ] Add anonymous sign-in to AuthenticationServing, its real adapter and test fakes.
- [ ] Add anonymous/registered status to AuthUserInfo without invalidating identity scope.
- [ ] Restore SDK state before issuing any new anonymous request.
- [ ] Serialize new guest creation across repeated taps, tasks and scene callbacks.
- [ ] Confirm secure session persistence before game bootstrap.
- [ ] Keep existing project-scoped Keychain storage compatible.
- [ ] Preserve a non-secret marker of an already established account where needed
      to distinguish terminal credential loss from genuinely first use.
- [ ] Persist explicit logout/prior-play routing evidence without retaining
      access to signed-out private state; stale title actions must recheck it.
- [ ] Coordinate refresh so simultaneous API requests do not create refresh-token reuse races.
- [ ] Retain cached identity and journals for temporary failures.
- [ ] Keep terminal recovery explicit; an unlinked guest cannot simply be told
      to re-enter credentials it never had.
- [ ] Keep all access/refresh/provider tokens out of JSON journals and diagnostics.

There is a narrow unavoidable failure window if anonymous signup succeeds
remotely but its response/credentials are never durably received. Do not promise
exactly-once creation of Supabase Auth rows for that window. No game bootstrap
should run until a usable session is saved, so this must not lose an already
played garden or grant duplicate starters within an existing account.

### 6.2 Automatic profile provisioning tasks

- [ ] First call GET /v1/me under the expected identity.
- [ ] Only the specific account_required response plus explicit new-garden intent
      may lead to bootstrap. Network/401/disabled-account failures are not absence.
- [ ] Persist the bootstrap request's ID, timezone, version and exact operation
      before transmission.
- [ ] Scope pending creation by game server plus issuer/subject until the internal
      game user ID is known; reuse the existing identity storage-scope pattern.
- [ ] Retry the original request/body/ID after refresh or uncertain completion.
- [ ] If /me discovers a committed profile after restart, reconcile it to the
      expected identity before clearing pending setup.
- [ ] Do not overwrite or reinterpret saved old manual-registration request bytes.
- [ ] Default profile naming must not block Play; optional naming can use PATCH /v1/me later.
- [ ] Attach editor/collection/visitor/activity stores only to a verified internal user.
- [ ] Failure leaves a finished retry/recovery page rather than a fresh blank garden.

### 6.3 Linking tasks

- [ ] Reuse getLinkIdentityURL for Google attachment, not ordinary signInWithOAuth.
- [ ] Capture expected issuer/subject before starting the browser.
- [ ] Link success must preserve that exact identity.
- [ ] Refresh provider/anonymous status after the SDK reports success.
- [ ] Avoid detaching/recreating game stores simply because methods/email/status changed.
- [ ] Do not replace an established game display name with a provider's name/email.
- [ ] Cancel/failure/conflict leaves original session, garden and pending operations accessible.
- [ ] Reconcile uncertain outcomes by refreshing the current user/identities.
- [ ] Route a cold-start callback to the saved intended operation and correct PKCE context.
- [ ] Reject invalid/mismatched callback scheme, host, path, state and nonce as appropriate.

The current unexpected-identity protection can clear the user/sign out. That
guards cross-account game access, but is insufficient guest recovery by itself.
Before exposing guests, provide a secure way to retain/restore the original
session if a bad or unexpected link result changes identity. Never weaken the
identity guard just to hide that problem.

### 6.4 Account-switch tasks

- [ ] A conflict offers an explicit existing-garden route instead of automatic login.
- [ ] Stage target authentication in a separate auth context so cancelled/failed
      auth does not destroy the guest's current session.
- [ ] Keep staging credentials only in approved secure/ephemeral SDK storage.
- [ ] Route callbacks/PKCE intent to that context; the main auth handler must not
      consume the same callback as a current-account link or password reset.
- [ ] Read the destination profile/garden with its own scoped token.
- [ ] Explain destination and guest recovery implications before committing.
- [ ] Handle missing target garden with an explicit choice, not an implicit new save.
- [ ] Pause active visitors and mutation transmission during account handoff.
- [ ] Stop staging refresh before handing session ownership to the main client;
      avoid two clients rotating the same refresh token.
- [ ] Persist/verify the new main session before discarding temporary staging state.
- [ ] Invalidate prior game token providers and ignore late old-account responses.
- [ ] Reattach stores under the new internal user ID; never rename old journals to it.
- [ ] Retain old registered account journals for their original account's future recovery.
- [ ] Explain that an unlinked guest left behind may not be recoverable.

This is a targeted safe switch, not a generalized multi-account management feature.

## 7. Backend implementation contract

### 7.1 Existing behavior to build on

- GET /v1/me resolves a verified issuer/subject to the internal game user.
- An authenticated identity without a game row receives 403 account_required.
- POST /v1/accounts currently requires requestId, username, displayName,
  gameTimezone and atomically provisions profile/garden/starter.
- PATCH /v1/me already supports username/display-name changes.
- users has a unique auth_issuer/auth_subject ownership constraint.
- Current registration serializes on a PostgreSQL advisory transaction lock
  derived from the verified issuer/subject, including before a user row exists.
- Existing request records support repeat-safe responses and recovery; response
  retention/compact completion behavior must also support the new operation.
- Normal game requests use Supabase access-token/JWKS verification, not Google
  tokens, an API publishable key as a player token, or an admin credential.

### 7.2 Additive bootstrap endpoint

Proposed API:

~~~http
POST /v1/accounts/bootstrap
Authorization: Bearer <SUPABASE_USER_ACCESS_TOKEN>
Content-Type: application/json

{
  "requestId": "a-valid-uuid",
  "gameTimezone": "Asia/Singapore"
}
~~~

Use the client's real intended IANA game timezone, not a hardcoded Singapore
timezone for every player. The example is illustrative.

Response: reuse AccountDTO / APIAccount, consistent with current API casing:

~~~json
{
  "profile": {
    "userId": "<internal-game-user-uuid>",
    "username": "<server-generated-unique-username>",
    "displayName": "New Gardener",
    "gameTimezone": "Asia/Singapore",
    "createdAt": "<timestamp>"
  },
  "gardenId": "<garden-uuid>",
  "starterPlantId": "<starter-plant-uuid>"
}
~~~

The placeholders above are not literal valid UUIDs/timestamps to send. Reuse
the current response schema rather than inventing a second garden ownership DTO.
Use a consistent successful status, preferably current registration's 200
convention for both creation and existing-account resolution.

### 7.3 Transaction requirements

1. Verify the supplied Supabase user token using the configured issuer/audience/key.
2. Build the same canonical identity key and acquire the same transaction lock as
   ordinary registration so both entry routes cannot provision in parallel.
3. Resolve existing user and status. A disabled account remains disabled.
4. Check request replay/hash before performing new work.
5. If the user exists, return their current account identity without renaming,
   changing timezone, replacing the garden, or granting another starter.
6. If absent, generate an allowed unique lowercase username; a value like
   gardener_<random suffix> is suitable. Respect the current 3-32 character limit.
7. Use a neutral default display name such as New Gardener. This is an
   implementation default, not a required player-entered signup step.
8. Create the same account/garden/catalog-discovery/starter facts that current
   registration creates, using one shared internal provisioning helper.
9. Record the operation receipt and return the existing response shape atomically.
10. Roll back all rows/awards if any part fails; handle a generated-name collision
    with a bounded safe retry.

Keep POST /v1/accounts backwards compatible for existing callers and persisted
manual-registration requests. Share creation logic rather than duplicating award
rules. Any new operation name, such as bootstrap_account, needs separate request
hashing/receipt handling so it cannot alias another operation using the same ID.

Authentication alone must still not mutate game state: GET /v1/me remains a read.
Creating an anonymous Auth user is distinct from explicit game bootstrap.

### 7.4 Code and compatibility tasks

| File / area | Required work |
| --- | --- |
| backend/src/forest_api/routes.py | Add authenticated bootstrap route. |
| backend/src/forest_api/schemas.py | Validated bootstrap request with UUID and known timezone; reuse response DTO. |
| backend/src/forest_api/services.py | Shared provisioning helper, same identity lock, generated defaults, receipt/replay handling. |
| backend/src/forest_api/auth.py | Verify anonymous tokens are accepted under existing trust settings; only add verified anonymous status if actually needed by policy. |
| backend/src/forest_api/models.py | Preserve ownership/schema; avoid adding an unnecessary duplicated guest/permanent flag that can go stale after linking. |
| backend/src/forest_api/history.py and history_models.py | Audit completion/replay/retention contracts for the new operation if they participate in recovery. |
| backend/src/forest_api/services.py operation-specific recovery branches | Add bootstrap where appropriate; current register_account is listed in operation handling. |
| backend/tests/test_accounts.py | Existing-account preservation, bootstrap defaults, concurrency, rollback, name collisions and replay. |
| backend/tests/test_supabase_auth.py | Anonymous-shaped claims, same-subject upgrade and provider/ownership invariance. |
| backend/tests/test_auth.py | Existing issuer/audience/algorithm/expiry and disabled-user protections remain effective. |
| backend/tests/test_activity.py and related launch/contract tests | Baseline, account and installation invariants survive auth changes. |

The core bootstrap does not inherently need a new ownership schema or migration
of existing users. If current code now requires a migration, document the concrete
reason and prove preservation rather than treating a reset/reseed as migration.
Release deletion/job state may require separate schema work later.

### 7.5 Bootstrap failure and recovery rules

| Situation | Required outcome |
| --- | --- |
| Invalid/expired token | Existing bounded refresh/reauthentication path; no new user/garden from failure. |
| Account disabled | Existing disabled-account behavior; no replacement account. |
| Bootstrap commits but response is lost | Original operation can be replayed/discovered; exactly one starter for that account. |
| Same request ID, changed body | Existing idempotency conflict behavior; no duplicate grant. |
| New request ID for an already existing user | Resolve original account without changing identity or regranting anything. |
| Concurrent bootstrap and manual registration | Same identity lock produces one internal user/garden/starter. |
| Missing/broken catalogue | Atomic failure; no partially provisioned account. |
| Generated username collision | Retry safely; never expose random collision as a player naming requirement. |
| Cached response expires | Durable completion/existing account still prevents regrant; support current recovery negotiation. |
| Temporary DB/API failure | Preserve pending setup and retry; never assume account absence. |

## 8. Activity, device and gameplay integration

### 8.1 Keep the current phone policy

One game account can be opened from different signed-in installations.
Only its active reporting installation can submit new activity credit.
Logging in on phone B does not automatically revoke phone A as the reporter.
Selecting Use this iPhone for activity performs explicit replacement.

The existing database uses a partial unique active-owner index for reporting
devices. Replacement checks the expected current device and revokes it atomically.
Old new-upload requests are rejected; an already completed operation can still
replay its original receipt without awarding again.

The current frontend can pause certain garden edits while activity is enabled
and another reporter is active, or while a pending request/recovery lock exists.
Preserve and explain those guards; do not promise unrestricted concurrent editing
from every signed-in phone.

### 8.2 Baseline is daily, not lifetime

Preserve the implementation in activity.establish_baseline and the daily credit
watermarks. On the replacement day:

~~~text
baseline_steps = phone B's current-day cumulative Health total at activation
baseline_credit_steps = that day's already-credited account steps

candidate credited steps =
    max(previous credited steps,
        baseline_credit_steps + max(0, observed B steps - baseline_steps))
~~~

The lifetime account counter increases by the newly eligible difference, rather
than being compared with phone B's raw total.

Example:

| Moment | Result |
| --- | --- |
| Account already has 100,000 lifetime eligible steps | Keep all confirmed progress. |
| Activate B when today's Health total is 2,400 | Today's new reporting baseline is 2,400. |
| B later reports 2,900 | Another 500 steps become eligible; lifetime becomes 100,500. |
| Next game day B reports 500 steps | New daily bucket counts its eligible 500; yesterday's 2,400 baseline is not subtracted again. |

Existing reward caps, availability, rounding and other rules still apply.
The player never needs to walk another lifetime 100,000 before B can contribute.
Daily optional metrics have their own baselines; recorded workouts have separate
time/identity eligibility. Do not apply a lifetime-total threshold to either.

### 8.3 Auth changes must preserve gameplay facts

- A successful guest-to-Google link keeps the same internal user.
- No new starter, plant replacement, wallet reset, visitor claim, reward replay,
  discovery reset, milestone reset, baseline reset, or consent change from linking.
- Pending garden/activity/pack/sale/visitor operations keep their original account,
  request ID, body and server scope.
- Refresh retries preserve exact mutation bytes/ID, as the current APIClient does.
- If the account actually changes, old stores are detached and late completions
  cannot mutate the newly opened garden.
- Do not modify balance, growth formulas, activity caps, catalogue offers,
  currencies, storage capacities or species data while implementing auth.
- Preserve fractional cumulative Health total normalization and current wire contracts.

### 8.4 Health consent stays separate

The companion [sync and onboarding plan](sync_and_onboarding_plan.md) owns the
post-entry Health prompt cadence, permission limitations, one-time tutorial and
presentation ordering. This section retains the auth/activity invariants.

- New guest creation does not itself request Health permission or enable uploads.
- Offer activity connection after the player has entered their garden.
- Preserve existing explicit Health read and upload consent semantics.
- A new account on a shared phone must not inherit another account's upload consent.
- Signing into the game with Google does not import Google Fit data.
- Signing into the game with Apple later does not log the backend into Apple Health.
- Health data available on a new phone depends on that phone's Health/iCloud setup,
  which is independent of game identity.
- App-level Health permission is not proof the Health store belongs to the currently
  signed-in human. Single-reporter policy is not a complete anti-cheating system.

### 8.5 Transfer limitations to test and disclose

- Sync the old phone first when possible; unsubmitted old-device activity may
  miss credit after replacement.
- Current Health upload journals are installation-local and excluded from backup;
  they are not automatically migrated by Google login.
- Wait for initial Health/iCloud syncing before setting B's baseline where possible.
- A delayed historical import can raise B's cumulative daily total after activation.
  The current aggregate-based design may interpret that difference as new activity.
  Test this before claiming perfect physical-step deduplication across transfers.
- Downward Health corrections preserve confirmed growth under the existing policy.
- A reinstall may restore a credential but create a different installation UUID;
  use the existing replacement flow rather than resetting the whole account.

### 8.6 Title/auth lifecycle gates

- No active garden visitor lease while a player is only at title/sign-in.
- End/pause the old account's active session before switching accounts.
- Settings/link/provider browser presentations block visitor interaction as expected.
- Returning from the Google browser must not count as a new player signup or a
  duplicate app-entry growth recap.
- Reconcile saved operations under the correct account before showing rewards.
- A recap acknowledgment remains an acknowledgment, not a reward grant.
- Keep fixture/sample health or generated-token paths isolated from live auth.

## 9. Operator worksheet and exact setup steps

These are future setup/verification instructions. No cloud action was performed
when this workfile was written. Console labels may change; use current official
documentation and the actual screen names at execution time.

### 9.1 Public configuration worksheet

Do not put secret values, passwords, access tokens, refresh tokens or downloaded
client-secret JSON content in this file. Record sensitive values in their proper
provider settings/private secret storage. Non-secret identifying values below can
be filled when confirmed, or linked to a private configuration record.

| Value | Current record | Where to verify |
| --- | --- | --- |
| Supabase project reference/URL | Unrecorded here; existing working project | Supabase project settings and Mac local config |
| Google Cloud project display name | Intended movementforest; actual unconfirmed | Google Cloud project picker/settings |
| Google Cloud project ID | Unrecorded; globally unique technical ID | Google Cloud project settings |
| Google OAuth client type/name | Web application advised; actual verify | Google Auth Platform -> Clients |
| Google OAuth client ID | Stored in Supabase; not copied here | Google client and Supabase Google provider |
| Google branding app name | Intended Forestivity | Google Auth Platform -> Branding |
| Google test users/audience | Unconfirmed | Google Auth Platform -> Audience |
| Actual installed bundle identifier | User reported com.example; source com.example.movementforest | Mac resolved build settings and built app |
| Actual callback scheme | Unresolved | Mac build settings and built app plist |
| Supabase Site URL | Screenshot: old com.isaacwvh... callback | Current Authentication URL Configuration |
| Supabase redirect allowlist | Screenshot: old callback + reset URLs | Current Authentication URL Configuration |
| Manual Linking | Unconfirmed | Supabase Authentication settings |
| Anonymous Sign-Ins | Unconfirmed | Supabase Authentication settings |
| SMTP sender/provider | Unconfirmed | Supabase Authentication SMTP |
| Game API origin | Existing private HTTPS route; not copied here | Current Mac config/backend setup |
| Backend JWT mode/algorithm | .env inspected: jwks / ES256 | Actual running service config and active project signing key |
| Apple membership/team | Personal Team reported; provider deferred | Apple account/Xcode only when resumed later |

### 9.2 Keep callback hops distinct

| Hop / purpose | Exact pattern | Configure in |
| --- | --- | --- |
| Google returns to hosted Supabase | https://<PROJECT_REF>.supabase.co/auth/v1/callback | Google Web client -> Authorized redirect URIs |
| Supabase returns to iOS login/link flow | <CALLBACK_SCHEME>://auth/callback | Supabase Redirect URLs and the app's registered/expected scheme |
| Supabase returns to iOS recovery | <CALLBACK_SCHEME>://auth/reset-password | Supabase Redirect URLs and app recovery handler |
| Default return destination | Selected normal app callback for this mobile dev setup | Supabase Site URL |
| Game requests | Existing HTTPS API origin | FOREST_GAME_API_URL only |

Copy the actual provider callback from Supabase's Google panel. Do not substitute
the iPhone URL scheme, localhost game API, Tailscale origin or future Cloud Run
URL into Google's Supabase callback field.

### 9.3 Supabase verification / preparation

1. Select the existing project that holds the current email/password user.
2. In Authentication -> Sign In / Providers (or current equivalent), keep Email enabled.
3. Verify Google is enabled and its saved credentials match the intended Web client.
4. Enable/verify Anonymous Sign-Ins for the planned guest flow.
5. Enable/verify Manual Linking for attaching Google while signed into a guest or
   email account, including a provider with a different email address.
6. Resolve the actual app scheme and set the exact normal/recovery URLs in the allowlist.
7. Confirm Site URL is the intended default return destination.
8. Retain email confirmation and the existing recovery templates unless deliberately
   changing the whole email flow. Standard templates must return through the SDK.
9. Check session lifetime/inactivity/single-session settings against the intended
   persistent game experience. Do not silently impose new guest sign-in deadlines.
10. Keep Apple disabled/deferred.
11. Preserve the asymmetric signing-key/JWKS configuration used by FastAPI.
12. Record observed settings and date; do not mark complete from this checklist alone.

Anonymous access uses a real authenticated user. Before public distribution,
review any Data API/RLS policies that equate authenticated with a registered
account. The intended game path remains owner-scoped FastAPI access. If the hosted
game Data API is unused, follow the existing project policy for disabling it.
Do not expose game tables directly merely to implement guests.

### 9.4 Google console verification (partly user-completed)

The user already reported creating/configuring Google OAuth and saving it in
Supabase. Begin by verifying it, not by creating another client/project.

1. In Google Cloud Console select the intended existing project.
2. Open Google Auth Platform -> Branding.
3. Use Forestivity as the public application name; provide support/developer
   contacts. Internal project/client/service names may remain movementforest.
4. Open Audience; select the appropriate audience, normally External for a public
   consumer app. Add the intended accounts as test users if the app is in testing.
5. Open Data Access; verify only needed basic scopes: openid, email and profile
   (the console may display the userinfo.email/userinfo.profile scope URLs).
6. Open Clients and select the existing Web application OAuth client.
7. Verify its Authorized redirect URIs contains the exact hosted Supabase callback.
8. Verify matching Client ID and Client Secret are saved in Supabase -> Google.
9. Save only corrections actually needed; do not create duplicate provider clients.
10. Enable the app flag and rebuild after app callbacks are aligned.
11. Complete live linking/sign-in acceptance before marking integration complete.
12. Before broader production use, complete any branding/audience publication and
    verification requirements shown by Google's current console.

The downloaded JSON normally has a web object:

| JSON field | Destination |
| --- | --- |
| web.client_id | Supabase Google provider -> Client IDs |
| web.client_secret | Supabase Google provider -> Client Secret |

The whole JSON file is not an iOS resource or a FastAPI config file for this
flow. Keep it outside the repository/app bundle. No Google client secret belongs
in Local.xcconfig. The existing browser implementation does not require adding
the native Google SDK or a separate iOS OAuth client.

Google Cloud project display names are editable; project IDs are persistent
technical identifiers. OAuth branding is separate. The same project can later
host Cloud Run, but auth configuration does not require deploying Cloud Run now.

### 9.5 Mac app configuration and rebuild

Existing private configuration location:

~~~text
frontend/MovementForest/Configuration/Local.xcconfig
~~~

Adjacent safe template:

~~~text
frontend/MovementForest/Configuration/Local.xcconfig.example
~~~

Retain the existing working project URL, publishable API key and HTTPS game API
origin. Auth.xcconfig includes Local.xcconfig in app configurations.
Retain the xcconfig https:/$()/... spelling from the template where used; it
prevents // from becoming a config comment.

For the active milestone, after implementing guest flag support:

~~~xcconfig
FOREST_AUTH_GUEST_ENABLED = YES
FOREST_AUTH_GOOGLE_ENABLED = YES
FOREST_AUTH_APPLE_ENABLED = NO
CODE_SIGN_ENTITLEMENTS = MovementForest/Configuration/MovementForest.entitlements
~~~

FOREST_AUTH_GUEST_ENABLED is a proposed NEW flag, not a currently supported
setting. Add it to configuration parsing, defaults and Info.plist before relying
on it. Prefer gating new guest creation, while still restoring any guest already
created by a prior enabled build.

If retaining an explicit old scheme, configure it deliberately:

~~~xcconfig
FOREST_AUTH_CALLBACK_SCHEME = com.isaacwvh.movementforest.prototype
~~~

That line is an example of the possible resolution, not a decision that this is
the correct current scheme. Otherwise the existing default derives it from the
resolved PRODUCT_BUNDLE_IDENTIFIER.

Use the current working Personal Team for Google/guest development. Preserve
HealthKit entitlements. Do not select the Apple entitlement file while Apple is
deferred. Rebuild after build-time values change.

For real auth tests remove synthetic health/auth-disable launch arguments and
environment overrides for that manual run. Preserve the isolated fixture
configuration for automated UI tests. Do not globally convert test schemes into
live Supabase traffic.

### 9.6 Backend configuration / local deployment

- Keep the current database and existing player data.
- Retain FOREST_AUTH_MODE=jwks and the existing trusted Supabase issuer/audience/JWKS URL.
- Match FOREST_AUTH_ALGORITHM to the project's active supported asymmetric key;
  inspected local .env uses ES256, while source defaults can differ.
- The client sends a Supabase USER access token. Apple/Google raw ID tokens are
  exchanged with Supabase first.
- Normal game verification does not need a Supabase admin secret or Google's client secret.
- Deploy the additive backend endpoint before enabling new guest bootstrap in the app.
- Apply only justified new migrations through the existing controlled workflow.
- Recreate/reload the API service appropriately after environment changes; a plain
  process restart may preserve stale container values.
- Validate /health/ready and a real authenticated profile request.
- Preserve the working private HTTPS/Tailscale route for physical iPhone testing.
- Do not move game tables/assets to hosted Supabase or Cloud Run merely for auth.
- Do not run seed/reset/drop/volume-removal commands against the user's game DB
  as an auth setup shortcut.

### 9.7 Email delivery: separate follow-up

The actual SMTP sender/provider has not been verified. Supabase's default sender
is restricted and unsuitable for broad external email testing; current limits
must be checked at execution time.

For custom delivery:

1. Select an SMTP sending service and configure a sender/domain.
2. Complete the service's domain verification and SPF/DKIM/DMARC instructions.
3. In Supabase Authentication SMTP settings enter sender, host, port, user/password.
4. Test signup confirmation and reset delivery to a non-project-team address.
5. Open the newest email link on the same app installation that requested it
   because the current SDK flow uses PKCE.
6. Verify expired/wrong-device email links have a usable recovery path.
7. When Apple is enabled later, configure the outgoing sender with Apple's private
   relay service if sending email to Hide My Email addresses.

Google sign-in and ordinary verified email/password login do not themselves need
an SMTP message. Custom delivery need not block the first Google linking test,
but must work before external email signup/recovery is relied on.

## 10. Apple: deliberately deferred, with a later resume checklist

### 10.1 Current decision

The user currently signs app builds using a personal Apple ID / Personal Team
and chose to defer Apple sign-in. This overrides the earlier all-provider plan
for the immediate milestone. Leave existing Apple source support available but
disabled. Do not prompt for a membership purchase during guest/Google work.

A paid individual Apple Developer Program membership can use the same personal
Apple Account; it creates a one-person development team. Apple lists US$99/year,
with regional pricing at checkout. Recheck requirements/pricing when resumed.
An individual membership's App Store seller is the legal personal name; the app
can still be branded Forestivity.

### 10.2 Later setup sequence (not required for core completion)

1. User enrolls through developer.apple.com or the Apple Developer app, with
   two-factor authentication and required identity verification.
2. Once membership is active, open Xcode -> Settings -> Apple Accounts (Accounts
   on older versions) and select the same account.
3. In app target -> Signing & Capabilities choose the membership-backed team and
   automatic signing.
4. Settle a stable available bundle ID before Apple capability setup. A value such
   as com.isaacwvh.forestivity was an example, not a user-approved final ID.
5. Coordinate any bundle/team migration with existing sessions/caches and the
   email/Google callback scheme. Server ownership must remain intact.
6. Enable Sign in with Apple on the matching App ID, through Xcode or Apple
   Developer -> Certificates, Identifiers & Profiles -> Identifiers.
7. In Supabase -> Apple enable the provider and add the native bundle ID to
   accepted Client IDs. Do not use the Team ID as the native client ID.
8. Keep Manual Linking enabled.
9. Set FOREST_AUTH_APPLE_ENABLED = YES and
   CODE_SIGN_ENTITLEMENTS = MovementForest/Configuration/MovementForestApple.entitlements.
10. Rebuild and run on a physical iPhone with matching provisioning.
11. Sign into the original garden with an existing method, Link Apple, then test
    Apple sign-in and the same garden. Include Hide My Email and differing emails.
12. Verify the original Google/email methods still work as intended.

### 10.3 Native login versus browser OAuth versus deletion

The implemented native login/linking exchanges Apple's ID token and nonce with
Supabase. This login path does not require adding Apple's browser Services ID
and web OAuth client-secret configuration.

If a future web/browser Apple flow is added, its Services ID, allowed web return
URL, signing key/client secret and rotation requirements are separate work.

Apple token revocation during account deletion is also separate server work:
it requires suitable Apple credentials and a valid Apple user token or a fresh
authorization-code exchange. A Supabase JWT is not an Apple token for revocation.
Do not conclude that native-only login removes all later server credential needs.

## 11. Delivery sequence, dependencies and stopping points

### A0. Refresh source and resolve configuration

Inputs: this workfile, current code, current Mac build settings, existing project.

- [ ] Reconfirm active scope is guest + Google; leave Apple deferred.
- [ ] Record current branch/revision, gameplay changes and existing validation state.
- [ ] Reconcile current files with the implementation map in section 6.
- [ ] Confirm current private API route and backend identity trust settings.
- [ ] Complete callback/bundle worksheet with actual Mac build evidence.
- [ ] Check Google provider, Manual Linking, anonymous toggle and test-user setup.
- [ ] Preserve original email account and selected title artwork.

Exit: an explicit configuration map and known remaining operator dependencies.
Do not restart a broad architecture discovery or ask the user to rechoose guest
onboarding, title Concept 02, or Apple deferral.

### A1. Prove Google on the existing account

- [ ] Enable existing Google adapter in a correctly configured development build.
- [ ] Complete manual test G01 below with the original email account.
- [ ] Verify identical Supabase/game/garden identity through both login methods.
- [ ] Check cancellation and a deliberately conflicting separate identity.
- [ ] Preserve existing email access as a recovery method.

Exit: real linking/sign-in works on the phone; console configuration alone is
not the exit criterion. This can use the existing adapter as a development
provider check; the final delivered auth pages still require the polished UI.
If Mac access is unavailable, label this live gate pending and continue the
independent backend/session/UI work rather than claiming a pass.

### A2. Implement additive backend bootstrap

- [ ] Add route/schema and refactor shared atomic provisioning.
- [ ] Add generated defaults and current request-recovery integration.
- [ ] Verify concurrent/replayed/missing-catalogue/disabled/old-account cases.
- [ ] Verify compatibility with existing manual registration and /me read behavior.
- [ ] Verify receipt retention cannot cause a second starter.
- [ ] Make any necessary API contract fixture/documentation changes.

Exit: bootstrap contracts pass on disposable PostgreSQL and preserve an existing
account snapshot. Deploy backend compatibility before a guest-enabled app is used.

### A3. Implement guest sessions and entry state

- [ ] Add anonymous SDK method, explicit anonymous status and fake-service coverage.
- [ ] Add restore-first coordinator, intent tracking, provisioning journal and recovery.
- [ ] Preserve legacy Keychain naming and existing pending registration bytes.
- [ ] Coordinate refresh and callback delivery across lifecycle events.
- [ ] Add guest creation rollout flag with safe defaults/backwards compatibility.

Exit: creation/restore/network/expiry/relaunch cases pass with no implicit account
replacement. No reliance on a physical hardware identifier for ownership.

### A4. Deliver the complete title and auth/settings UI

- [ ] Prepare durable title assets from Concept 02 without overwriting the source.
- [ ] Implement actual title controls and returning-player navigation.
- [ ] Implement state-aware Play / Continue your garden / Sign back in and a
      separate confirmed Start a new garden route; preserve Concept 02 artwork.
- [ ] Restyle Settings, Account & save, email/recovery and status pages.
- [ ] Add guest/registered recovery indicators and optional Google linking.
- [ ] Support initial automatic naming and optional profile edit.
- [ ] Keep provider branding, native input behavior and accessibility intact.
- [ ] Register files/resources through current project-generation conventions.
- [ ] Add complete test-only UI scenarios for every material state.

Exit: all touched auth surfaces meet the established journal quality bar.
Do not declare this milestone done with placeholder layout or a planned later reskin.

### A5. Implement link conflicts and safe account switching

- [ ] Link retains expected identity and updates status without resetting game stores.
- [ ] Failure/cancellation preserves the current guest and its saved credentials.
- [ ] Isolated target auth cannot consume the main context's PKCE callback.
- [ ] Explicit target verification/confirmation precedes a switch commit.
- [ ] Handoff does not race two refresh-token owners.
- [ ] Old requests/responses stay bound to their original account.
- [ ] Switching to an identity without a game save requires an explicit next choice.

Exit: the conflict/switch tests pass with no implicit garden merges or loss of
the original guest on a failed login.

### A6. Integrate gameplay lifecycle and activity enrollment

- [ ] Preserve first Health read/upload consent and existing steps-only consent.
- [ ] Preserve current active reporting-device comparison/replacement behavior.
- [ ] Preserve baseline and credit watermarks through guest upgrade.
- [ ] Preserve every relevant current account-scoped operation journal.
- [ ] Gate active visitors and app-entry recaps around title/auth presentations.
- [ ] Provide the post-entry handoff/presentation gate described in
      sync_and_onboarding_plan.md. Health setup/tutorial implementation has its
      own S0-S5 checks there; auth completion does not imply those are delivered.
- [ ] Verify actual account switch detaches old stores before opening the next.

Exit: auth transitions cause no unauthorized rewards, duplicate recaps, consent
inheritance, cross-account responses, or baseline resets.

### A7. Acceptance, compatibility rollout and handoff

- [ ] Run the meaningful automated coverage in sections 12-13.
- [ ] Complete Mac Debug/Release native checks and physical iPhone acceptance.
- [ ] Verify original-account Google login plus fresh guest and conflict flows.
- [ ] Review all finished UI states across device/text sizes.
- [ ] Verify feature-disabled and partially configured builds remain usable.
- [ ] Update this workfile, F5a acceptance/setup, validation records and relevant plan status.
- [ ] Leave Apple/live deployment/SMTP items separately labelled as pending or deferred.

Exit: a guest can start, resume, link Google and recover the same garden; the
original email account remains intact; all active-milestone acceptance has evidence.

### Rollout and rollback

1. Start from an additive backend that still accepts the current email app.
2. Validate new source against isolated test data.
3. Run the existing-account phone test before broad guest creation.
4. Enable guest creation for the intended development/test build.
5. Restore created guests even if new guest creation is later disabled.
6. If disabling Google for a provider outage, preserve sessions and account data;
   do not unlink providers or rotate/delete users as a UI rollback.
7. Existing email login remains available for accounts that already have it.
8. Report unresolved outcomes and retained journals rather than pretending a
   reverted UI means remote operations did not happen.

## 12. Acceptance tests: exact manual flows

Do not use the user's real garden for destructive tests. Link the original
account first; use separate identities and disposable saves for conflict,
deletion, loss, or fresh-start scenarios.

### G00. Establish the pre-change evidence

Preparation:

- Confirm the original email/password login works.
- Finish any pending game operations, or record precisely which are pending.
- Record non-secret IDs in developer diagnostics: Supabase issuer/user ID,
  internal user ID, garden ID and representative plant IDs.
- Record starter identity/count, inventory, wallet, credited activity and reporter.
- Record current scheme/bundle/provider flags.
- Capture screenshots where useful without exposing tokens or private secrets.

Expected: a stable comparison point. Time/Health/visitor activity may independently
change balances/progress, so prove identity and inspect receipts rather than
assuming every unrelated live counter remains frozen during the test.

### G01. Link the original email account to Google

1. Run the correctly configured app on the real iPhone.
2. Sign in using the existing email/password if not already signed in.
3. Open the existing garden and confirm it is the intended save.
4. Open Settings -> Account & save (or current Account and sign-in for the
   initial adapter proof) -> Link Google.
5. Choose the intended Google identity and complete consent.
6. Return to the app and wait for linked identity status confirmation.
7. Confirm the same Supabase subject, internal user ID, garden and plant IDs.
8. Confirm no second starter, baseline reset or auth-triggered reward operation.
9. Deliberately sign out of this recoverable account.
10. Choose Sign back in (or I already have a garden where shown) -> Continue with Google.
11. Verify the same account/save loads and existing progress is retained.
12. Sign out and confirm the original email/password still opens that save.

Record actual result and date. Configuring OAuth in Supabase is not this test.
Use different-email Google linking when feasible to exercise explicit linking
rather than relying only on automatic same-email behavior.

### G02. Cancel Google linking

1. Enter the same account's settings and start linking with a suitable test identity.
2. Cancel in the browser/account chooser before completion.
3. Confirm the original account remains signed in and its garden playable.
4. Confirm no guest, new game profile, second starter or queue reassignment.
5. Retry successfully with the intended unused identity where appropriate.

If the main Google identity is already linked, use a disposable suitable test
account for the cancel test; do not unlink the main account merely to repeat it.

### G03. Relaunch an existing registered account

1. Keep the same bundle identifier/installation and install the updated build.
2. Cold launch; see Concept 02 while the saved session restores.
3. Tap Continue your garden; resume the same garden without username signup or guest creation.
4. Background and return; resume the current page without replaying onboarding.
5. Confirm no duplicate visitor session or entry recap from lifecycle callbacks.

### U01. Fresh guest start

1. Use a clean dedicated test installation/device state.
2. Do not delete the user's real app data to obtain this state.
3. Launch: title has Play and I already have a garden.
4. Tap Play once, then exercise repeated taps while it is pending.
5. Confirm exactly one locally established anonymous session and one game
   profile/garden/starter for that identity.
6. Confirm no required email, password, Google login or naming form.
7. Confirm Health permission and upload consent have not been silently granted.
8. Check Settings shows guest/recovery status and optional Google linking.

### U02. Guest persistence and access-token renewal

1. Record the guest's user/game/garden/starter IDs.
2. Force-quit and reopen the app several times.
3. Exercise normal background/foreground transitions and install an app update
   over the same test installation.
4. Allow the access token to expire or use controlled automated clock/service
   coverage for expiry; reopen and make an authenticated request.
5. Confirm refresh/restore yields the same identity and save with no registration prompt.
6. Confirm no policy intentionally forces guest linking after a fixed play period.

Do not revoke the only credential of a valuable guest just to test renewal.
Use disposable users and controlled failures.

### U03. Interrupted anonymous/game provisioning

Test separately:

- Network unavailable before anonymous signup.
- Signup/session established but game API unavailable.
- Bootstrap pending before request transmission.
- Server commits bootstrap but response is lost.
- App is killed during each recoverable setup phase.
- Credential storage/durable journal storage fails.

Expected:

- No game bootstrap before a usable session is safely saved.
- Pending bootstrap retains its original ID/body/account.
- Relaunch finds/resumes the same established account where credentials exist.
- Exactly one starter for that account.
- Helpful retry/recovery state, not a fabricated empty replacement garden.
- Any irrecoverable pre-credential anonymous signup orphan is reported accurately;
  no claim of impossible recovery for unknown remote-only credentials.

### U04. Upgrade guest with an unused Google identity

1. Start a disposable guest and obtain meaningful saved progress.
2. Record account/garden/plant IDs, activity baseline, wallet and consent.
3. In Settings -> Account & save, choose the Google recovery/link action.
4. Use a Google identity not already attached to another Supabase user.
5. Confirm guest status changes to recoverable with Google.
6. Confirm identical Supabase subject, internal account, garden and plants.
7. Confirm baseline, permissions/consent and all saved requests retain identity.
8. Sign out only after the provider link has been verified.
9. Sign in with that Google identity on the same or another test phone.
10. Confirm the same save opens and reporter transfer remains an independent choice.

### U05. Conflict: guest tries the main account's Google identity

1. First finish G01 so the main Google identity already owns the main account.
2. Create a separate disposable guest with a recognizable save.
3. Attempt to link the main Google identity while signed into that guest.
4. Expect a clear existing-account conflict with no merge or transfer.
5. Cancel/return; the guest remains accessible and unchanged.
6. Choose the explicit existing-garden switch route.
7. Authenticate the destination and inspect its identity.
8. Cancel the final switch: guest still playable.
9. Repeat and deliberately confirm leaving the unlinked guest.
10. Confirm only the destination account's state is attached; old queued requests
    cannot be sent using its tokens.

Once Google is attached to the user's main account it is not an unused identity
for U04. This distinction is essential to interpreting provider test results.

### U06. Registered-account switching with pending requests

1. Use two disposable recoverable accounts A and B.
2. Queue an unresolved operation for A, preserving its request ID/body.
3. Switch deliberately to B.
4. Deliver a simulated delayed A response and exercise B requests.
5. Confirm no A state appears in B and no A operation is resent as B.
6. Sign back into A and recover the original operation through its current
   durable completion/replay contract.

Include at least activity and one gameplay mutation journal that is current
when implementing; audit sale/pack/visitor journals rather than assuming they
all share identical mechanics.

### U07. Linked guest logout, state-aware title and deliberate new start

1. Start a disposable guest, record its user/garden/starter IDs, then link an
   unused Google identity and verify that the garden is recoverable.
2. Log out. Confirm the title shows Sign back in, not an unconditional Play.
3. Reopen the app while signed out; the same routing remains. No anonymous
   signup, bootstrap or new starter occurs just from logout, title or relaunch.
4. Choose Sign back in (or I already have a garden where shown), authenticate
   the linked Google identity, and verify the original garden and starter IDs.
5. While signed in, relaunch and choose Continue your garden; verify the same save.
6. Log out again. Choose secondary Start a new garden, then cancel confirmation:
   no account/game creation occurs and returning sign-in remains available.
7. On a disposable test path, confirm Start a new garden. Exactly one new guest
   garden is created; the original linked garden remains recoverable with Google.
8. Exercise repeated taps, a stale Play event, restore delays, offline/401 errors,
   and credential-loss recovery. None silently turns known sign-out into first use.
9. Verify an unlinked guest's new-start/recovery path explains credential loss
   and preserves the existing safe-switch/session rules.
10. On a fresh installation with no surviving history, verify I already have a
    garden is still visible and can recover the linked garden.

Repeat applicable cases with email and, when enabled later, Apple. Physical
Health prompts, recurring entry behaviour and tutorial recovery have separate
acceptance cases in sync_and_onboarding_plan.md.

### D01. Reporting phone transfer without lifetime catch-up

1. Use a recoverable test account already reporting on phone A.
2. Sync A and record account lifetime credited steps L.
3. Sign into the same account on B.
4. Verify the garden follows but the activity reporter does not transfer silently.
5. Let B's initial Health syncing settle; explicitly enable activity sync.
6. Choose Use this iPhone for activity and confirm replacement.
7. Record today's B baseline, for example 2,400.
8. Accumulate/report another measured delta, for example reach 2,900.
9. Confirm 500 newly eligible steps and lifetime L + 500, subject to normal rules.
10. Confirm new uploads from the replaced A are rejected rather than added.
11. Confirm replay of an already completed A operation returns the original
    receipt without awarding again.
12. Verify the next game-day bucket does not subtract yesterday's baseline.

Also test unavailable steps at replacement, delayed Health imports, downward
corrections and reinstallation with a surviving account session.

### E01. Existing email/recovery behavior

- Email/password still works for the original user.
- Signup confirmation/resend pages work in their retained secondary path.
- Password recovery suspends normal game mutation until the password is saved.
- Correct-device PKCE return succeeds.
- Wrong-device, expired, replayed or cancelled links give actionable recovery.
- Provider linking does not quietly overwrite established credentials/profile names.
- Rate-limit, network and unconfirmed-email errors have polished readable states.

### V01. Visual and accessibility acceptance

- Compare title directly with Concept 02, including exact caption and quiet layout.
- Inspect title, sign-in, guest settings, linked settings, confirmations, recovery,
  conflicts and reporting-phone screens as one coherent group.
- Check standard and accessibility text sizes, keyboard, small iPhone and typical
  iPhone; focus on long emails/names and translated-length copy.
- Test VoiceOver action order/labels, return navigation and Reduce Motion.
- Verify actual provider controls are usable and not obscured by decorative art.
- Confirm all buttons/loading/errors correspond to real operations and outcomes.
- Perform one consolidated correction pass and confirm the results.

### Future Apple acceptance (deferred)

When Apple is explicitly resumed, repeat original-account linking/sign-in,
guest upgrade, cancellation and conflict tests using suitable unused Apple
identities. Include Hide My Email. Use a separate test identity/device when the
user's Apple identity is already attached to the main garden. Do not unlink or
delete the main provider just to create a fresh test.

## 13. Automated verification and platform boundaries

### 13.1 Backend tests

Extend existing tests rather than replacing ownership/provisioning invariants.
Required coverage includes:

- Anonymous-shaped and registered-shaped Supabase tokens resolve the same trust
  rules, and a same-subject upgrade retains one account.
- Wrong issuer, audience, algorithm, expiry and different subjects remain isolated.
- /me does not implicitly create game rows.
- New bootstrap validates UUID/timezone and rolls back partial state.
- Concurrent bootstrap/manual registration for one identity yields one starter.
- New IDs and changed-body replay cannot multiply grants.
- Existing account naming/timezone/garden/history are not overwritten by bootstrap.
- Response-cache cleanup/current compact recovery still prevents reprovisioning.
- Disabled users cannot escape their status by retrying onboarding.
- Existing activity-device, baseline and idempotency tests continue passing.

The current fixture requires FOREST_TEST_DATABASE_URL, a PostgreSQL admin
connection used to create/drop random forest_test_* databases. Use the dedicated
validation cluster, not the user's personal game database. Inspect current test
setup before running it. Do not embed its credentials in this document.

From backend with its supported Python environment activated, the initial focused
run can be:

~~~sh
python -m pytest tests/test_auth.py tests/test_supabase_auth.py tests/test_accounts.py tests/test_activity.py tests/test_activity_frontend_contract.py
python -m ruff check src tests
python -m ruff format --check src tests
~~~

Include new bootstrap tests if created separately. After implementation is stable,
run the applicable full backend suite once. Re-run broader checks only when new
changes/failures justify them. Follow current repository instructions if commands
or dependency versions have changed.

### 13.2 Swift/unit/integration coverage

Extend AuthenticationTests, AppLifecycleTests, ActivitySyncTests, APIClientTests
and new entry/bootstrap/switch test files as appropriate.

Required scenarios:

- Initial SDK event timing cannot cause guest creation before restore resolves.
- Repeated Play/foreground tasks perform one guest creation operation.
- Cached guest/registered session retains the original scope on temporary failures.
- Bootstrap unknown outcome survives relaunch with exact request identity.
- An existing user's update path never becomes a guest.
- Explicit logout survives relaunch as known sign-out, with Sign back in and
  confirmed new-start routing; stale Play events cannot create an implicit guest.
- Cancelling Start a new garden performs no signup/provisioning and keeps recovery available.
- Guest-to-Google changes status/methods without changing account generation.
- Expected-link identity mismatch remains fail-closed and original guest access
  is recoverable through the protected old-session path.
- Linking cancellation/conflict does not sign out the guest.
- Staged callbacks do not get processed by the wrong auth context.
- Cancelled/failed account switch preserves the current session.
- Refresh-token handoff is serialized; expired tokens do not produce retry loops.
- Old-account in-flight work cannot send/apply under the new account.
- Recovery callbacks keep the existing password-recovery mutation gate.
- Title/auth presentations do not produce active visitors or duplicate entry recaps.
- Activity/upload consent remains account-scoped and survives same-account linking.

### 13.3 Portable frontend checks

From the repository root:

~~~sh
python -X utf8 frontend/scripts/validate_frontend.py
python -X utf8 frontend/scripts/check_swift_syntax.py
python -X utf8 frontend/scripts/generate_project.py --check
~~~

Inspect current script options before running against a Mac clone with local
signing overrides; the native test script currently uses
validate_frontend.py --allow-local-project-settings.
If generation changes are needed during implementation, use the generator
deliberately and preserve the user's legitimate local signing configuration.

### 13.4 Mac checks

From the Mac repository root:

~~~sh
bash frontend/scripts/test-mac.sh
~~~

At handoff that script runs simulator XCTest and Release/InternalRelease builds.
Inspect its current content before execution. A simulator build without signing
does not prove real Google/browser callback, Health access or physical-device
provisioning. Complete the live phone flows separately.

Windows Swift syntax parsing does not type-check Apple SDK APIs or prove native
layout. Existing repository validation counts are historical evidence and must
not be copied into the new auth acceptance record as if just executed.

### 13.5 Evidence to save

For each gate record:

- Date/timezone, branch/revision and build configuration.
- Which test command and isolated data environment were used.
- Actual pass/fail/skip result, not a planned expected result.
- Phone/iOS/Xcode versions for native/live checks.
- Non-secret account/garden identity comparison results.
- Screenshots/fixtures for the finished UI states.
- Any unrun checks and precise reason.
- Remaining operator settings or source gaps.

Keep credentials, tokens, recovery links with codes, raw private Health uploads
and downloaded OAuth JSON out of logs, committed evidence and ordinary screenshots.
Developer diagnostics should show only the bounded non-secret IDs/status needed
to prove ownership and operation outcomes.

## 14. Troubleshooting guide for the future chat

| Symptom | Check first | Correct interpretation |
| --- | --- | --- |
| Email login works but Google does not return | Built callback scheme vs Supabase allowlist and provider callback | Password login did not validate redirect configuration. |
| Google redirect_uri_mismatch | Google Web client's Authorized redirect URIs | It must include the hosted Supabase callback, not the game API or iPhone scheme. |
| OAuth works in browser but app does not finish | Registered iOS scheme, handler host/path, PKCE/intent, same installation | Do not create another game profile to work around callback failure. |
| Google login blocked for a tester | Google Audience/testing users and required consent/scopes | Provider configuration may be present but not accessible to that Google account. |
| manual_linking_disabled | Supabase Manual Linking setting | Google enabled is not equivalent to manual linking enabled. |
| identity_already_exists / existing-account conflict | Whether the Google identity already belongs to another Supabase user | Offer deliberate account switching; do not merge gardens. |
| Fresh Google sign-in opens a blank account | Current subject vs original email user and intended link path | Signing in separately may have created a different Auth identity; verify before touching ownership. |
| Guest changes each launch | Restore timing, Keychain storage/bundle/team, unconditional signup calls | Preserve credentials and fix entry state; do not copy game rows to each new subject. |
| Guest disappears during a temporary outage | Error classification and SDK event handling | Network failure must not be treated as confirmed new-install absence. |
| Guest cannot recover after credentials truly lost | Whether a reusable provider was ever attached | Explain limitation; do not promise recovery solely from a physical phone ID. |
| Game reports account_required after auth | /me result and pending provisioning intent | Auth user and game profile are separate; bootstrap only under correct intent. |
| Auth succeeds but game access fails after cloud setting change | Running issuer/audience/key algorithm and backend process environment | Provider login is not proof FastAPI trusts the correct token/project. |
| Old phone still shows a completed operation after replacement | Same request replay versus a new upload | Original completed receipt is valid history, not a new activity grant. |
| New phone appears blocked by lifetime total | Inspect daily baseline and display terminology | No lifetime catch-up threshold is intended or implemented. |
| Apple capability unavailable with Personal Team | Paid membership status | Apple remains deferred; guest/Google work can continue. |
| Google option missing in app | Compiled FOREST_AUTH_GOOGLE_ENABLED and current configuration | Saving Supabase credentials does not alter a previously built app. |
| New title or UI files absent in build | Project generator and resource registration | A file in the workspace is not necessarily included in the Xcode target. |

## 15. Release work intentionally separate from the active milestone

These are explicit future gates, not reasons to block local guest/Google work.

| Work | Timing / requirement |
| --- | --- |
| Apple membership/capability/provider | When user explicitly resumes Apple; before distribution that requires the equivalent login option. |
| Production Google branding/publication | Before broad production Google sign-in; follow current console requirements. |
| Custom SMTP | Before external email signup/recovery is a supported route. |
| Coordinated account deletion | Before relevant App Store/public release acceptance; guest accounts require deletion support too. |
| Signup abuse controls | Before exposing anonymous signup broadly; verify native challenge integration and rate limits. |
| Guest retention/cleanup | Define deliberate policy; do not delete actively played guests merely because created_at is old. |
| Cloud Run deployment | Existing deployment milestone; preserve auth project/user identities through API hosting changes. |
| Hosted game DB and remote assets | Separate controlled migration/publishing; do not mix with auth bootstrap changes. |
| Backups, restore, privacy and operational monitoring | Release readiness with explicit verification. |
| General provider unlinking or garden merging | Separate scope/design; not implicitly included in guest linking. |

### 15.1 Account deletion requirements to carry forward

- Sign-out is not account deletion.
- Delete/disable game access and coordinate removal of profile/private activity/
  owned game data with Supabase Auth deletion through trusted server tooling.
- Support anonymous account deletion as well as registered accounts.
- Make cross-service deletion recoverable/repeat-safe; server job state may
  require a separate migration.
- Revoke Apple authorization when Apple is used, using appropriate server-side
  signing/token material or the current supported recovery procedure.
- Keep admin credentials and Apple signing keys out of the app.
- Explain actual deletion scope/timing and backup retention consistently.
- Do not add a decorative Delete account button before its server action works.
- Use disposable test users for deletion acceptance.

Apple's equivalent privacy-preserving login requirement must be rechecked before
shipping an iOS app with Google login. Local development of Google first does not
remove that later distribution requirement.

### 15.2 Retaining guests responsibly

The user's chosen behavior is continued guest play on the same installation.
Do not introduce a 7-day/30-day mandatory upgrade or a created-at-only deletion job.
Any future inactive-account policy must distinguish active/valuable guests and
be an explicit product/retention decision. Normal credential/session loss can
still occur; optional provider recovery remains the protection against it.

## 16. Reference documents and official sources

### 16.1 Repository reading order

1. This file: latest agreed guest/Google direction and Apple deferral.
2. [SUPABASE_SETUP.md](SUPABASE_SETUP.md): existing provider/backend setup guide.
3. [F5a auth acceptance](frontend/F5A_AUTH_ACCEPTANCE.md): source integration,
   original email acceptance and provider live-test requirements.
4. [Frontend design](frontend/DESIGN.md): current visual authority.
5. [Implementation plan](IMPLEMENTATION_PLAN.md): broader gameplay/release roadmap;
   older auth milestones may not yet describe the guest decision in this file.
6. [Game specification](forest_game_v1_spec.md): ownership/activity/retention product rules.
7. [Backend activity contract](backend/ACTIVITY_API.md): existing baseline/device/retry rules.
8. [Frontend validation](frontend/VALIDATION.md) and
   [backend validation](backend/VALIDATION.md): distinguish executed checks from pending native acceptance.
9. [Data retention plan](DATA_RETENTION_PLAN.md): completion history and deletion boundaries.
10. The current source files mapped in sections 6-8.
11. [Sync and onboarding plan](sync_and_onboarding_plan.md): post-entry Health
    setup, recurring reminders, separate tutorial and single-starter presentation.

Do not overwrite accepted gameplay work just because an older roadmap table has
not caught up with newer source. Reconcile sources and actual evidence first.
Update relevant handoff/status documents when implementation actually lands;
The original 6 November handoff edited only auth_setup_plan.md. The 21 November
planning update edits this workfile and adds sync_and_onboarding_plan.md; it
does not implement auth, Health setup, tutorial UI or any runtime changes.

### 16.2 Official documentation bookmarks

These sources were consulted during the 5-6 November 2026 conversation. Provider
labels, requirements, limits and pricing are time-sensitive; recheck the relevant
current official page before executing external setup later.

- [Supabase anonymous users](https://supabase.com/docs/guides/auth/auth-anonymous)
- [Supabase Swift anonymous sign-in](https://supabase.com/docs/reference/swift/auth-signinanonymously)
- [Supabase sessions](https://supabase.com/docs/guides/auth/sessions)
- [Supabase identity linking](https://supabase.com/docs/guides/auth/auth-identity-linking)
- [Supabase Swift identity linking](https://supabase.com/docs/reference/swift/auth-linkidentity)
- [Supabase Google provider](https://supabase.com/docs/guides/auth/social-sign-in/auth-google)
- [Supabase Apple provider](https://supabase.com/docs/guides/auth/social-sign-in/auth-apple)
- [Supabase redirect URLs](https://supabase.com/docs/guides/auth/redirect-urls)
- [Supabase mobile deep linking](https://supabase.com/docs/guides/auth/native-mobile-deep-linking)
- [Supabase SMTP delivery](https://supabase.com/docs/guides/auth/auth-smtp)
- [Google Cloud project identity/naming](https://docs.cloud.google.com/resource-manager/docs/creating-managing-projects)
- [Google OAuth app branding](https://support.google.com/cloud/answer/15549049?hl=en)
- [Google sign-in button branding](https://developers.google.com/identity/branding-guidelines)
- [Apple developer account and Personal Team overview](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [Apple Developer Program enrollment](https://developer.apple.com/programs/enroll/)
- [Apple Developer Program membership/pricing](https://developer.apple.com/programs/)
- [Apple supported iOS capabilities](https://developer.apple.com/help/account/reference/supported-capabilities-ios/)
- [Xcode signing and physical devices](https://developer.apple.com/documentation/Xcode/running-your-app-on-simulated-or-physical-devices)
- [Xcode Sign in with Apple capability](https://developer.apple.com/documentation/xcode/configuring-sign-in-with-apple)
- [Apple private email relay configuration](https://developer.apple.com/help/account/capabilities/configure-private-email-relay-service/)
- [Apple account deletion requirements](https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion)
- [Apple token revocation](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens)
- [Apple App Review login requirements](https://developer.apple.com/app-store/review/guidelines/#login-services)

Use primary documentation and the pinned/current Swift SDK source for API details.
Do not replace an established working adapter with a web tutorial's incompatible
flow without a concrete reason.

## 17. Future work log and final completion checklist

### 17.1 Work log

Append observations and results; retain earlier evidence with its date rather
than rewriting an untested assertion into a completed item.

| Date | Milestone / action | Evidence | Remaining work |
| --- | --- | --- | --- |
| 2026-11-06 | Planning handoff created; current code/config inspected | This file; source map; user-reported Google configuration; dated callback screenshot values | All new guest/UI/bootstrap work and live Google acceptance remain outstanding; Apple deferred. |
| 2026-11-21 | Agreed state-aware title/logout routing and companion sync/tutorial plan | Updated sections 4-5, tasks and U07; sync_and_onboarding_plan.md; targeted local source review | Documentation only. Guest/title/bootstrap changes, Health setup/tutorial implementation and native/live acceptance remain outstanding. |
| 2026-11-22 | User resumed full guest + Google implementation; earlier Google link/re-login passed on their test account | Added bootstrap/shared provisioning, anonymous/session/history state, isolated Keychain/PKCE switching and rollback guards, Concept 02 native title, Account & save, concise warnings, profile edit and native test/fixture source. Backend 795 passed / 3 opt-in benchmarks skipped; four HTTP smoke checks, frontend portable checks, 117-file syntax parse and backend lint/format passed. | No push, CI, deployment or cloud changes. Mac builds/XCTest, native layout/accessibility and integrated live guest/provider/Health acceptance remain pending. Separate Health onboarding/tutorial and Apple remain deferred. |
| To fill | A0 refreshed inventory | Revision, configuration worksheet and observed settings | To fill |
| To fill | A1 original-account Google acceptance | Phone/build and same-user/garden results | To fill |
| To fill | A2 backend bootstrap | Isolated PostgreSQL test results | To fill |
| To fill | A3-A6 app/UI/lifecycle integration | Native and automated evidence | To fill |
| To fill | A7 final active-milestone acceptance | Completed cases and screenshots | Explicit release/Apple follow-ups |

### 17.2 Core guest + Google definition of done

- [ ] Existing email account, garden and owned progress preserved.
- [ ] Actual bundle/callback configuration verified and documented.
- [ ] Google linked to the existing account and re-login proven on real iPhone.
- [ ] Fresh Play creates one usable guest game account without required registration.
- [ ] Restored sessions use Continue your garden; explicit logout uses Sign back
      in; a new guest after prior play requires confirmed Start a new garden.
- [ ] Guest survives normal relaunch, update and access-token renewal.
- [ ] Temporary failures do not manufacture another account.
- [ ] Bootstrap interruption/replay/concurrency cannot regrant a starter.
- [ ] Guest Google upgrade retains all ownership, progress, consent and baselines.
- [ ] Conflicts/cancellation preserve the current guest; switching is explicit.
- [ ] Old-account queued/in-flight work cannot cross account boundaries.
- [ ] Reporting phone and daily-baseline behavior remain correct.
- [ ] Health opt-in remains separate from auth.
- [ ] Concept 02 title and all touched auth/settings pages are finished and accessible.
- [ ] Provider flags and disabled/partial configurations behave safely.
- [ ] Backend/portable/native/live checks have separate real evidence.
- [ ] Current setup/acceptance docs and this work log reflect actual delivery.
- [ ] Apple remains explicitly deferred unless the user later resumed it.

### 17.3 What the next chat should report back

Lead with implemented player behavior, what was verified, and what remains.
Give the user the exact next operator action if a dashboard/Mac check is pending.
Do not claim live provider success from source tests, console configuration,
syntax parsing, or mocked tokens. Do not call the whole auth program complete
while outstanding release requirements are merely deferred.
