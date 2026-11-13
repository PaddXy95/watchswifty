# Single sign-on (OIDC)

Optional. If you already run an identity provider (Pocket ID, Authentik, Keycloak, Authelia, Zitadel, Kanidm, …),
users sign in through it with a „Mit SSO anmelden“ (sign in with SSO) button on the sign-in page. The provider decides
who may use WatchSwifty (by granting the application to users or groups). There is exactly one provider.

## Setting up the provider

In general: create an OAuth2/OpenID client of type *confidential* with

- redirect URI `https://<watchswifty>/auth/oidc/callback`,
- scopes `openid profile email`,
- ID tokens signed **asymmetrically** (RS256, ES256, EdDSA, …; HS256 is rejected).

Provider notes:

- **Pocket ID:** under **OIDC Clients** add a client (not "public"), enter the callback URL from WatchSwifty and copy
  client ID and secret (the secret is shown only once). The issuer is Pocket ID's `APP_URL` (for example
  `https://id.example.com`). The callback URL must use https (otherwise set `ALLOW_INSECURE_CALLBACK_URLS=true` in
  Pocket ID). If `INTERNAL_APP_URL` is set there, WatchSwifty must reach that internal address (for example in the same
  Docker network). To limit access, assign user groups to the client; Pocket ID shows non-members its own error page.
- **Authentik:** provider "OAuth2/OpenID", choose a **Signing Key** on the provider (without a key Authentik signs with
  HS256), leave the subject mode at the default, create the application and grant access. The issuer is the provider's
  "OpenID Configuration Issuer" address (with `/application/o/<slug>/`).
- **Keycloak:** issuer `https://kc.example.com/realms/<realm>`, client with "Client authentication" on.

## Setting up WatchSwifty

As an admin, under **System → Anmeldung über OIDC (SSO)** (sign-in via OIDC) enter the display name (for example
"Pocket ID"), issuer, client ID, client secret and the **address of WatchSwifty**, then save. The page shows the
callback URL to copy (address + `/auth/oidc/callback`), checks the connection right away and has a
„Verbindung testen“ (test connection) button. Everything is stored encrypted (key `TOKEN_KEY`) and takes effect
immediately, without a restart. The secret is never shown again and must be entered again when the issuer or client ID
changes. No environment variables are needed.

All sign-ins through the provider use the address you entered. Behind a reverse proxy, the proxy must pass on the
**Host header including the port** (or `X-Forwarded-Host`/`X-Forwarded-Port`); otherwise it still works, but
WatchSwifty logs a warning on every SSO sign-in. WatchSwifty must reach the provider at the issuer address (with a
publicly trusted certificate); the app still starts when the provider is unreachable.

**First sign-in:** when someone signs in through the provider for the first time, WatchSwifty asks whether to create a
new account (name prefilled). People who already have an account link it instead (see below). Accounts created through
SSO have no password; their e-mail address comes from the provider.

## Moving an existing installation to SSO

1. Set up OIDC under **System** as above and **keep password login on** (no restart needed).
2. Everyone signs in as usual and clicks „Mit SSO verknüpfen“ (link with SSO) under **Konto** (account). People who
   forgot their password use „Passwort vergessen?“ (forgot password) or a **„Verknüpfungslink“** (linking link) from
   the admin (users page, by mail or to pass on, valid for 7 days). Open invitations can be accepted through SSO directly.
3. Check on the **Benutzer** (users) page: „x von y Konten verknüpft · Admin verknüpft: ja“ (x of y accounts linked,
   admin linked).
4. Under **System**, click „Passwort-Login abschalten“ (turn off password login); this only works once your own account
   is linked. After that only the SSO button remains; „Passwort vergessen“, initial passwords and „Passwort setzen“
   (set password) are gone, and new accounts come from invitations or the first SSO sign-in.
5. Connected apps keep working (tokens last up to 90 days). The next time an app connects, and for a token created by
   hand, it goes through the provider once; a user blocked there gets no new token. An existing web session stays
   signed in as long as it is used (every use extends it by 30 days); to lock someone out at once, delete the account
   under **Benutzer**.

Note: if an admin later sets a password for an account created through SSO, it keeps the address taken from the
provider, and „Passwort vergessen“ would send mail there.

## Emergency access and changing the provider

**Emergency switch:** set `PASSWORD_LOGIN=true` in `.env` and restart. Password login then stays on until the
variable is removed.

If someone cannot get in any more (user recreated at the provider, password login turned off too early), the server
creates a linking link for them (valid for 1 hour; it removes the account's old link to the provider):

```bash
docker exec -it watchswifty /app/docker-entrypoint.sh link-oidc <username>
```

If only the provider's address changes (new domain, renamed slug), this command rewrites all account links. Enter the new
issuer under **System** first; `<new>` must be exactly the issuer of the new discovery document:

```bash
docker exec -it watchswifty /app/docker-entrypoint.sh oidc-move-issuer <old> <new>
```

On a **real change** of provider, the user IDs change: link the accounts again with password login turned on (as when
moving to SSO) or send linking links. A user ID that happens to match at the new provider does not open an old account.

**Back without OIDC:** turn on password login and click „Anmelde-Einstellungen löschen“ (delete sign-in settings)
under **System**. Accounts with a password sign in normally; accounts created through SSO count as invitations again:
use „Einladung erneut senden“ (resend invitation) or „Passwort setzen“ on the users page (or `reset-password`). If you
turn OIDC on again later with the same issuer, the old links apply again.
