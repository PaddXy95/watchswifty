# Accounts

WatchSwifty has several users with separate data. The first admin is created from `ADMIN_USERNAME` and
`ADMIN_PASSWORD` on the very first start (see [Installation](installation.md)). After that the admin creates accounts
under **Benutzer** (users) or, with [mail](email.md) set up, invites people by mail: they choose their password
themselves, the link is valid for 7 days. With [single sign-on](sso.md), accounts can also be created on the first
sign-in through the provider.

Every user enters their own [TMDB token](tmdb.md) and, optionally, their e-mail address under **Konto** (account).
Changing the address requires the current password. Admins only see other users' addresses shortened, for example
`p•••@example.org`.

## Forgot password

If [mail](email.md) is set up and the user has an address under **Konto**, no admin is needed: choose
„Passwort vergessen?“ (forgot password) on the sign-in page, enter the username and open the link from the mail (valid
for one hour). An admin can also reset other users' passwords under **Benutzer**.

Without mail, or when nobody can sign in any more (including the only admin), set the password on the server:

```bash
docker exec -it watchswifty /app/docker-entrypoint.sh reset-password <username>
```

The command asks for the new password twice without echoing it, so it ends up neither in the shell history nor in
`.env`. A changed `ADMIN_PASSWORD` in `.env` does not help here, because it is only used on the first start.

## Sessions and apps

A web session stays signed in as long as it is used; every use extends it by 30 days. Signing in starts a new
session. Apps connect through the browser and get a device token valid for 90 days, see [App API](app-api.md). Under
**Konto → Geräte** (account → devices) users sign out apps or create a token for scripts.
