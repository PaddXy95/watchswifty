# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

WatchSwifty is a self-hosted series and movie tracker: Swift 6.3+, Vapor 4, Fluent/SQLite, server-rendered HTML
with Elementary + htmx (no JS build step), plus a JSON App API. Data comes from TMDB; Netflix viewing history can be
imported.

**Languages:** everything a user sees (UI text, error messages, flash messages), the README, CHANGELOG and design
docs are **German**. Code identifiers and code comments are English. Commit messages are English Conventional
Commits (`feat(mail): …`, `fix(auth): …`, `docs: …`, `perf: …`).

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
- Feature folders: `Auth`, `Account`, `Admin`, `Catalog` (local cache of TMDB titles/episodes), `Tracking`
  (watches, ratings, comments, continue watching, history, library, stats), `Import` (Netflix CSV, film list,
  `MatchingWorker`), `Mail`, `TMDB`, `Web`, `API`.

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

### TMDB cache rule
`CatalogMaintenance` enforces the TMDB terms: titles are re-fetched after 60 days with the token of a user who uses
them, unused titles are deleted, TMDB texts are cleared after 180 days without refresh. `titleUsers(on:)` lists every
table that counts as "using" a title; **a new per-user table referencing titles must be added there**, or its titles
get deleted.

## Tests

- Swift Testing (`@Suite`, `@Test`, `#expect`), not XCTest.
- `withTestApp { app in … }` (`Tests/AppTests/Support/TestApp.swift`) runs the real `configure` with in-memory
  SQLite and `AppConfig.testing` (bcrypt cost 4, no login delay, background jobs off, fixed today).
- Helpers: `createUser`, `login` (real login form, returns headers with session cookie + same Origin),
  `HTTPHeaders.sameOrigin` / `.htmx` for state-changing web requests, `apiToken` + `HTTPHeaders.bearer` for the API,
  `seedSeries` / `seedMovie` / `episode` in `Support/Seed.swift`, `FakeTMDBClient` (records `calls`, can inject
  failures), `FakeMailSender`.
- `Tests/AppTests/Fixtures/netflix-sample.csv` holds representative rows; never commit a real user's export.
- `ReleaseScriptTests` run `scripts/*.sh` in throwaway git repos.

## Releases and CI

- `.github/workflows/docker.yml`: PRs run `swift test` (in `swift:6.4-noble`) and a test image build. **A push to
  `main` publishes**: image to `ghcr.io/paddxy95/watchswifty` and a GitHub release. A push to `beta` (or a manual
  "Run workflow" on any branch) pushes only `:beta` / `:beta-<sha7>` with `APP_VERSION=<next>-beta`; no tag, no
  release.
- `VERSION` holds the intended version; `scripts/next-version.sh` releases it if the tag doesn't exist yet, else
  bumps the patch. Release notes come from the matching `## [X.Y.Z] – date` section of `CHANGELOG.md` (German,
  sections like `### Neu`, `### Sicherer`, `### Schneller`) via `scripts/release-notes.sh`.
- A release commit bumps `VERSION`, adds the CHANGELOG section and updates the README where user-facing behavior
  changed.

## Design docs

`docs/superpowers/specs/` (German design specs) and `docs/superpowers/plans/` (implementation plans) explain the
reasoning; code comments refer to spec sections such as `§6.2` of `2026-11-07-watchswifty-design.md`.
