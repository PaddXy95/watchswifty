# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

WatchSwifty is a self-hosted series and movie tracker: Swift 6.3+, Vapor 4, Fluent/SQLite, server-rendered HTML
with Elementary + htmx (no JS build step), plus a JSON App API. Data comes from TMDB; Netflix viewing history can be
imported.

**Languages:** everything a user sees in the app (UI text, error messages, flash messages) is **German**. The README,
`docs/*.md`, CHANGELOG, the OpenAPI descriptions, code identifiers and code comments are **English**; English docs
quote German UI labels verbatim with the English meaning in parentheses, e.g. **Konto** (account). Design specs and
plans under `docs/superpowers/` stay German, and so does `docs/datenschutz-ios-app.md` (the German privacy policy,
linked from App Store Connect; keep `docs/privacy-ios-app.md` in sync). Commit messages are English Conventional
Commits (`feat(mail): …`, `fix(auth): …`, `docs: …`, `perf: …`).

**Documentation:** the README stays short (features, quick start, links). Details go into the topic pages under
`docs/` (installation, configuration, operations, accounts, tmdb, sso, email, import, app-api, releases, development).
UI hints point to those pages with `DocsLink` (`Web/Components/DocsLink.swift`), not to the README.

## Commands

```bash
swift build
swift test                                                   # whole suite (Swift Testing)
swift test --filter WatchServiceTests                        # one suite / file
swift test --filter "WatchServiceTests/markEpisodeDefaultsToToday"   # one test
DATABASE_PATH=./dev.sqlite ADMIN_USERNAME=admin ADMIN_PASSWORD=adminpass123 swift run App serve
swift run App reset-password <username>                      # CLI command (also via docker-entrypoint.sh)
docker build -t watchswifty .
```

`.claude/launch.json` defines the `watchswifty` preview server (DB `.dev/accept.sqlite`, admin password read from
`.dev/admin-password`, port 8080). No linter or formatter is configured.

The package enables upcoming features `ExistentialAny` (write `any Protocol`), `InternalImportsByDefault` and
`MemberImportVisibility` (import every module whose members a file uses, e.g. `import Fluent` for queries).

## Architecture

### Targets and the API spec
- `WatchSwiftyAPI`: types and the `APIProtocol` server stub are **generated at build time** by
  swift-openapi-generator from `Sources/WatchSwiftyAPI/openapi.yaml` (`accessModifier: package`). That YAML is the
  single source of the App API; `Public/api/openapi.yaml` is a symlink to it (served at `/api/openapi.yaml`, the
  Dockerfile copies `Public` with `cp -RL`).
- `App`: the executable. To change the API, edit `openapi.yaml` first, then implement the generated operation in
  `Sources/App/API/APIHandler+<Group>.swift` (`APIHandler` conforms to `APIProtocol`).

### Startup and dependency wiring
- `entrypoint.swift` builds `AppConfig` from the environment and a `TMDBProvider`, then calls `configure(...)`.
  Tests call the same `configure` with fakes (TMDB, mail sender, release fetcher), so everything wired there is
  exercised by tests.
- `configure.swift` holds the middleware order, the **explicit, ordered migration list** (append new migrations at
  the end), auto-migration, admin bootstrap, and the background workers (Netflix matching, daily catalog refresh,
  update check). Workers only start for `serve` with `backgroundJobsEnabled` (off in tests).
- App-wide singletons live in `Application.storage` behind typed accessors (`Config/Application+Services.swift`
  and similar). Services are cheap structs over `db` + collaborators, exposed per request through `Request`
  extensions at the bottom of each service file (`req.watches`, `req.catalog`, `req.history`, `req.seriesDetails`, …).
- "Today" is `AppConfig.today` (a `YYYY-MM-DD` string, see `CalendarDay`), not `Date()`; tests pin it to
  `2026-11-07`.

### Two front doors, shared services
- **Web UI**: `*Controller.swift` per feature folder registers routes (protected ones via the `protected` group in
  `routes.swift`) and returns `HTMLResponse(<Elementary page or component>)`. Pages are in `Web/Pages`, reusable
  fragments in `Web/Components`, the shell in `Web/Layout.swift`. htmx requests (`req.isHTMX`) usually get just
  the fragment to swap; error responses are swapped too (htmx-config in `Layout`), typically into `#flash`.
- **App API** (`/api/v1`): handlers must only call the services shared with the web UI, so new behavior goes into
  the service and both front doors get it. Errors are `{"code", "message"}` via `APIError`/`APIErrorMiddleware`.
- Feature folders: `Auth` (incl. `Auth/OIDC`: OIDC login, see below), `Account`, `Admin`, `Catalog` (local cache of TMDB titles/episodes), `Tracking`
  (watches, ratings, comments, continue watching, history, library, stats), `Import` (Netflix CSV, film list,
  `MatchingWorker`), `Mail`, `Notify` (daily run schedule, new-episode notices, KNot webhook, per-user channel),
  `TMDB`, `Web`, `API`.

### Auth and security rules
- Web: Fluent sessions (cookie `watchswifty_session`), `User.sessionAuthenticator()` + `AuthRedirectMiddleware`;
  admin-only routes use `RequireAdminMiddleware`.
- API: bearer tokens `ws_…` only (session cookies are ignored). `APIContextMiddleware` resolves the token and puts
  request + user into the `@TaskLocal` `APIContext`; handlers call `APIContext.requireUser()` / `requireAdmin()`.
  Apps obtain tokens through the PKCE flow in `APIAuthorizeController`.
- CSRF: `OriginCheckMiddleware` rejects non-GET web requests unless `Origin` matches the host (or `PUBLIC_ORIGIN`),
  or, without `Origin`, the request is from htmx.
- Per-user isolation: user-owned records are always loaded through the logged-in user; another user's IDs must
  yield 404 (covered by `IsolationTests`).
- Secrets at rest (each user's TMDB token, SMTP settings, user e-mail addresses) are AES-GCM encrypted with
  `TokenCipher` (key from `TOKEN_KEY` / `TOKEN_KEY_FILE` / generated `token.key`). `req.tmdb` is a client for the
  logged-in user's own token; all users share one TMDB `RateLimiter`.

### OIDC login (SSO)
Optional, one provider, configured under System (`OIDCSettingsService`, sealed in `app_settings.oidc_config`, cached in
`app.loginSettings`; `PASSWORD_LOGIN=true` is only an emergency switch; spec `2026-11-07-oidc-login-design.md`).
Read the setup through `req.application.loginSettings.current`, never from `AppConfig` (its `oidc`/`passwordLogin` are
test seeds). `LiveOIDCProvider`
(discovery, JWKS, token exchange over `jwt-kit`) sits behind the `OIDCProvider` protocol; `OIDCController` runs
`/auth/oidc/*` with an encrypted flow cookie (`OIDCFlowCookie`, no session rows for anonymous starts);
`OIDCLoginService` holds the account logic (account lookup by issuer + `sub`, confirmed creation, linking under
`app.oidcIdentityLock`, provider e-mail for accounts without password). Rules depending on the setup go through
`User.isLinked(_:)`, `isSSOAccount(_:passwordLogin:)` and `emailFromProvider(_:)`. Commands: `link-oidc`,
`oidc-move-issuer`.

### TMDB cache rule
`CatalogMaintenance` enforces the TMDB terms: titles are re-fetched after 60 days with the token of a user who uses
them, unused titles are deleted, TMDB texts are cleared after 180 days without refresh. `titleUsers(on:)` lists every
table that counts as "using" a title; **a new per-user table referencing titles must be added there**, or its titles
get deleted. `episode_notices` (sent notifications) deliberately does not count: it must not keep titles cached.

### Notifications
`DailyRefreshLifecycle` runs `runDailyPass` at the admin's time (`app_settings.daily_run_time`, server time zone,
woken by `DailyRunTrigger` on change); the pass ends with `runNotifications`. Due notices are computed from the current
catalog (`episodes.first_seen_at`/`last_seen_at`, `user_titles.followed_at`) against `episode_notices`, sent as one
digest per user through `NotificationService` (mail or `WebhookSender`), and recorded only after a successful send.
Spec `2026-11-11-notifications-design.md`.

## Tests

- Swift Testing (`@Suite`, `@Test`, `#expect`), not XCTest.
- `withTestApp { app in … }` (`Tests/AppTests/Support/TestApp.swift`) runs the real `configure` with in-memory
  SQLite and `AppConfig.testing` (bcrypt cost 4, no login delay, background jobs off, fixed today).
- OIDC tests: `withTestApp(config: .testingOIDC, oidc: FakeOIDCProvider())`, `oidcFlow`/`browserGet`/`browserPost`/
  `newAccountPage`/`linkOIDC` (`Support/OIDCFlow.swift`), `OIDCTestKeys` + `FakeOIDCTransport` for token/provider tests.
- Helpers: `createUser`, `login` (real login form, returns headers with session cookie + same Origin),
  `HTTPHeaders.sameOrigin` / `.htmx` for state-changing web requests, `apiToken` + `HTTPHeaders.bearer` for the API,
  `seedSeries` / `seedMovie` / `episode` in `Support/Seed.swift`, `FakeTMDBClient` (records `calls`, can inject
  failures), `FakeMailSender`.
- `Tests/AppTests/Fixtures/netflix-sample.csv` holds representative rows; never commit a real user's export.
- `ReleaseScriptTests` run `scripts/*.sh` in throwaway git repos.

## Releases and CI

- `.github/workflows/docker.yml`: PRs run `swift test` (in `swift:6.4-noble`); `image-check.yml` adds a test image
  build only for PRs that touch the Docker build (Dockerfile, entrypoint, `Package.*`, workflows). **A push to
  `main` publishes**: image to `ghcr.io/paddxy95/watchswifty` and a GitHub release. A push to `beta` (or a manual
  "Run workflow" on any branch) pushes only `:beta` / `:beta-<sha7>` with `APP_VERSION=<next>-beta`; no tag, no
  release.
- `VERSION` holds the intended version; `scripts/next-version.sh` releases it if the tag doesn't exist yet, else
  bumps the patch. Release notes come from the matching `## [X.Y.Z] – date` section of `CHANGELOG.md` (English,
  sections `### Added`, `### Changed`, `### Fixed`, `### Security`, `### Performance`) via `scripts/release-notes.sh`.
- A release commit bumps `VERSION`, adds the CHANGELOG section and updates the README and `docs/` where user-facing
  behavior changed.

## Design docs

`docs/superpowers/specs/` (German design specs) and `docs/superpowers/plans/` (implementation plans) explain the
reasoning; code comments refer to spec sections such as `§6.2` of `2026-11-07-watchswifty-design.md`.
