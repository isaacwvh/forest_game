# Supabase email setup

Use the **existing Supabase project** that owns the current player accounts.
These are dashboard/provider steps; this code change does not apply them remotely.
Custom SMTP is available on Supabase Free; the sending provider has its own limits.

## Configure delivery

1. Choose a provider supporting SMTP (for example Resend, Brevo, SES or Postmark).
   Verify its sender/domain using its required DNS records, including SPF/DKIM.
   Obtain its SMTP host, port, username and SMTP password/API credential.
2. In Supabase, open **Authentication → Emails → SMTP Settings**, enable custom
   SMTP and enter those settings plus the verified sender address and sender name
   `Forestivity`. Use the port and credentials supplied by that provider.
3. In **Authentication → Rate Limits**, review the project email sending limit.
   Custom SMTP starts at 30 emails/hour and is adjustable; respect the provider's
   separate quota and keep resend protection. Ordinary password sign-in does not
   send mail. Supabase's built-in sender is unsuitable for public-player delivery.
4. Under the auth provider/settings controls, keep **Email**, **Confirm email**,
   **Anonymous Sign-Ins** and **Manual Linking** enabled. Preserve working Google
   settings and the existing project URLs/keys. Apple remains disabled for now.

SMTP credentials belong only in the Supabase dashboard/provider, never in
Local.xcconfig, the iPhone bundle, a Git commit or player-facing diagnostics.

## Configure verification and recovery

In **Authentication → Emails → Templates**, edit **Change email address**. Email
linking uses this template because it upgrades the current user rather than
creating a second account. Include the verification code and preserve a link:

```html
<h2>Verify your email</h2>
<p>Enter this code in Forestivity:</p>
<p><strong>{{ .Token }}</strong></p>
<p><a href="{{ .ConfirmationURL }}">Verify email</a></p>
```

Keep **Reset password** and any legacy **Confirm signup** templates configured
with their confirmation links. Disable the SMTP provider's link/click tracking
for auth mail so it does not rewrite or pre-consume links. If secure email change
requires both old and new inbox confirmations, complete both supplied links.

In **Authentication → URL Configuration**, retain the callback URLs matching
the installed app's existing callback scheme:

```text
<existing-callback-scheme>://auth/callback
<existing-callback-scheme>://auth/reset-password
```

For the previously verified installation, that scheme was
`com.example.movementforest`; use the actual value in the existing ignored
Local.xcconfig. Do not change the bundle identifier or scheme to enable SMTP.
PKCE recovery links must be opened on the iPhone/installation that requested them.

## Verify with a disposable guest

Rebuild/update the app without deleting it. Follow
[the device test flow](AUTH_ACCOUNT_UI_ACCEPTANCE.md#physical-device-flow),
starting with Link with email → verification → password. Check delivery to an
address outside your Supabase organization team, then test recovery. Inspect
Supabase auth logs and the provider's delivery logs if mail does not arrive.

Official references:
[custom SMTP](https://supabase.com/docs/guides/auth/auth-smtp),
[rate limits](https://supabase.com/docs/guides/auth/rate-limits),
[email templates](https://supabase.com/docs/guides/auth/auth-email-templates),
[anonymous account upgrades](https://supabase.com/docs/guides/auth/auth-anonymous).
