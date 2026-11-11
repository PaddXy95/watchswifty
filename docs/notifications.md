# Notifications

WatchSwifty can tell you about new episodes of the series you follow (**🔔 Beobachten**, follow), by mail or through a
webhook. Everything is optional: without setup nothing changes.

## What you get

Under **Konto → Benachrichtigungen** (account → notifications) every user picks any of three notices:

- **sobald eine neue Folge bekannt wird** (as soon as a new episode is known): TMDB lists an episode that was not
  there when you started following the series
- **3 Tage vor der Ausstrahlung** (3 days before it airs): sent when the air date is 1 to 3 days ahead
- **am Tag der Ausstrahlung** (on the air date)

Only regular episodes of followed series count, also when the series is hidden in your library; specials (season 0)
do not. Everything due on a day arrives in **one** message per user, grouped by series, with episode, title and date
and a link to the series when WatchSwifty knows its own address (mail settings or SSO).

Good to know:

- Following a series does not report the episodes TMDB already lists; they still get the two reminders.
- The dates are TMDB's. For US series that is often one day before the episode is available elsewhere.
- A postponed episode gets its reminders again for the new date; „neu angekündigt“ (newly announced) comes only once.
- If sending fails, the same items go out with the next daily run. A reminder for a day that has passed is dropped.
- The notice **Neues Gerät verbunden** (new device connected) uses the same channel and cannot be switched off.

## Daily run

Once a day WatchSwifty refreshes running series from TMDB and then sends notifications. The admin sets the time
under **System → Benachrichtigungen** (default 07:00). It uses the server's time zone, so set `TZ` in the container,
for example `TZ=Europe/Berlin` (see [Configuration](configuration.md)); the page shows the zone in use and the next run.
After a restart the run is repeated at once only when the last one is more than 24 hours old.

## Channels

- **E-Mail** (mail): needs [mail](email.md) set up by the admin and your own address under **Konto**.
- **Webhook (KNot)**: needs the admin's webhook address and your own key.

When both are available you choose one; when your choice is not available any more, the other one is used.
Password resets, invitations and SSO links are always sent by mail, never through the webhook.

## KNot webhook

[KNot](https://github.com/nexus421/KNot) is a small webhook-to-mail bridge. WatchSwifty sends
`POST <address>` with the header `X-API-Key: <key>` and the JSON body `{"subject": "…", "body": "…"}`; KNot turns it
into a mail to the recipient configured for that key.

1. In KNot, add one target per person with their mail address and a key from `java -jar knot.jar key`.
2. As admin, enter the hook address (for example `https://knot.example.lan/hook`) under **System →
   Benachrichtigungen**. Addresses with user info, `?…` or `#…` are rejected; the key belongs in the header.
3. Give each person their key. They enter it under **Konto → Benachrichtigungen** (with their current password, if
   the account has one) and can send a **Testnachricht** (test message).

The key is stored encrypted and never shown again. WatchSwifty waits up to 60 seconds for KNot (it delivers the mail
while the request is open) and does not follow redirects.

## App API

The same settings are available under `/api/v1/me/notifications` and, for admins, `/api/v1/admin/notifications`; see
[App API](app-api.md).
