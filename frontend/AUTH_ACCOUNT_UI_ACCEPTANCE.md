# Account access and loading screens

22 November 2026. Native implementation of the revised auth concepts, with the
user's final minimal copy and **Link with email** wording. The user requested a
follow-up push for Mac validation without waiting for CI, and reported completing
Resend/Supabase setup. No account deletion or backend migration is required.

Follow-up: the user confirmed the full email linking flow works on device.
Routine auth notices are removed and form feedback clears on exit. In password
recovery, retry with the current password: expect “Choose a different password
from your current password.” once, then verify a different password succeeds.

## Behavior

- Account & save uses Profile's journal, portrait, headings and sage status band.
  Guests see “Link account to save progress”, Link with Google and Link with email.
  Confirmed Google and email/password methods have explicit state and icons.
- Email linking updates the active Supabase user. Verification precedes password
  setup; non-secret pending intent survives a cold launch under that exact auth
  identity. Passwords and codes remain transient. A Google-confirmed email can
  proceed directly to password setup. No signup endpoint is used by this flow.
- Email & password settings appear only after a successful password login/setup
  establishes the capability. A Google email or email identity alone is insufficient.
  New password setup writes a presentation-only metadata flag with the password;
  successful legacy password login also remembers the capability on this device.
  This flag never authorizes API/game access. On an older account without the
  flag, Link with email can finish setup or a password login can establish it.
- Returning-player sign-in has Google and an envelope-labelled email option.
  It stages a destination and retains explicit Open this garden confirmation.
  Password recovery while switching uses that same isolated context. The active
  guest is retained until a verified, explicit account handoff.
- A restored account's title has only Continue your garden. The native loading
  indicator is delayed 250 ms; successful entry is never delayed. Failed
  connectivity retains the session and makes Continue the retry.
- Unresolved restoration never offers a fresh guest. Confirmed signed-out entry
  has Play and existing-garden sign-in; previous-play history still requires
  confirmation before creating a new garden.

## Physical-device flow

Keep the existing installation and cloud project. Configure SMTP and email
templates using [the setup guide](AUTH_EMAIL_SETUP.md), then rebuild on Mac.
Do not use fixture launch arguments for real provider tests.

1. Play into a disposable guest. Place the starter and wait for its saved result.
   Record the existing garden/account IDs through developer diagnostics.
2. Account & save: verify both link options, no email/password settings, and the
   short guest copy. Force-close/reopen, then restart/unlock the iPhone and reopen.
   Confirm the same guest and starter return automatically.
3. Launch without connectivity. Confirm Continue is the only account action;
   restore connectivity and tap it. No signup, extra starter or sign-out occurs.
   Also interrupt connectivity after the account lookup but before the garden
   loads; Continue must retry the incomplete garden load rather than get stuck.
4. Link with email using an unused address. Leave/reopen the page and app while
   verification is pending. The guest, placement and pending address must survive.
   Try an incorrect/expired code, resend, then verify a valid code or email link.
   Set a password. Confirm the same account/garden IDs and owned plants.
5. Confirm Email & password settings now appears. Sign out, sign in with email,
   verify the destination, and Open this garden. Confirm the same progress.
6. Link Google using that same Gmail address when available. Both methods must
   remain usable and identify the same garden. Separately test a Google-only
   account: no password settings until Link with email is completed.
7. While in a disposable unlinked guest, open another garden, request a password
   reset for a separate existing email account, return from the email, and save
   its new password. The guest must remain active until Open this garden.
   Cancel switching and confirm the original guest remains accessible.
8. Test an email/Google identity already belonging to another garden. Confirm a
   clear conflict, no merging or automatic switching, and a usable cancel path.
9. Test password recovery, email changes, callback expiry, backgrounding, rapid
   taps, oldest supported/smallest iPhone, largest Dynamic Type, VoiceOver,
   keyboard/autofill and Reduce Motion. Text and buttons must wrap and scroll.

## Local/native checks

The shared core checks can also run with a complete Linux Swift toolchain:

```sh
python frontend/scripts/prepare_auth_validation.py
swift -swift-version 5 frontend/.validation-tools/auth/AuthChecks.swift
```

Portable source/asset validation and syntax checking do not establish an Apple
SDK build, native rendering or provider behavior. Run on a Mac:

```sh
bash frontend/scripts/test-mac.sh
```

Native checks include shared identity/persistence tests in AuthLinkChecks and UI
coverage for title states, guest warning, Google-only/email-only accounts, email
setup and settings visibility. Debug previews are isolated from real services:

```text
--fixture-auth --auth-guest --auth-account
--fixture-auth --auth-google-only --auth-account
--fixture-auth --auth-email-only --auth-account
--fixture-auth --auth-linked --auth-account
--fixture-auth --auth-restoring
--fixture-auth --auth-unavailable
--fixture-auth --auth-signed-out
```

The isolated fixture email verification code is `123456`; it is never used by
the real Supabase adapter.
