# Mail

Optional. With mail set up, the admin invites people by mail (they choose their password themselves, the link is
valid for 7 days), everyone can reset their password with „Passwort vergessen?“ (forgot password), and users with an
address get a mail when an app connects to their account. Without mail everything else works as before.

## Setting up

As an admin, under **System → E-Mail** enter the SMTP server's details, save and click „Testmail senden“ (send test
mail). Everything is stored encrypted (key `TOKEN_KEY`, like the TMDB tokens); the password is never shown again. When
server, port, encryption or user change, the password must be entered again. No environment variables are needed.

The **address of WatchSwifty** is the address browsers use to reach the app (behind a reverse proxy its https
address, for example `https://watch.example.lan`). Links in mails are built only from it.

Every user enters their own address under **Konto** (account), see [Accounts](accounts.md).

## With SwiftyRelay

[SwiftyRelay](https://github.com/PaddXy95/SwiftyRelay) is a small mail gateway for self-hosted apps. In
`docker-compose.yml`, enable the commented lines for `swifty-relay` (network and volume `swifty-relay-certs`;
SwiftyRelay must have run once before), then use:

| Field | Value |
|---|---|
| Server | `swifty-relay` |
| Port | `2525` |
| Encryption | STARTTLS |
| User | `watchswifty` (app name in the relay) |
| Password | `SMTP_IN_PASSWORD` of the relay |
| CA file | `/certs/swifty-relay/ca/ca-bundle.pem` |

SwiftyRelay replaces the sender with its own address, so the sender name has no effect there.

## Other providers

For a mail provider (for example Mailbox, or Gmail with an app password): the provider's server, port `587` with
STARTTLS (or `465` with SSL/TLS), user and password of the mailbox, and leave the CA file empty.
