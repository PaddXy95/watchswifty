# Changelog

All notable changes to WatchSwifty. Versions follow [SemVer](https://semver.org).

## [0.5.1] – 2026-11-13

### Added
- **Reload all data from TMDB:** under **Konto → TMDB-Token** (account → TMDB token), „Alle Daten von TMDB neu
  laden“ reloads all your series and movies in the background with your token (watched, rated, hidden or followed,
  also finished series), titles without genres or runtime first. The block shows the progress and the result. Useful
  after an update that brings new data, such as the genres in 0.5.0.
- **App API:** `POST /v1/library/refresh` starts the reload, `GET /v1/library/refresh` returns its progress.

### Changed
- Episode titles on the series page are no longer underlined, and the episodes have more space between them.
- **Statistics → Dienste** (services) shows the five services with the most time, like the other lists, so the panel
  is no taller than its neighbours; the others fold out under „N weitere Dienste“ (N more services).

### Fixed
- **System → Version & Updates:** after an update the page no longer claims „Du nutzt die neueste Version“ (you use
  the newest version) with the older release found before the update; it says the installation was updated since
  the last check. With automatic checks on, the check runs right after an update instead of up to 12 hours later.

## [0.5.0] – 2026-11-13

### Added
- **Genres:** series and movies show their TMDB genres below the title, and the library can be filtered by genre
  (only genres that occur in your own library). Series and movies share one list with German names; TMDB's mixed
  series genres are split („Action & Adventure“ → Action + Abenteuer, „Sci-Fi & Fantasy“ → Science-Fiction + Fantasy,
  „War & Politics“ → Krieg + Politik). Existing titles get their genres when their page is opened or in the daily run.
- **More statistics:** „Längste Filme“ (longest movies), „Meistgesehene Filme“ (most watched movies),
  „Meistgesehene Folgen“ (most watched episodes), „Meistgesehene Serien“ (how often a series was watched completely,
  over all years) and „Genres“ (series and movie time per genre). „Dienste“ (services) also counts episodes and movies
  per service. The former „Meistgesehen“ list is now called „Längste Serien“ (longest series).
- **Service for a whole season or series:** „Ganze Staffel gesehen“ and „Gesamte Serie gesehen“ (whole season / whole
  series watched) let you choose the streaming service, preset to the one last used for the series.
- **Netflix import, „Zu prüfen“ (to review):** every entry shows when Netflix says it was watched, and the single rows
  fold out under „Zeilen anzeigen“ (show rows). Candidates have a larger poster (click to enlarge) and a link to TMDB.
- **App API:** `genres` on `SeriesDetail`, `MovieDetail` and `LibraryEntry`, `GET /v1/library?genre=`;
  `GET /v1/stats` returns `longestMovies`, `mostWatchedMovies`, `mostWatchedEpisodes`, `mostCompletedSeries`,
  `genres`, and `episodes`/`movies` per service; `MappingReview` returns `firstDay`, `lastDay` and `rows`. All new
  response fields are optional, so apps keep working with older servers. The Swift client gets the open type
  `GenreValue`.

### Changed
- **Episodes on the series page** are folded: the episode title opens description and watch form (replacing
  „Details“), the checkbox still marks it watched right away. After „Gesehen“ (watched) the episode stays open.
- **System** and **Konto** (account) are split into collapsible blocks; the block of the last action stays open. The
  update notice in the footer opens „Version & Updates“.
- **Webhook key** under **Konto → Benachrichtigungen** (account → notifications) no longer needs the current password,
  in the web UI and the API (`currentPassword` is still accepted and ignored).
- **Pocket ID** is the example identity provider in the SSO setup and in [docs/sso.md](docs/sso.md), with a short
  setup section.
- The Netflix instructions name the current path (**Konto → Einstellungen → Titelverlauf → Alle herunterladen**).
- Pages without login (sign-in, forgotten password, new SSO account) no longer show the version in the footer.
- TMDB genres count as TMDB texts and are removed with them after 180 days without a refresh.

### Fixed
- Episode titles stay readable on phones.
- The service choice for a season and the whole series is refreshed after every watch.
- Browsers no longer fill the login password into the webhook key field.
- After an update, a cached old stylesheet or htmx file no longer styles the page: asset links carry a version.
- More space between the buttons under **Konto → Benachrichtigungen** and between the buttons of an episode.

### Performance
- Statistics, library and „Weiterschauen“ (continue watching) read watches as a lean SQL projection instead of full
  models, and the library is loaded once per page. Measured with 4,152 watches (release build): `/stats` 0.71 s →
  0.11 s, `/library` 0.35 s → 0.07 s, `/` 0.21 s → 0.11 s.

## [0.4.0] – 2026-11-11

### Added
- **Notifications about new episodes:** for followed series, every user can be told as soon as a new episode is
  known, 3 days before it airs and on the air date, in one daily message, by mail or through a
  [KNot](https://github.com/nexus421/KNot) webhook (**Konto → Benachrichtigungen**, account → notifications). The
  notice about newly connected devices uses the same channel.
- **Time of the daily run:** the admin sets it under **System → Benachrichtigungen** (default 07:00, server time
  zone), together with the KNot webhook address. After a restart the run only repeats when the last one is more than
  24 hours old.
- **App API:** `GET/PUT /v1/me/notifications`, `PUT/DELETE /v1/me/notifications/webhook-key`,
  `POST /v1/me/notifications/test`, `GET/PUT /v1/admin/notifications`; error codes `notificationsNotConfigured` and
  `notifyFailed`. The Swift client gets the open type `NotifyChannelValue`.
- **App API: next episode of a series:** `GET /api/v1/tv/{id}` now also returns the next episode (`next`, as in
  „Weiterschauen“ (continue watching)) and, per season, whether the web UI shows it expanded (`isOpen`).
- **Client library for the iOS app:** The Swift package now also offers the `WatchSwiftyClient` library, generated from
  the same API description as the server. Values that can grow with new versions (streaming services, import and
  matching status, device kind) are open there, so older apps keep understanding newer servers.
- **Login via OIDC (SSO):** Sign in through your own identity provider (Authentik, Keycloak, Authelia, Pocket ID …)
  with „Mit SSO anmelden“ (sign in with SSO). Existing accounts are linked under **Konto** (account), new ones are
  created after confirmation on first login, and invitations can be accepted via SSO. The **Benutzer** (users) page
  shows who is already linked and generates linking URLs. Everything is set up under
  **System → Anmeldung über OIDC (SSO)** (stored encrypted, with „Verbindung testen“ (test connection)); password login
  can be switched off there afterwards. Emergency switch `PASSWORD_LOGIN=true`, emergency exit `link-oidc`, provider
  address change with `oidc-move-issuer`.
- **App API:** `Me` and `UserSummary` report `ssoLinked`, `Me` additionally `passwordLogin`; new endpoint
  `POST /v1/admin/users/{id}/sso-link`, SSO settings under `/v1/admin/oidc` (incl. test and password login switch);
  new error codes `passwordLoginDisabled`, `emailFromProvider` and `oidcCheckFailed`.
- **Mail for a new device:** When an app connects to an account, a mail goes to the address stored under **Konto**,
  with device name, time and a link to sign out (only if e-mail is set up).
- **License:** WatchSwifty is released under the MIT license (`LICENSE`), as are the `WatchSwiftyClient` client library
  and the API description. The Docker image carries the license as a label.

### Changed
- **Documentation in English:** The README is now short (features, quick start, links); setup and operation are
  described in topic pages under `docs/`. CHANGELOG, API description (`/api`), `docker-compose.yml` and `.env.example`
  are English as well; the web UI stays German. Hints on the **System** page link to the matching page. The privacy
  policy of the iOS app is also available in English (`docs/privacy-ios-app.md`).
- **App login:** The redirect URI is now `dev.patmei.watchswifty:/auth` instead of `watchswifty://auth` (scheme in
  reverse-DNS form, RFC 8252). Apps must be updated; the old URI is rejected.
- App API: A failed mail delivery responds with **503** `mailFailed` instead of 502.

### Fixed
- **Followed but hidden series** were never refreshed from TMDB when no other user had them visible: the daily refresh
  now also uses the token of a user who follows the series.
- **Behind Cloudflare**, a failed test mail or invitation shows the message with the cause again instead of
  Cloudflare's „Bad gateway“ page. Cloudflare replaces every 502 response; WatchSwifty now responds with 503 in such
  cases. The same applies to „TMDB nicht erreichbar“ (TMDB unreachable).
- **System → E-Mail:** A password without a user name was silently discarded on save, and mails then went out without
  authentication. Now a notice appears and nothing is saved.

### Security
- **New session on every login:** Password login, SSO and setting a password via a reset or invitation link now issue a
  new session ID and delete the old one. A session planted in the browser beforehand (for example by another service on
  the same server) can therefore never become a logged-in one (session fixation).
- **SSO accounts and apps:** Accounts that can only sign in through the provider go through the provider once before an
  app is connected and before a manually created token; anyone blocked there gets no new token.
- No page can be embedded in other sites any more (`X-Frame-Options: DENY`, `frame-ancestors 'none'`). This protects
  against clickjacking, including by other services on the same server or under the same domain.
- The API docs under `/api` no longer store a pasted token in the browser; a previously stored one is deleted on
  opening.
- **Mail client updated to SwiftySMTPClient 0.1.2:** line breaks in addresses and SMTP commands are rejected before
  anything is sent (CWE-93), with a German message under **System → E-Mail**.

## [0.3.0] – 2026-11-09

### Added
- **E-mail (optional):** SMTP delivery, set up as admin under **System → E-Mail** (system → e-mail) and stored
  encrypted; with „Testmail senden“ (send test mail). Works with [SwiftyRelay](https://github.com/PaddXy95/SwiftyRelay)
  (CA file from its volume) and ordinary providers.
- **Invitations:** The admin creates an account with a user name and e-mail address, and the person sets their own
  password via the link (valid for 7 days, can be resent). Admins only see addresses in abbreviated form.
- **Passwort vergessen** (forgot password) on the login page: link by mail to the address stored under **Konto**
  (account), valid for 1 hour.
- **Konto:** store your own e-mail address (stored encrypted, changing it requires the current password).
- App API: mail settings, invitations and your own address (`/api/v1/admin/mail`, `/api/v1/admin/users/{id}/invite`,
  `/api/v1/me/email`).

### Security
- Login no longer reveals through the response time whether a user name exists.

## [0.2.6] – 2026-11-08

### Added
- **App icon:** „WS“ with a swift taking off – as the favicon in the browser tab, in the page header, as the icon on
  the home screen (iPhone/Android) and in the README.
- **Forgot password:** `reset-password <user>` resets a password on the server, even for the only admin
  (`docker exec -it watchswifty /app/docker-entrypoint.sh reset-password <user>`, the password is prompted for without
  echo).

## [0.2.5] – 2026-11-08

### Added
- **Clearer statistics:** Pick the period at the top (all years or one year) – key figures with change from the
  previous year, a „Zeit pro Monat“ (time per month) chart (series and movies stacked, values on hover), share per
  service, „Meistgesehen“ (most watched, top 5 series) and ratings as a chart. The previous tables are under
  „Alle Zahlen“ (all figures). The App API returns the same fields (`GET /api/v1/stats?year=` now filters everything).

### Performance
- Posters are loaded in a suitable size, lazily and asynchronously.
- „Weiterschauen“ (continue watching) opens much faster.

### Fixed
- App API: no more tokens, cookies or passwords in error logs; malformed requests give 4xx instead of 500; size limits
  for requests; huge page numbers no longer crash the server.

## [0.2.4] – 2026-11-08

### Added
- **App API (phase 5):** user management (never for your own account) and system (version, update check) – so the API
  can do everything the web UI can.

### Changed
- **Benutzer (web)** (users): Admins can no longer change their own password and admin right through user management
  (own password under **Konto**, account).

## [0.2.3] – 2026-11-08

### Added
- **App API (phase 4):** Netflix import (upload up to 10 MB, status, „Zu prüfen“ (to review), change matches, assign
  unmatched rows) and movie list (upload up to 2 MB, suggestions, search, skip).

## [0.2.2] – 2026-11-08

### Added
- **App API (phase 3):** history (paging, change/delete a viewing), library, statistics and account (password, TMDB
  token, watched series).

## [0.2.1] – 2026-11-08

### Added
- **App API (phase 2):** „Weiterschauen“ (continue watching) incl. „next episode watched“ and service link, notices
  (new episodes, upcoming), search, series (details, check off episodes/season/series, rating, comments, watching,
  hiding) and movies.

## [0.2.0] – 2026-11-08

### Added
- **App API (phase 1):** JSON API under `/api/v1`, described in an OpenAPI file (the server code is generated from it),
  docs with „Ausprobieren“ (try it out) under `/api`.
- **App login:** Login in the browser window with confirmation („App verbinden“ (connect app)), followed by a device
  token (valid for 90 days, stored only as a hash). Under **Konto → Geräte** (account → devices) see all devices and
  sign them out, and create tokens for scripts.

## [0.1.2] – 2026-11-08

### Added
- **Weiterschauen** (continue watching)**:** Button for the most recently used service instead of only „Auf Netflix
  suchen“ (search on Netflix) – search on Netflix, Prime Video, Apple TV+ and Paramount+; „Disney+ / HBO Max / WOW
  öffnen“ (open; there is no web search there without login).
- **TMDB terms:** daily cache maintenance – every title is re-fetched after 60 days at the latest with the token of a
  user who uses it; unused titles are deleted, old suggestion lists are discarded. The footer on the right shows the
  TMDB logo and notice (instead of „GitHub“).

## [0.1.1] – 2026-11-07

### Added
- **Import movie list:** your own CSV (e.g. from Numbers) with date, service, rating 0–100 → 1–10 and comment from
  „Mit …“ (with …), „Übeltäter“ (culprit) and „Bemerkung“ (remark); unclear movies are suggested for selection.
- **Update notice:** admin page „System“ with an optional check for new releases on GitHub (every 12 hours, off by
  default) and „Jetzt prüfen“ (check now).
- **Operations:** `docker-compose.yml` reads all settings from an `.env` (template `.env.example`); without
  `TOKEN_KEY`, Compose does not start.


### Fixed
- Data folder as a bind mount (e.g. `/home/docker/watchswifty:/data`): At start, the container hands the folder to the
  app user (UID 999) instead of crashing with „cantOpen“; if that is not possible, a message explains what to do.

### Changed
- CI: GitHub Actions on Node 24 versions; the image build runs in parallel with the tests, dependencies are cached in
  the Docker build – a push now only rebuilds the app.

## [0.1.0] – 2026-11-07

First version.

### Added
- **Weiterschauen** (continue watching)**:** one card per series with the next episode, „✓ gesehen“ (watched), hide,
  link „Auf Netflix suchen“ (search on Netflix); only series from the last 3 months (older ones via „N ältere Serien
  anzeigen“ (show N older series)).
- **Watching:** watch series on the series page; box „Neue Folgen“ (new episodes, with „Erledigt“ (done)) and
  „Demnächst“ (upcoming, episodes of the next 14 days) on the home page; list of watched series under Konto (account).
- **Manual tracking:** check off episodes/movies with date and service (Netflix, Prime Video, Disney+, Apple TV+,
  HBO Max, Paramount+, WOW, Kino (cinema), Gekauft (bought), Sonstiges (other)), watched again, „Ganze Staffel“
  (whole season), „bis hier“ (up to here) and „Gesamte Serie gesehen“ (whole series watched), rating 1–10, private
  comments on series, season and movie.
- **Detail pages:** synopsis for series, movie and every episode; links to TMDB, IMDb, Rotten Tomatoes and SeriesGraph.
- **Netflix import:** viewing activity as CSV (including Excel variants), automatic TMDB matching, „Zu prüfen“ (to
  review), „Nicht zugeordnet“ (unmatched), „Zuordnungen“ (matches), „Erneut versuchen“ (retry) and automatic retry.
- **Verlauf** (history) and **Bibliothek** (library) with filter and sorting.
- **Statistics:** movies, series, episodes and time spent (TMDB runtimes) – overall, per year and month, and by
  rating.
- **Users:** multiple accounts with separate data, admin management, own TMDB token per user (encrypted in the
  database with AES-GCM, key via `TOKEN_KEY`).
- **UI:** WatchSwifty branding, smartphone layout with burger menu, loading bar and loading animation on tiles, German
  error pages.
- **Operations:** Docker image via GitHub Actions (`ghcr.io/paddxy95/watchswifty`), Compose file, SQLite database in
  the volume, version in the footer and at `/version`.
