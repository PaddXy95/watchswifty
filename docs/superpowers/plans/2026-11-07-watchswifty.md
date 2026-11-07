# watchswifty Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Self-hosted multi-user series/movie tracker: Netflix CSV import, manual per-episode tracking with date/service/rating, "Weiterschauen" shelf, history, library, admin-managed accounts.

**Architecture:** One Vapor 4 executable (`App`) with Fluent on SQLite, server-rendered HTML via Elementary components and htmx 2 for partial updates. TMDB is the shared metadata cache (`titles`, `episodes`); everything else is per user. Background work (import matching, daily TMDB refresh) runs as in-process Swift tasks – no queue, no Redis, no Node.

**Tech Stack:** Swift 6.4 toolchain, Vapor 4.122.x, Fluent 4.13, fluent-sqlite-driver 4.9, Elementary 0.9.0, ElementaryHTMX 0.7.0 (`ElementaryHTMX2`), htmx 2.0.11, Swift Testing + VaporTesting, Docker, GitHub Actions → ghcr.io.

**Spec:** `docs/superpowers/specs/2026-11-07-watchswifty-design.md` (approved 2026-11-07). Read it before starting; section numbers below (§) refer to it.

## Global Constraints

- `// swift-tools-version:6.3`, platforms `.macOS(.v14)`; executable target `App`, test target `AppTests` (Swift Testing, `VaporTesting`).
- Dependencies exactly: `vapor` `from: "4.122.3"`, `fluent` `from: "4.13.0"`, `fluent-sqlite-driver` `from: "4.9.0"`, `swift-nio` `from: "2.101.0"`, `elementary` `exact: "0.9.0"`, `elementary-htmx` `exact: "0.7.0"` (product `ElementaryHTMX2`). No other packages.
- swiftSettings as in the Vapor template: upcoming features `ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility`, `InferIsolatedConformances`, `ImmutableWeakCaptures`.
- htmx `2.0.11`, vendored at `Public/js/htmx.min.js`. No other JavaScript, no build step.
- All UI copy in German. Strings quoted in this plan are exact.
- Env vars (§9): `TMDB_TOKEN` (required), `TMDB_LANGUAGE` (default `de-DE`), `DATABASE_PATH` (default `/data/watchswifty.sqlite`), `HOST` (default `0.0.0.0`), `PORT` (default `8080`), `ADMIN_USERNAME`/`ADMIN_PASSWORD` (first start only). Missing `TMDB_TOKEN` → app refuses to start with a message naming the variable.
- Every per-user table has `user_id` → `users.id` with `onDelete: .cascade`. Every per-user lookup filters by the logged-in user; a foreign ID yields **404**.
- Dates without time are ISO day strings `yyyy-MM-dd` internally (`watched_on`, `air_date`), displayed as `dd.MM.yyyy`. "Today" = process time zone (`TZ`, compose sets `Europe/Berlin`). Future dates are rejected.
- Services (fixed list, raw values stored): `netflix` „Netflix“, `prime_video` „Prime Video“, `disney_plus` „Disney+“, `apple_tv` „Apple TV+“, `cinema` „Kino“, `other` „Sonstiges“; `nil` = unbekannt.
- Rating: integer 1–10 or none, per user per title.
- Passwords: Bcrypt, minimum 8 characters. Session cookie: 30 days, `HttpOnly`, `SameSite=Lax`, sessions stored via Fluent.
- State-changing requests (non-GET/HEAD) must pass the Origin check (Task 3).
- Upload limit 10 MB. TMDB: ≤ 20 requests/s, honour HTTP 429 `Retry-After`.
- Auto-match only on a unique exact (normalized) name match; anything uncertain stays unmatched/for review (§2 anti-goals).
- The user's real export `/Users/patrickmeindl/Downloads/NetflixViewingHistory.csv` is **never** committed; only the fixture from Task 11.

## Review Focus

1. **CSV saved through Excel/Numbers** (UTF-8 BOM, CRLF line endings) → imports exactly like the original. Test in Task 11.
2. **Wrong file uploaded** (full DSGVO export `ViewingActivity.csv`, random CSV) → clear German error, nothing stored. Test in Task 14.
3. **TMDB down or token invalid mid-import** → rows stay pending (not "nicht zugeordnet"), error visible on the import page, next run retries. Test in Task 15.
4. **Session expired while clicking an htmx control** → whole page goes to `/login` (`HX-Redirect`), no login form swapped into a fragment. Test in Task 3.
5. **Double-click on „✓ gesehen“ / episode checkbox** → exactly one watch. Test in Task 7.

---

## File Structure

```
Package.swift  Dockerfile  docker-compose.yml  .dockerignore  .gitignore  README.md
.github/workflows/docker.yml
Public/js/htmx.min.js  Public/css/app.css
Sources/App/
  entrypoint.swift  configure.swift  routes.swift
  Config/AppConfig.swift  Config/Application+Services.swift  Config/CalendarDay.swift
  Web/HTMLResponse.swift  Web/HTMX.swift  Web/Layout.swift
  Web/Pages/*.swift          (one HTMLDocument per page)
  Web/Components/*.swift     (fragments reused by pages and htmx responses)
  Auth/User.swift  Auth/CreateUser.swift  Auth/AdminBootstrap.swift  Auth/AuthController.swift
  Auth/OriginCheckMiddleware.swift  Auth/AuthRedirectMiddleware.swift  Auth/RequireAdminMiddleware.swift
  Admin/AdminUsersController.swift  Account/AccountController.swift
  TMDB/TMDBClient.swift  TMDB/LiveTMDBClient.swift  TMDB/RateLimiter.swift
  Catalog/Title.swift  Catalog/Episode.swift  Catalog/CatalogMigrations.swift  Catalog/CatalogService.swift  Catalog/DailyRefresh.swift
  Tracking/StreamingService.swift  Tracking/UserTitle.swift  Tracking/Watch.swift  Tracking/TrackingMigrations.swift
  Tracking/WatchService.swift  Tracking/NextEpisode.swift  Tracking/ContinueWatchingService.swift
  Tracking/TitleController.swift  Tracking/SearchController.swift  Tracking/HomeController.swift
  Tracking/HistoryController.swift  Tracking/LibraryController.swift
  Import/NetflixCSV.swift  Import/NetflixTitleParser.swift  Import/TitleNormalizer.swift
  Import/MappingMatcher.swift  Import/EpisodeMatcher.swift
  Import/NetflixImport.swift  Import/NetflixRow.swift  Import/NetflixMapping.swift  Import/ImportMigrations.swift
  Import/ImportService.swift  Import/MatchingWorker.swift  Import/MappingService.swift  Import/ImportController.swift
Tests/AppTests/
  Support/TestApp.swift  Support/FakeTMDBClient.swift  Support/Seed.swift
  Fixtures/netflix-sample.csv
  <Area>Tests.swift (one per task area)
```

Feature folders (Auth, Catalog, Tracking, Import) hold model + migration + service + controller of that area; `Web/` holds shared rendering infrastructure and components.

---

### Task 1: Project skeleton, configuration, health check

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/App/entrypoint.swift`, `Sources/App/configure.swift`, `Sources/App/routes.swift`, `Sources/App/Config/AppConfig.swift`, `Sources/App/Config/Application+Services.swift`, `Sources/App/Config/CalendarDay.swift`
- Test: `Tests/AppTests/Support/TestApp.swift`, `Tests/AppTests/ConfigTests.swift`, `Tests/AppTests/CalendarDayTests.swift`

**Interfaces:**
- Produces:
  - `struct AppConfig: Sendable { tmdbToken: String; tmdbLanguage: String; databasePath: String; host: String; port: Int; adminUsername: String?; adminPassword: String?; loginFailureDelay: Duration; backgroundJobsEnabled: Bool }`
  - `static func AppConfig.fromEnvironment(_ env: [String: String]) throws -> AppConfig`, `static var AppConfig.testing: AppConfig` (token `"test"`, db `":memory:"`, admin `"admin"`/`"adminpass123"`, delay `.zero`, background jobs `false`)
  - `enum ConfigError: Error, Equatable { case missing(String) }`
  - `func configure(_ app: Application, config: AppConfig) async throws` – sets host/port, SQLite (`":memory:"` → `.sqlite(.memory)`, else `.sqlite(.file(path))`), registers migrations, runs `app.autoMigrate()`, then routes.
  - `app.appConfig: AppConfig` (Application storage accessor)
  - `enum CalendarDay { static func today(now: Date = .now, timeZone: TimeZone = .current) -> String; static func isValid(_ iso: String) -> Bool; static func daysBetween(_ a: String, _ b: String) -> Int; static func display(_ iso: String) -> String }`
  - Test helper `func withApp(config: AppConfig = .testing, _ test: (Application) async throws -> Void) async throws` (template pattern: `Application.make(.testing)`, `configure`, test, `asyncShutdown`; no separate autoMigrate – configure does it).

- [ ] **Step 1:** `git init` in `/Users/patrickmeindl/Downloads/watchswifty`; `.gitignore` with `.build/`, `.swiftpm/`, `*.sqlite`, `.env`, `DerivedData/`.
- [ ] **Step 2: Write failing tests**

```swift
@Test func missingTokenFails() {
    #expect(throws: ConfigError.missing("TMDB_TOKEN")) { try AppConfig.fromEnvironment([:]) }
}
@Test func defaults() throws {
    let c = try AppConfig.fromEnvironment(["TMDB_TOKEN": "t"])
    #expect(c.tmdbLanguage == "de-DE"); #expect(c.databasePath == "/data/watchswifty.sqlite")
    #expect(c.host == "0.0.0.0"); #expect(c.port == 8080); #expect(c.adminUsername == nil)
    #expect(c.backgroundJobsEnabled)
}
@Test func healthz() async throws {
    try await withApp { app in
        try await app.testing().test(.GET, "healthz") { res async in
            #expect(res.status == .ok); #expect(res.body.string == "ok")
        }
    }
}
@Test func calendarDay() {
    #expect(CalendarDay.display("2026-11-07") == "07.11.2026")
    #expect(CalendarDay.daysBetween("2026-11-06", "2026-11-07") == 1)
    #expect(CalendarDay.isValid("2026-02-30") == false)
}
```

- [ ] **Step 3:** Run `swift test` → FAIL (types missing).
- [ ] **Step 4:** Implement the files above. `entrypoint.swift` follows the template (`Environment.detect`, `LoggingSystem.bootstrap`, `Application.make(env)`), reads `ProcessInfo.processInfo.environment` via `AppConfig.fromEnvironment`; on `ConfigError.missing(name)` print `Fehlende Umgebungsvariable: <name>` and exit non-zero. `GET /healthz` returns `"ok"` without auth.
- [ ] **Step 5:** Run `swift test` → PASS.
- [ ] **Step 6:** Commit spec + plan + skeleton: `git add -A && git commit -m "chore: project skeleton, config, health check"`.

---

### Task 2: HTML rendering, layout, static assets

**Files:**
- Create: `Sources/App/Web/HTMLResponse.swift`, `Sources/App/Web/HTMX.swift`, `Sources/App/Web/Layout.swift`, `Public/js/htmx.min.js`, `Public/css/app.css`
- Modify: `Sources/App/configure.swift` (FileMiddleware)
- Test: `Tests/AppTests/RenderingTests.swift`

**Interfaces:**
- Produces:
  - `struct HTMLResponse: AsyncResponseEncodable { init(status: HTTPStatus = .ok, headers: HTTPHeaders = [:], _ content: some HTML) }` – renders eagerly via `content.render()`, sets `Content-Type: text/html; charset=utf-8`. Own adapter; do not depend on `vapor-elementary`.
  - `enum NavItem: Sendable { case continueWatching, history, library, search, importing, account, admin }`
  - `struct NavContext: Sendable { let username: String; let isAdmin: Bool; let active: NavItem }`
  - `struct PageLayout<Content: HTML>: HTMLDocument` with `init(title: String, nav: NavContext?, @HTMLBuilder content: () -> Content)` – `<title>` is `"<title> · watchswifty"`, links `/css/app.css`, `<script src="/js/htmx.min.js">`, nav labels „Weiterschauen“, „Verlauf“, „Bibliothek“, „Suche“, „Import“, „Konto“, plus „Benutzer“ only when `isAdmin`; logout as a POST form button „Abmelden“. `nav == nil` (login page) renders no navigation.
  - `extension Request { var isHTMX: Bool }` (`HX-Request: true`)

- [ ] **Step 1:** Vendor htmx: `curl -fsSL https://unpkg.com/htmx.org@2.0.11/dist/htmx.min.js -o Public/js/htmx.min.js` and check the file starts with a JS comment/IIFE and is > 30 KB.
- [ ] **Step 2: Write failing tests**

```swift
@Test func layoutContainsAssetsAndNav() {
    let html = PageLayout(title: "Verlauf", nav: .init(username: "pat", isAdmin: false, active: .history)) { p { "x" } }.render()
    #expect(html.contains(#"<script src="/js/htmx.min.js""#))
    #expect(html.contains("Verlauf · watchswifty")); #expect(html.contains("Weiterschauen"))
    #expect(!html.contains("Benutzer"))
}
@Test func textIsEscaped() {
    #expect(p { "<b>&" }.render().contains("&lt;b&gt;&amp;"))
}
@Test func staticCSSServed() async throws {
    try await withApp { app in
        try await app.testing().test(.GET, "css/app.css") { res async in #expect(res.status == .ok) }
    }
}
```

- [ ] **Step 3:** Run → FAIL. If `textIsEscaped` fails after implementation, Elementary does not escape text by default: stop and report – every component would then need explicit escaping.
- [ ] **Step 4:** Implement. `app.css`: dark theme derived from `tv-tracker-main/tokens.css` color/space/text tokens (paper, ink, line, accent, ok, warn, focus), visible `:focus-visible` ring, `@media (prefers-reduced-motion: reduce)` disables transitions, responsive poster grid. No Netflix red/branding.
- [ ] **Step 5:** Run → PASS. Commit `feat: HTML layout, htmx and styles`.

---

### Task 3: Users, login/logout, admin bootstrap, auth and Origin middleware

**Files:**
- Create: `Sources/App/Auth/User.swift`, `Auth/CreateUser.swift`, `Auth/AdminBootstrap.swift`, `Auth/AuthController.swift`, `Auth/OriginCheckMiddleware.swift`, `Auth/AuthRedirectMiddleware.swift`, `Web/Pages/LoginPage.swift`
- Modify: `configure.swift` (sessions, middleware, bootstrap), `routes.swift` (public vs protected groups; placeholder `GET /` page „Weiterschauen“ until Task 10)
- Test: `Tests/AppTests/AuthTests.swift`, extend `Support/TestApp.swift`

**Interfaces:**
- Produces:
  - `final class User: Model, ModelSessionAuthenticatable, @unchecked Sendable` – schema `users`: `id: UUID`, `username` (unique, stored lowercased/trimmed), `password_hash`, `is_admin: Bool`, `created_at`.
  - `func bootstrapAdmin(config: AppConfig, db: any Database, logger: Logger) async throws` – only when `users` is empty and both admin vars set (password ≥ 8); empty + vars missing → log warning `Kein Benutzer vorhanden – ADMIN_USERNAME und ADMIN_PASSWORD setzen.`
  - `extension Request { var currentUser: User { get throws }; var userID: UUID { get throws } }`
  - Routes: `GET /login`, `POST /login` (form `username`, `password`), `POST /logout`.
  - `protected: RoutesBuilder` (group with `User.sessionAuthenticator()` + `AuthRedirectMiddleware`) passed to later route registrations: `func routes(_ app: Application) throws` builds it; later tasks add `XController.register(on protected:)` calls.
  - Test helpers: `func createUser(_ app: Application, _ username: String, password: String = "password123", isAdmin: Bool = false) async throws -> User`; `func login(_ app: Application, _ username: String, password: String = "password123") async throws -> HTTPHeaders` (returns `Cookie`, `Origin: http://localhost:8080`, `Host: localhost:8080` for follow-up requests); `extension HTTPHeaders { static let sameOrigin: HTTPHeaders }`.

Behaviour: login failure (unknown user or wrong password) waits `config.loginFailureDelay` and re-renders the form with „Benutzername oder Passwort falsch.“ (HTTP 200). Success → session, `303` to `/`. Cookie: name `watchswifty_session`, `maxAge` 2592000, `isHTTPOnly`, `sameSite: .lax`; `app.sessions.use(.fluent)` + `SessionRecord.migration`.
`AuthRedirectMiddleware`: unauthenticated → `303 Location: /login`; if `req.isHTMX` → `200` with header `HX-Redirect: /login`.
`OriginCheckMiddleware` (global, non-GET/HEAD only): host = `X-Forwarded-Host` ?? `Host`; if `Origin` present its `host[:port]` must equal host, else `403`; if `Origin` absent, require `HX-Request: true`, else `403`.

- [ ] **Step 1: Write failing tests**

```swift
@Test func bootstrapCreatesAdminOnlyWhenEmpty() async throws {
    try await withApp { app in   // .testing config has admin vars
        let users = try await User.query(on: app.db).all()
        #expect(users.count == 1); #expect(users[0].isAdmin); #expect(users[0].username == "admin")
        try await bootstrapAdmin(config: .testing, db: app.db, logger: app.logger)
        #expect(try await User.query(on: app.db).count() == 1)
    }
}
@Test func protectedRedirectsToLogin() async throws  // GET "/" → 303, Location "/login"
@Test func htmxGetsHXRedirect() async throws         // GET "/" with HX-Request → header HX-Redirect == "/login"   (Review Focus 4)
@Test func loginSetsSecureCookie() async throws       // POST login admin/adminpass123 → 303 "/", Set-Cookie contains "HttpOnly", "SameSite=Lax", "Max-Age=2592000"
@Test func loginIsCaseInsensitiveOnUsername() async throws // "ADMIN" works
@Test func wrongPasswordAndUnknownUserSameMessage() async throws // both bodies contain "Benutzername oder Passwort falsch.", no Set-Cookie
@Test func logoutEndsSession() async throws           // after POST /logout, GET "/" → 303 /login
@Test func originCheck() async throws                 // POST /logout with Origin "http://evil.example" → 403; without Origin and without HX-Request → 403; matching Origin → not 403; X-Forwarded-Host "tv.lan:8080" + Origin "http://tv.lan:8080" → not 403
```

- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement. `configure` order: migrations → `autoMigrate` → `bootstrapAdmin` → middleware (`OriginCheckMiddleware`, `app.sessions.middleware`) → routes.
- [ ] **Step 4:** Run → PASS. Commit `feat: user accounts, login, admin bootstrap`.

---

### Task 4: Admin user management and account page

**Files:**
- Create: `Sources/App/Auth/RequireAdminMiddleware.swift`, `Admin/AdminUsersController.swift`, `Account/AccountController.swift`, `Web/Pages/AdminUsersPage.swift`, `Web/Pages/AccountPage.swift`
- Modify: `routes.swift`
- Test: `Tests/AppTests/AdminTests.swift`, `Tests/AppTests/AccountTests.swift`

**Interfaces:**
- Consumes: `User`, `protected`, `createUser`, `login` (Task 3).
- Produces routes: `GET /admin/users`, `POST /admin/users` (`username`, `password`, `isAdmin`), `POST /admin/users/:userID/password` (`password`), `POST /admin/users/:userID/admin` (`isAdmin`), `DELETE /admin/users/:userID`; `GET /account`, `POST /account/password` (`currentPassword`, `newPassword`). Admin routes behind `RequireAdminMiddleware` (non-admin → `403`).
- Validation copy: username 3–32 chars of `[a-z0-9._-]` after lowercasing, else „Benutzername: 3–32 Zeichen, nur a–z, 0–9, . _ -“; duplicate → „Benutzername ist vergeben.“; short password → „Passwort muss mindestens 8 Zeichen haben.“; last admin → „Der letzte Admin kann nicht entfernt werden.“; self-delete → „Du kannst dich nicht selbst löschen.“; wrong current password → „Aktuelles Passwort ist falsch.“ Validation errors re-render with HTTP 422.
- Admin page lists username, „Admin“ badge, created date; never shows other users' tracking data.

- [ ] **Step 1: Write failing tests** – `nonAdminGets403`, `adminCreatesUserWhoCanLogIn`, `duplicateUsernameRejected`, `shortPasswordRejected`, `resetPasswordReplacesOld` (old login fails, new works), `toggleAdmin`, `lastAdminCannotBeDemotedOrDeleted`, `adminCannotDeleteSelf`, `deleteUserRemovesAccount`, `changeOwnPasswordRequiresCurrent`. Assert status codes and the exact copy above.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: admin user management and account page`.

---

### Task 5: TMDB client

**Files:**
- Create: `Sources/App/TMDB/TMDBClient.swift`, `TMDB/LiveTMDBClient.swift`, `TMDB/RateLimiter.swift`, `Tests/AppTests/Support/FakeTMDBClient.swift`
- Modify: `configure.swift` (signature gains `tmdb:`), `entrypoint.swift`, `Config/Application+Services.swift`, `Support/TestApp.swift` (`withApp(config:tmdb:_:)`, default `FakeTMDBClient()`)
- Test: `Tests/AppTests/TMDBTests.swift`

**Interfaces:**
- Produces:

```swift
enum TitleKind: String, Codable, Sendable, CaseIterable { case tv, movie }
struct TMDBSearchResult: Codable, Sendable, Equatable { let id: Int; let kind: TitleKind; let name: String; let originalName: String?; let year: Int?; let posterPath: String? }
struct TMDBSeries: Sendable, Equatable { let id: Int; let name: String; let originalName: String?; let year: Int?; let posterPath: String?; let status: String?; let seasonNumbers: [Int] }
struct TMDBEpisode: Sendable, Equatable { let id: Int; let season: Int; let number: Int; let name: String; let airDate: String? }
struct TMDBMovie: Sendable, Equatable { let id: Int; let name: String; let originalName: String?; let year: Int?; let posterPath: String? }
enum TMDBError: Error, Equatable { case unauthorized, notFound, rateLimited, http(UInt), network(String) }
protocol TMDBClient: Sendable {
    func search(_ query: String, kind: TitleKind) async throws -> [TMDBSearchResult]
    func searchMulti(_ query: String) async throws -> [TMDBSearchResult]
    func series(id: Int) async throws -> TMDBSeries
    func season(seriesID: Int, number: Int) async throws -> [TMDBEpisode]
    func movie(id: Int) async throws -> TMDBMovie
}
func configure(_ app: Application, config: AppConfig, tmdb: any TMDBClient) async throws
// app.tmdb: any TMDBClient
```

  - `LiveTMDBClient(client: any Client, token: String, language: String, limiter: RateLimiter)`; base `https://api.themoviedb.org/3`; header `Authorization: Bearer <token>`; every request carries `language=<language>`; searches add `include_adult=false`. Paths: `search/tv`, `search/movie`, `search/multi` (keep only `media_type` tv/movie), `tv/{id}`, `tv/{id}/season/{n}`, `movie/{id}`. TV uses `name`/`original_name`/`first_air_date`, movies `title`/`original_title`/`release_date`; year = first 4 chars, `""` → nil; `air_date: ""` → nil.
  - Static, testable pieces: `LiveTMDBClient.url(path: String, query: [String: String], language: String) -> URI`, `decodeSearch(_: Data, kind: TitleKind)`, `decodeMulti(_: Data)`, `decodeSeries(_: Data)`, `decodeSeason(_: Data)`, `decodeMovie(_: Data)`, `retryDelay(status: UInt, retryAfter: String?, attempt: Int) -> Duration?` (429 → `Retry-After` seconds or 2 s, attempts 1…3; otherwise nil). Status 401 → `.unauthorized`, 404 → `.notFound`, 429 after retries → `.rateLimited`.
  - `actor RateLimiter { init(minInterval: Duration = .milliseconds(50)); func acquire() async throws }`
  - `final class FakeTMDBClient: TMDBClient, @unchecked Sendable` (state in `NIOLockedValueBox`): settable `searchResults: [String: [TMDBSearchResult]]` keyed `"\(kind):\(query)"` (`"multi:\(query)"`), `seriesByID`, `seasons: [String: [TMDBEpisode]]` keyed `"\(seriesID)/\(n)"`, `moviesByID`, `failure: TMDBError?` (thrown by every call when set), `calls: [String]` log.

- [ ] **Step 1: Write failing tests** – decode fixtures written inline as JSON strings: `decodesTVSearch` (year from `"2008-09-23"` → 2008, empty date → nil), `multiSkipsPeople` (a `media_type: "person"` entry is dropped), `decodesSeasonEpisodesWithEmptyAirDate`, `urlCarriesLanguageAndEncodesQuery` (`query: "Pokémon"` → URI string contains `language=de-DE` and `query=Pok%C3%A9mon`), `retryDelayRules` (`(429,"3",1) == .seconds(3)`, `(429,nil,1) == .seconds(2)`, `(429,"3",4) == nil`, `(500,nil,1) == nil`).
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement; update entrypoint to build `LiveTMDBClient(client: app.client, …)`. **Step 4:** Run → PASS (all earlier tests too).
- [ ] **Step 5:** Commit `feat: TMDB client with rate limiting`.

---

### Task 6: Catalog cache (titles, episodes)

**Files:**
- Create: `Sources/App/Catalog/Title.swift`, `Catalog/Episode.swift`, `Catalog/CatalogMigrations.swift`, `Catalog/CatalogService.swift`
- Test: `Tests/AppTests/CatalogServiceTests.swift`

**Interfaces:**
- Consumes: `TMDBClient`, `TitleKind` (Task 5).
- Produces:
  - `final class Title: Model` – schema `titles`: `tmdb_id: Int`, `kind: String` (computed `titleKind: TitleKind`), `name`, `original_name?`, `year?`, `poster_path?`, `tmdb_status?`, `refreshed_at: Date?`; unique (`kind`, `tmdb_id`).
  - `final class Episode: Model` – schema `episodes`: `title_id` (→ titles, cascade), `season_number`, `episode_number`, `name`, `air_date: String?`, `tmdb_episode_id: Int`; unique (`title_id`, `season_number`, `episode_number`). Episodes are never deleted by refresh.
  - `struct CatalogService { let db: any Database; let tmdb: any TMDBClient`
    `func title(kind: TitleKind, tmdbID: Int) async throws -> Title` (cached or fetched; new series also loads all episodes)
    `func refresh(_ title: Title, now: Date = .now) async throws` (series: details + every season in `seasonNumbers`, upsert by (season, number) keeping episode IDs; movie: details)
    `func refreshIfStale(_ title: Title, now: Date = .now, maxAge: TimeInterval = 604_800) async throws`
    `func episodes(of titleID: UUID) async throws -> [Episode]` (sorted season, number) `}`
  - `extension Request { var catalog: CatalogService }`

- [ ] **Step 1: Write failing tests** (FakeTMDBClient with series 1399 „Testserie“, seasons [1, 2], two episodes each):
  - `newSeriesLoadsAllEpisodes` → 4 episodes; calls contain `series:1399`, `season:1399/1`, `season:1399/2` once each.
  - `cachedTitleMakesNoCalls` → second `title()` adds no calls.
  - `refreshUpsertsKeepingIDs` → rename S1E1 + add S2E3 in fake, `refresh` → 5 episodes, S1E1 same UUID, new name.
  - `refreshIfStaleRespectsAge` → fresh: no calls; `now` + 8 days: refreshed.
  - `movieTitle` → kind movie, no episode rows.
  - `unknownIDPropagatesNotFound` → `TMDBError.notFound`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement (register migrations in `configure`). **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: TMDB catalog cache`.

---

### Task 7: Tracking core (library entries, watches, WatchService)

**Files:**
- Create: `Sources/App/Tracking/StreamingService.swift`, `Tracking/UserTitle.swift`, `Tracking/Watch.swift`, `Tracking/TrackingMigrations.swift`, `Tracking/WatchService.swift`, `Tests/AppTests/Support/Seed.swift`
- Test: `Tests/AppTests/WatchServiceTests.swift`

**Interfaces:**
- Consumes: `User`, `Title`, `Episode`, `CalendarDay`.
- Produces:

```swift
enum StreamingService: String, Codable, Sendable, CaseIterable { case netflix, primeVideo = "prime_video", disneyPlus = "disney_plus", appleTV = "apple_tv", cinema, other
    var label: String }   // labels per Global Constraints
enum WatchOrigin: String, Codable, Sendable { case manual, `import` }
// UserTitle: schema user_titles: user_id (cascade), title_id (cascade), rating: Int?, hidden: Bool (default false); unique (user_id, title_id)
// Watch: schema watches: user_id (cascade), title_id (cascade), episode_id? (→ episodes), watched_on: String?, service: String?, origin: String, created_at
enum TrackingError: Error, Equatable { case notFound, invalidRating, invalidDate, futureDate, notAired }
struct WatchService {
    let db: any Database
    var today: @Sendable () -> String = { CalendarDay.today() }
    func markEpisode(userID: UUID, episodeID: UUID, day: String?, service: StreamingService?, rewatch: Bool = false) async throws -> Watch
    func unmarkEpisode(userID: UUID, episodeID: UUID) async throws
    func markSeason(userID: UUID, titleID: UUID, season: Int, service: StreamingService?) async throws -> Int
    func markUpTo(userID: UUID, episodeID: UUID, service: StreamingService?) async throws -> Int
    func markMovie(userID: UUID, titleID: UUID, day: String?, service: StreamingService?, rewatch: Bool = false) async throws -> Watch
    func unmarkMovie(userID: UUID, titleID: UUID) async throws
    func editWatch(userID: UUID, watchID: UUID, day: String?, service: StreamingService?) async throws
    func deleteWatch(userID: UUID, watchID: UUID) async throws
    func setRating(userID: UUID, titleID: UUID, rating: Int?) async throws
    func setHidden(userID: UUID, titleID: UUID, hidden: Bool) async throws
    func lastService(userID: UUID, titleID: UUID) async throws -> StreamingService?
    func userTitle(userID: UUID, titleID: UUID) async throws -> UserTitle   // get-or-create
}
// extension Request { var watches: WatchService }
// Seed helpers: seedSeries(app, tmdbID:, seasons: [Int: Int], airedUntil: String) -> Title  (direct inserts, no TMDB), seedMovie(app, tmdbID:, name:) -> Title
```

Rules (§5.5–5.7): `markEpisode`/`markMovie`: `day == nil` → today; invalid ISO → `.invalidDate`; > today → `.futureDate`; episode with `air_date` nil or > today → `.notAired`; creates user_title if missing and sets `hidden = false`; without `rewatch`, an existing watch for that episode/movie is returned instead of inserting (double-click guard); with `rewatch`, always inserts. `markSeason`/`markUpTo` insert **undated** manual watches for aired, not-yet-watched episodes (season ≥ 1; `markUpTo` covers all earlier seasons and the target season up to the episode), unhide, return count. `setHidden` only for `.tv` titles (movie → `.notFound`). Rating outside 1…10 → `.invalidRating`. Any ID not belonging to `userID` → `.notFound`.

- [ ] **Step 1: Write failing tests** – `markEpisodeDefaultsToToday`, `doubleMarkCreatesOneWatch` (Review Focus 5), `rewatchAddsSecondWatch`, `futureDateRejected`, `unairedRejected`, `markUnhidesSeries`, `unmarkRemovesAllWatchesOfEpisode`, `markSeasonSkipsWatchedAndUnaired` (count + all inserted have `watched_on == nil`), `markUpToSpansEarlierSeasons`, `ratingBounds` (0 and 11 throw, nil clears), `hideMovieRejected`, `lastServiceIsMostRecentDatedWatch`, `otherUsersWatchIsNotFound` (edit/delete of user A's watch by B → `.notFound`).
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: per-user tracking core`.

---

### Task 8: „Weiterschauen“ rule and service

**Files:**
- Create: `Sources/App/Tracking/NextEpisode.swift`, `Tracking/ContinueWatchingService.swift`
- Test: `Tests/AppTests/NextEpisodeTests.swift`, `Tests/AppTests/ContinueWatchingTests.swift`

**Interfaces:**
- Produces:

```swift
struct EpisodeInfo: Sendable, Equatable { let id: UUID; let season: Int; let number: Int; let name: String; let airDate: String? }
func nextEpisode(in episodes: [EpisodeInfo], watched: Set<UUID>, today: String) -> EpisodeInfo?
func remainingAiredCount(in episodes: [EpisodeInfo], from next: EpisodeInfo, watched: Set<UUID>, today: String) -> Int
struct ContinueCard: Sendable { let titleID: UUID; let tmdbID: Int; let name: String; let posterPath: String?; let rating: Int?
    let next: EpisodeInfo; let remaining: Int; let lastWatchedOn: String?; let lastService: StreamingService?; let hasNetflixData: Bool }
struct ContinueWatchingService { let db: any Database
    func cards(userID: UUID, today: String) async throws -> [ContinueCard]
    func card(userID: UUID, titleID: UUID, today: String) async throws -> ContinueCard? }
```

Rule (§5.2): ignore season 0; highest watched = max (season, number) among watched regular episodes; next = first episode after it with non-nil `airDate <= today` that is not watched; none → nil (caught up). `remaining` counts aired, unwatched episodes from `next` onwards. Cards: tv titles with ≥ 1 watch, not hidden, with a next episode; sorted by latest dated `watched_on` desc, undated-only series by their latest watch `created_at`. `hasNetflixData` = any watch with origin `import` or service `netflix`. Load the user's watches in one query and episodes of all candidate titles in one query (no per-title queries).

- [ ] **Step 1: Write failing tests**
  - `nextEpisode`: `basicNext` (S1E1–2 watched of 4 → S1E3), `gapsBeforeHighestIgnored` (S1E1, S1E3 watched → S1E4), `specialsIgnored` (S0E5 watched only → nil), `crossesSeason` (all S1 watched → S2E1), `unairedAfterHighestGivesNil`, `nilAirDateCountsAsUnaired`, `nothingWatchedGivesNil`.
  - `ContinueWatchingService`: `hiddenExcluded`, `moviesExcluded`, `caughtUpExcluded`, `otherUsersWatchesIgnored`, `sortedByLastWatch`, `remainingCount` (next S4E15 of 24 aired → 10), `netflixFlag`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: next-episode rule and continue-watching service`.

---

### Task 9: Search and detail pages (series, movie) with htmx actions

**Files:**
- Create: `Sources/App/Tracking/SearchController.swift`, `Tracking/TitleController.swift`, `Web/Pages/SearchPage.swift`, `Web/Pages/SeriesPage.swift`, `Web/Pages/MoviePage.swift`, `Web/Components/EpisodeRow.swift`, `Web/Components/SeasonSection.swift`, `Web/Components/RatingControl.swift`, `Web/Components/WatchForm.swift`, `Web/Components/Poster.swift`
- Modify: `routes.swift`
- Test: `Tests/AppTests/TitlePagesTests.swift`

**Interfaces:**
- Consumes: `CatalogService`, `WatchService`, `nextEpisode`, `login`, `FakeTMDBClient`.
- Produces routes (all protected):
  - `GET /search` (page with input; `hx-get="/search/results"`, trigger `input changed delay:300ms`, target `#results`), `GET /search/results?q=` (fragment; `q` < 2 chars → empty; uses `searchMulti`; each item: poster, name, year, „Serie“/„Film“, own status „12/24 gesehen“ and/or „★ 8“; links `/tv/:id` or `/movie/:id`).
  - `GET /tv/:tmdbID` – `catalog.title(.tv)` + `refreshIfStale`; header with name, year, `RatingControl`, „Ausblenden“/„Einblenden“; one `<details>` per season (`open` for the season containing the next episode), summary „Staffel N · x/y gesehen“, button „Ganze Staffel gesehen“; season 0 titled „Specials“, collapsed. `EpisodeRow`: checkbox (aired only), number, name, last watch date `dd.MM.yyyy` + service label, „×N“ when watched more than once, details menu with `WatchForm` (date input max = today, service select incl. „unbekannt“; for watched episodes the submit reads „Erneut gesehen“), button „bis hier gesehen“.
  - `POST /tv/:tmdbID/episodes/:season/:number/watch` (form `day?`, `service?`, `rewatch?`; empty `day` → today; checkbox click sends no service → `lastService`; form `service=""` → unbekannt) → `EpisodeRow` fragment. `DELETE` same path → unmark → `EpisodeRow`.
  - `POST /tv/:tmdbID/seasons/:season/watch` (`service?`) → `SeasonSection`; `POST /tv/:tmdbID/episodes/:season/:number/watch-up-to` (`service?`) → all seasons fragment `#seasons`.
  - `GET /movie/:tmdbID` (poster, year, rating, „Gesehen“ opening `WatchForm`, „Nicht gesehen“, list of own watches with date + service, „Erneut gesehen“); `POST /movie/:tmdbID/watch`, `DELETE /movie/:tmdbID/watch` → movie watch section fragment.
  - `POST /:kind/:tmdbID/rating` (`rating` = "" or 1…10) → `RatingControl`; `POST /tv/:tmdbID/hidden` (`hidden` true/false) → toggle button fragment; unhide calls `catalog.refresh`.
  - Error mapping: `TrackingError.notFound`/`TMDBError.notFound` → 404; `.futureDate` → 422 „Datum liegt in der Zukunft.“; `.invalidDate` → 422 „Ungültiges Datum.“; `.notAired` → 422 „Folge ist noch nicht erschienen.“; `.invalidRating` → 422 „Bewertung muss zwischen 1 und 10 liegen.“; unknown service value → 400.
  - Episode code format `S%02dE%02d`.
  - `struct Poster: HTML { init(path: String?, alt: String) }` – `<img loading="lazy" src="https://image.tmdb.org/t/p/w342<path>">`; `path == nil` → neutral placeholder box with the title's initials. Images are hot-linked, never stored.

- [ ] **Step 1: Write failing tests** (fake TMDB series 1399 with 2 seasons, movie 603 „Matrix“): `searchListsBothKinds` (contains „Serie“, „Film“, `/tv/1399`, `/movie/603`), `searchShowsOwnStatus` (after marking 1 of 4 + rating 8: „1/4 gesehen“, „★ 8“), `seriesPageShowsSeasons` („Staffel 1 · 0/2 gesehen“, „Ganze Staffel gesehen“), `markEpisodeReturnsCheckedRow` (fragment contains today's `dd.MM.yyyy`), `markWithPastDateAndService` (day 2026-11-01, `disney_plus` → „01.11.2026“, „Disney+“), `futureDate422`, `unmarkEpisode`, `markUpToCount` (4 watches with nil date), `ratingOutOfRange422`, `hideAndUnhide`, `movieWatchedInCinema` („Kino“), `unknownTMDBIDIs404`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement with ElementaryHTMX2 helpers (`.hx.post`, `.hx.delete`, `.hx.target`, `.hx.swap(.outerHTML)`); attributes without a helper via Elementary's custom attribute API (check its source for the exact initializer). **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: search and title detail pages`.

---

### Task 10: „Weiterschauen“, „Verlauf“, „Bibliothek“ pages

**Files:**
- Create: `Sources/App/Tracking/HomeController.swift`, `Tracking/HistoryController.swift`, `Tracking/LibraryController.swift`, `Web/Pages/ContinuePage.swift`, `Web/Pages/HistoryPage.swift`, `Web/Pages/LibraryPage.swift`, `Web/Components/ContinueCardView.swift`, `Web/Components/HistoryRow.swift`
- Modify: `routes.swift` (replace placeholder `GET /`)
- Test: `Tests/AppTests/HomeHistoryLibraryTests.swift`

**Interfaces:**
- Consumes: `ContinueWatchingService`, `WatchService`, `CalendarDay`.
- Produces routes:
  - `GET /` – cards as in §5.2: poster, name, „zuletzt dd.MM.yyyy“, „Weiter mit S04E15 · „<name>““, „noch N Folgen“, „zuletzt auf <Dienst>“ (omitted when unknown), „★ N“, buttons „✓ gesehen“ and „Ausblenden“; „Auf Netflix suchen“ linking `https://www.netflix.com/search?q=<percent-encoded name>` only when `hasNetflixData`; empty state „Noch nichts zum Weiterschauen.“
  - `POST /tv/:tmdbID/next` – marks the card's next episode (today, `lastService`) → updated `ContinueCardView` or empty body when caught up (swap `outerHTML`).
  - `POST /tv/:tmdbID/hidden` with `context=card` → empty body (card disappears).
  - `GET /history?page=N` – 50 dated watches per page, sorted `watched_on` desc then `created_at` desc; row: date, title (+ `SxxEyy · <Folgenname>`), service label, „Import“/„manuell“; inline edit form (date, service) `POST /watches/:watchID` → `HistoryRow`; `DELETE /watches/:watchID` → empty; „Mehr laden“ button loads the next page (htmx, replaces itself). Undated watches never appear.
  - `GET /library?filter=all|tv|movie|hidden&sort=recent|rating|name` – titles with ≥ 1 watch or a rating; `hidden` filter lists hidden series with „Einblenden“; poster grid with rating badge.

- [ ] **Step 1: Write failing tests** – `continueCardContent` (seeded series, S4E14 watched on Netflix 2026-11-07 → „Weiter mit S04E15“, „zuletzt auf Netflix“, „07.11.2026“), `netflixLinkOnlyWithNetflixData`, `emptyState`, `quickMarkAdvancesCard` (POST next → „S04E16“), `quickMarkLastEpisodeRemovesCard` (empty body), `historyExcludesUndated`, `historyPaginates` (60 watches → page 1 has 50 rows + „Mehr laden“), `editWatchFromHistory`, `deleteForeignWatchIs404`, `libraryFilters` (hidden filter shows only hidden; movie filter only movies), `librarySortByRating`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: continue watching, history and library pages`.

---

### Task 11: Netflix CSV parser and fixture

**Files:**
- Create: `Sources/App/Import/NetflixCSV.swift`, `Tests/AppTests/Fixtures/netflix-sample.csv`
- Modify: `Package.swift` (test target `resources: [.copy("Fixtures")]`)
- Test: `Tests/AppTests/NetflixCSVTests.swift`

**Interfaces:**
- Produces:

```swift
struct NetflixCSVRow: Sendable, Equatable { let title: String; let day: String; let fingerprint: String }
struct NetflixCSVResult: Sendable, Equatable { let rows: [NetflixCSVRow]; let skippedBlank: Int }
enum NetflixCSVError: Error, Equatable { case notNetflixHistory; case invalidDate(line: Int, value: String) }
func parseNetflixCSV(_ text: String) throws -> NetflixCSVResult
```

Rules (§6.1/6.2): strip UTF-8 BOM; accept `\n` and `\r\n`; RFC-4180 quoting (`""` escape, commas inside quotes); first line must be exactly `Title,Date` else `.notNetflixHistory`; date `M/D/YY` → `20YY-MM-DD`, otherwise `.invalidDate(line:value:)` (1-based file line); skip rows whose trimmed title is empty or starts with `:` (counted in `skippedBlank`); `fingerprint = "\(day)#\(occurrence)#\(title)"`, occurrence = 0-based index among identical (title, day) pairs in file order.

Fixture `Tests/AppTests/Fixtures/netflix-sample.csv` (exact content, LF line endings):

```
Title,Date
"The Mentalist: Staffel 4: Die Aura des Todes","11/7/26"
"The Mentalist: Staffel 4: Keine Lust auf Shakespeare","11/7/26"
"Rick and Morty: Staffel 8: Papa-Morty","11/6/26"
"Star Trek: Deep Space Nine: Staffel 7: Extreme Maßnahmen (7)","3/2/25"
"Star Trek: Deep Space Nine: Staffel 7: Das, was du zurücklässt – Teil 1 und 2","3/9/25"
"Star Trek: Deep Space Nine: Staffel 3: Die Suche: Teil 1","1/5/25"
"DAHMER: Monster: Die Geschichte von Jeffrey Dahmer: Verstummt","10/1/24"
"Monster: Die Geschichte von Lizzie Borden: Blutbad","10/2/25"
"HIS & HERS: Miniserie: Folge 6","8/1/26"
"Haus des Geldes: Teil 1: Folge 6","4/4/19"
"Doppelhaushälfte: Season 3: Der Traum ist aus","6/6/24"
"Ted: Ted – Staffel 1: Die letzte Jungfrau","2/2/25"
"Leben auf unserem Planeten: Kapitel 1: Die Regeln des Lebens","5/5/23"
"Keine Fremde: Folge 2","9/9/25"
"Pokémon: Pika-Pikachu","10/4/15"
"Das fünfte Element","12/24/20"
"Twilight – Biss zum Morgengrauen","1/1/21"
" ","8/19/25"
" : Folge 1","5/5/25"
"The Mentalist: Staffel 1: Pilot","1/1/20"
"The Mentalist: Staffel 1: Pilot","1/1/20"
```

- [ ] **Step 1: Write failing tests** – `parsesFixture` (19 rows, `skippedBlank == 2`, first row `day == "2026-11-07"`, Pokémon row `"2015-10-04"`), `duplicateSameDayGetsOccurrence` (fingerprints end `#0#…`/`#1#…` for the two Pilot rows), `commaInsideQuotes` (title `Das, was du zurücklässt` part intact), `bomAndCRLF` (fixture text with `"\u{FEFF}"` prefix and `\r\n` → identical result to `parsesFixture`; Review Focus 1), `rejectsOtherCSV` (`"Profile Name,Start Time,Duration\n…"` → `.notNetflixHistory`), `invalidDateReportsLine` (`"Title,Date\n\"A\",\"2026-11-07\""` → `.invalidDate(line: 2, value: "2026-11-07")`).
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: Netflix CSV parser`.

---

### Task 12: Netflix title parser

**Files:**
- Create: `Sources/App/Import/NetflixTitleParser.swift`
- Test: `Tests/AppTests/NetflixTitleParserTests.swift`

**Interfaces:**
- Produces:

```swift
enum ParsedNetflixTitle: Sendable, Equatable {
    case episode(show: String, season: Int?, episodeTitle: String)
    case movie(title: String)
}
func parseNetflixTitle(_ raw: String) -> ParsedNetflixTitle
```

Rules: split on `": "`. Scan segments from index 1 up to the second-to-last; the **first** segment matching a season marker splits the title: show = segments before it joined with `": "`, episodeTitle = segments after it joined with `": "`. Markers: `^(Staffel|Season|Teil|Part|Kapitel|Ausgabe|Buch|Volume) (\d+)$` (season = number); `^.+ – Staffel (\d+)$` (season = number); `^(Miniserie|Limitierte Serie|Limited Series)$` (season = nil). No marker: ≥ 2 segments → show = all but the last, episodeTitle = last, season nil; 1 segment → `.movie`.

- [ ] **Step 1: Write failing parameterized test** `@Test(arguments: cases)` with exactly these pairs:

| raw | expected |
|---|---|
| `The Mentalist: Staffel 4: Die Aura des Todes` | episode("The Mentalist", 4, "Die Aura des Todes") |
| `Star Trek: Deep Space Nine: Staffel 7: Extreme Maßnahmen (7)` | episode("Star Trek: Deep Space Nine", 7, "Extreme Maßnahmen (7)") |
| `Star Trek: Deep Space Nine: Staffel 3: Die Suche: Teil 1` | episode("Star Trek: Deep Space Nine", 3, "Die Suche: Teil 1") |
| `Haus des Geldes: Teil 1: Folge 6` | episode("Haus des Geldes", 1, "Folge 6") |
| `Doppelhaushälfte: Season 3: Der Traum ist aus` | episode("Doppelhaushälfte", 3, "Der Traum ist aus") |
| `Leben auf unserem Planeten: Kapitel 1: Die Regeln des Lebens` | episode("Leben auf unserem Planeten", 1, "Die Regeln des Lebens") |
| `Ted: Ted – Staffel 1: Die letzte Jungfrau` | episode("Ted", 1, "Die letzte Jungfrau") |
| `HIS & HERS: Miniserie: Folge 6` | episode("HIS & HERS", nil, "Folge 6") |
| `DAHMER: Monster: Die Geschichte von Jeffrey Dahmer: Verstummt` | episode("DAHMER: Monster: Die Geschichte von Jeffrey Dahmer", nil, "Verstummt") |
| `Pokémon: Pika-Pikachu` | episode("Pokémon", nil, "Pika-Pikachu") |
| `Keine Fremde: Folge 2` | episode("Keine Fremde", nil, "Folge 2") |
| `Das fünfte Element` | movie("Das fünfte Element") |
| `Twilight – Biss zum Morgengrauen` | movie("Twilight – Biss zum Morgengrauen") |

- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: Netflix title parser`.

---

### Task 13: Matching helpers (normalization, show auto-match, episode matcher)

**Files:**
- Create: `Sources/App/Import/TitleNormalizer.swift`, `Import/MappingMatcher.swift`, `Import/EpisodeMatcher.swift`
- Test: `Tests/AppTests/MatchingHelpersTests.swift`

**Interfaces:**
- Consumes: `TMDBSearchResult` (Task 5).
- Produces:

```swift
func normalizeTitle(_ s: String) -> String
func autoMatch(candidate: String, in results: [TMDBSearchResult]) -> TMDBSearchResult?
struct EpisodeCandidate: Sendable, Equatable { let id: UUID; let season: Int; let number: Int; let name: String }
func matchEpisodes(title: String, season: Int?, in candidates: [EpisodeCandidate]) -> [UUID]   // [] = no match
```

- `normalizeTitle`: lowercase; fold diacritics (`é`→`e`, `ä`→`a`, `ß`→`ss`); `–`, `—`, `-`, `:` → space; drop other punctuation; drop a trailing `(<digits>)`; collapse whitespace; trim.
- `autoMatch`: return the result only if **exactly one** result has `normalizeTitle(name) == normalizeTitle(candidate)` or the same for `originalName`.
- `matchEpisodes` (order matters; first rule that decides wins):
  1. Pool = candidates of `season` if given, else all with `season >= 1`.
  2. Title `^Folge (\d+)$` → the pool episode with that number, if the pool spans one season (or season given); else continue.
  3. Exactly one pool episode with equal normalized name → it.
  4. Title ends with `Teil 1 und 2` (optionally preceded by `–`/`:`) → base = title without that suffix; if exactly two pool episodes have normalized names starting with `normalizeTitle(base)` → both IDs (sorted by number).
  5. Fuzzy: similarity = `1 - levenshtein(a, b) / max(len)` on normalized names; take the best; match only if best ≥ 0.85 **and** (no second candidate or second < best − 0.10).
  6. Otherwise `[]`.

- [ ] **Step 1: Write failing tests** – `normalizes` (`"Pokémon: Pika-Pikachu"` → `"pokemon pika pikachu"`, `"Extreme Maßnahmen (7)"` → `"extreme massnahmen"`), `autoMatchUniqueExact`, `autoMatchAmbiguousIsNil` (two results both „Monster“ → nil), `autoMatchOriginalName`, `autoMatchNoExactIsNil` (only „DAHMER – Monster: Die Geschichte von Jeffrey Dahmer“ vs candidate without dash → matches after normalization; vs „Dahmer“ → nil), `episodeExact`, `episodeSuffixNumberIgnored` („Extreme Maßnahmen (7)“ ↔ „Extreme Maßnahmen“), `episodeFolgeN` (season 1 pool, „Folge 2“ → E2), `episodeWithoutSeasonSearchesAll`, `doubleEpisode` („Das, was du zurücklässt – Teil 1 und 2“ ↔ „Das, was du zurücklässt (1)“ and „(2)“ → both), `fuzzyTypo` („Die Geister die wir riefen“ ↔ „Die Geister, die wir riefen“), `fuzzyAmbiguousIsEmpty` (two near-equal names → `[]`), `noMatchIsEmpty`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: title normalization and matching`.

---

### Task 14: Import ingest, import models, upload, discarding rows

**Files:**
- Create: `Sources/App/Import/NetflixImport.swift`, `Import/NetflixRow.swift`, `Import/NetflixMapping.swift`, `Import/ImportMigrations.swift`, `Import/ImportService.swift`, `Import/ImportController.swift`, `Web/Pages/ImportPage.swift`
- Modify: `Tracking/WatchService.swift` (`unmarkEpisode`, `unmarkMovie`, `deleteWatch` set linked rows to `discarded`), `routes.swift`, `configure.swift`
- Test: `Tests/AppTests/ImportIngestTests.swift`, extend `WatchServiceTests.swift`

**Interfaces:**
- Consumes: `parseNetflixCSV`, `parseNetflixTitle` (Tasks 11–12), `WatchService` (Task 7).
- Produces:

```swift
enum RowStatus: String, Codable, Sendable { case pending, matched, unmatched, ignored, discarded }
enum MappingStatus: String, Codable, Sendable { case pending, auto, confirmed, review, ignored }
// NetflixImport (netflix_imports): user_id, uploaded_at, filename, total_rows, new_rows, known_rows, skipped_rows
// NetflixRow (netflix_rows): user_id, import_id (cascade), raw_title, watched_on, fingerprint, parsed_kind ("episode"/"movie"),
//   show_name?, season_number?, episode_title?, status, mapping_id? (→ netflix_mappings, setNull), watch_id? (→ watches, setNull);
//   unique (user_id, fingerprint)
// NetflixMapping (netflix_mappings): user_id, netflix_name, kind, title_id? (→ titles), status, candidates: String? (JSON [TMDBSearchResult]);
//   unique (user_id, netflix_name, kind)
struct ImportSummary: Sendable, Equatable { let total: Int; let new: Int; let known: Int; let skipped: Int }
struct ImportService { let db: any Database
    func ingest(text: String, filename: String, userID: UUID) async throws -> ImportSummary }   // one transaction, inserts in chunks of 500
```

  - Routes: `GET /import` (upload section now; Task 16 adds the rest), `POST /import` (multipart field `file`, route body `.collect(maxSize: "10mb")`, strips BOM, requires valid UTF-8). Success → page with „N neu, M bereits bekannt, K übersprungen (leerer Titel)“. `NetflixCSVError.notNetflixHistory` → 422 „Das ist keine Netflix-Wiedergabeaktivität (erwartet wird die Kopfzeile „Title,Date“).“; `.invalidDate(l, v)` → 422 „Zeile l: ungültiges Datum „v“.“; nothing stored on error.

- [ ] **Step 1: Write failing tests** – `ingestFixture` (summary total 21 rows read → `new == 19`, `skipped == 2`, `known == 0`; rows `pending`, parsed fields stored e.g. DS9 row `show_name == "Star Trek: Deep Space Nine"`, `season_number == 7`), `reimportIsIdempotent` (second ingest → `new == 0`, `known == 19`, still 19 rows), `fingerprintsArePerUser` (user B ingesting the same file → `new == 19`), `wrongFileStoresNothing` (Review Focus 2; zero rows and zero imports after `.notNetflixHistory`), `uploadViaHTTP` (multipart POST → body contains „19 neu, 0 bereits bekannt, 2 übersprungen“), `uploadWrongFile422`, `deletingImportedWatchDiscardsRow` (row linked to a watch → `deleteWatch` → row `discarded`; re-ingest → still `discarded`, no new watch).
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: Netflix import ingest and upload`.

---

### Task 15: Matching worker

**Files:**
- Create: `Sources/App/Import/MatchingWorker.swift`
- Modify: `Tracking/WatchService.swift` (add `recordImportedWatch`), `Config/Application+Services.swift` (`app.matchingWorker`), `configure.swift` (lifecycle: kick on boot when `backgroundJobsEnabled`), `Import/ImportController.swift` (kick after successful upload)
- Test: `Tests/AppTests/MatchingWorkerTests.swift`

**Interfaces:**
- Consumes: `CatalogService`, `TMDBClient`, `autoMatch`, `matchEpisodes`, import models.
- Produces:

```swift
extension WatchService {
    func recordImportedWatch(userID: UUID, titleID: UUID, episodeID: UUID?, day: String) async throws -> Watch }
struct MatchingRunResult: Sendable, Equatable { var matched: Int; var unmatched: Int; var awaitingReview: Int }
actor MatchingWorker {
    init(db: any Database, tmdb: any TMDBClient, logger: Logger, enabled: Bool)
    func kick()                                   // no-op when disabled; starts processAll() in a Task if idle, else flags a rerun
    func processAll() async throws -> MatchingRunResult
    var isRunning: Bool { get }
    var lastError: String? { get }
}
```

`recordImportedWatch` (§6.2 step 5): look for the user's watch on the same episode (or movie: `episode_id` nil, same title) with origin `manual`, service `netflix` or nil, and either `watched_on` within ±1 day of `day` (prefer smallest distance) or `watched_on` nil (then set it to `day`); return it if found, else insert a new watch (origin `import`, service `netflix`, `watched_on = day`). Always ensures a user_title (does **not** unhide).

`processAll` loop, repeated until a pass changes nothing:
1. Load pending rows (all users) without `mapping_id`. Mapping key per row: `.movie` → (`raw_title`, movie); `.episode` with season nil and exactly one row of this user with that `show_name` → movie fallback (`raw_title`, movie) first, falling back to (`show_name`, tv) if the movie mapping ends in `review`; otherwise (`show_name`, tv). Get-or-create the user's mapping (status `pending`) and set `mapping_id`.
2. For each mapping in `pending`: `tmdb.search(name, kind:)`; `autoMatch` hit → `catalog.title(kind:tmdbID:)`, status `auto`; else status `review`, `candidates` = top 5 as JSON. Each name is searched once per user (mappings persist across imports).
3. Rows whose mapping is `ignored` → `ignored`. Rows whose mapping is `review` stay `pending` (counted in `awaitingReview`).
4. Rows whose mapping is `auto`/`confirmed`: movie → `recordImportedWatch(episodeID: nil)`; episode → `matchEpisodes(episode_title, season, catalog episodes)`: non-empty → one `recordImportedWatch` per ID, row `matched`, `watch_id` = first; empty → `unmatched`.
5. Any `TMDBError` aborts the run: set `lastError = "TMDB nicht erreichbar: <error>"`, leave affected rows `pending`, return; a later `kick` retries. A successful run clears `lastError`.

- [ ] **Step 1: Write failing tests** (fake TMDB: search `tv:The Mentalist` → one exact result 1001 with seasons [1, 4] and episode names from the fixture; ingest via `ImportService`; call `processAll()` directly):
  - `autoMatchedSeriesCreatesWatches` (Mentalist rows matched, watches origin `import`, service `netflix`, `watched_on` from CSV).
  - `ambiguousShowGoesToReview` (search returns two „Monster“ results → mapping `review`, 5-or-fewer candidates stored, rows `pending`, `awaitingReview > 0`).
  - `ignoredMappingIgnoresRows`.
  - `unknownEpisodeUnmatched`.
  - `mergesWithManualWatchWithinOneDay` (manual watch netflix 2026-11-06 on same episode → no new watch, row linked to it).
  - `doesNotMergeOtherService` (manual `disney_plus` same day → second watch).
  - `undatedManualWatchTakesCSVDate`.
  - `singleRowMovieFallback` (row `Mission: Impossible – Dead Reckoning` alone; fake movie search exact → movie watch).
  - `tmdbFailureKeepsRowsPending` (Review Focus 3; `failure = .unauthorized` → rows `pending`, `lastError` starts with „TMDB nicht erreichbar“; clear failure, `processAll` again → matched).
  - `mappingsReusedAcrossImports` (second import of a new Mentalist row → no new `search:` call in the fake log).
  - `restartRecovery` (new worker instance processes leftover pending rows).
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: background matching of imported rows`.

---

### Task 16: Import page – review, unmatched rows, mappings

**Files:**
- Create: `Sources/App/Import/MappingService.swift`, `Web/Components/ImportProgress.swift`, `Web/Components/MappingReviewItem.swift`, `Web/Components/UnmatchedRowItem.swift`, `Web/Components/MappingListItem.swift`
- Modify: `Import/ImportController.swift`, `Web/Pages/ImportPage.swift`
- Test: `Tests/AppTests/ImportPageTests.swift`

**Interfaces:**
- Consumes: `MatchingWorker`, `WatchService.recordImportedWatch`, import models.
- Produces:

```swift
struct MappingService { let db: any Database; let catalog: CatalogService; let watches: WatchService
    func accept(userID: UUID, mappingID: UUID, kind: TitleKind, tmdbID: Int) async throws     // confirmed + title; its non-discarded rows → pending
    func ignore(userID: UUID, mappingID: UUID) async throws                                 // ignored; its pending/unmatched rows → ignored
    func reset(userID: UUID, mappingID: UUID) async throws    // delete origin-import watches linked from its rows (unlink manual ones), rows (not discarded) → pending, mapping → pending, title nil
    func change(userID: UUID, mappingID: UUID, kind: TitleKind, tmdbID: Int) async throws    // reset + accept
    func assignRow(userID: UUID, rowID: UUID, episodeID: UUID) async throws                // recordImportedWatch, row matched
    func ignoreRow(userID: UUID, rowID: UUID) async throws }
```

  - Routes: `GET /import` – four sections (§5.9): „Upload“, „Zu prüfen“ (mapping name, row count, candidates with poster/year, own search box `GET /import/mappings/:id/search?q=` → candidate list fragment, buttons „Übernehmen“/„Ignorieren“), „Nicht zugeordnet“ (raw title, date, episode `<select>` grouped by season of the mapped show, „Zuordnen“/„Ignorieren“), „Zuordnungen“ (all mappings with status label „automatisch“/„bestätigt“/„ignoriert“, filter by status, „Ändern“ opening the search, „Zurücksetzen“). `GET /import/progress` → `ImportProgress` fragment: while running „Zuordnung läuft …“ plus `hx-trigger="every 2s"` self-refresh; otherwise counts „N Zeilen warten auf Prüfung“ and `lastError` if set (no polling attribute).
  - `POST /import/mappings/:id/accept` (`kind`, `tmdbID`), `/ignore`, `/reset`, `/change` (`kind`, `tmdbID`); `POST /import/rows/:id/assign` (`episodeID`), `POST /import/rows/:id/ignore`. Accept/change/reset kick the worker. Foreign IDs → 404.

- [ ] **Step 1: Write failing tests** – `acceptMatchesRows` (review mapping → accept → `processAll` → rows matched), `ignoreMapping`, `resetKeepsMergedManualWatch` (one row merged into a manual watch, one created a new import watch → reset deletes only the import watch, manual remains, rows pending), `changeRematchesToOtherTitle`, `assignUnmatchedRow`, `foreignMappingIs404`, `progressShowsWaitingCount` („2 Zeilen warten auf Prüfung“), `progressShowsTMDBError`, `progressPollsOnlyWhileRunning`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: import review, unmatched rows and mapping management`.

---

### Task 17: Daily TMDB refresh

**Files:**
- Create: `Sources/App/Catalog/DailyRefresh.swift`
- Modify: `configure.swift` (register lifecycle when `backgroundJobsEnabled`)
- Test: `Tests/AppTests/DailyRefreshTests.swift`

**Interfaces:**
- Consumes: `CatalogService`, `UserTitle`.
- Produces: `func seriesDueForRefresh(on db: any Database) async throws -> [Title]` – tv titles with ≥ 1 user_title where `hidden == false`, and `tmdb_status` not in `["Ended", "Canceled"]`; `struct DailyRefreshLifecycle: LifecycleHandler` – on boot starts a Task: wait 60 s, then refresh each due series sequentially (errors logged, loop continues), sleep 24 h, repeat; cancelled in `shutdownAsync`.

- [ ] **Step 1: Write failing tests** – `dueWhenInLibraryAndVisible`, `notDueWhenHiddenByEveryone`, `dueWhenHiddenByOneVisibleForAnother`, `notDueWhenEnded`, `moviesNeverDue`, `notDueWhenInNoLibrary`.
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: daily TMDB refresh`.

---

### Task 18: Cross-user isolation and account deletion suite

**Files:**
- Test: `Tests/AppTests/IsolationTests.swift`
- Modify: any controller/service a failing test exposes

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Write tests** (users A and B, A has watches, rating, hidden series, import with mappings and unmatched rows):
  - `historyOnlyShowsOwnWatches`, `continueOnlyShowsOwnCards`, `libraryOnlyShowsOwnTitles`, `seriesPageShowsOwnRatingAndChecks` (B sees no „★“ value and unchecked episodes on the same series), `importPageOnlyShowsOwnMappings`, `foreignIDsAre404` (B: `DELETE /watches/<A>`, `POST /watches/<A>`, `POST /import/mappings/<A>/accept`, `POST /import/rows/<A>/ignore` → 404), `deletingUserRemovesAllTheirData` (admin deletes A → zero rows for A in `watches`, `user_titles`, `netflix_imports`, `netflix_rows`, `netflix_mappings`; `titles`/`episodes` remain), `nonAdminCannotReachAdmin`.
- [ ] **Step 2:** Run `swift test` → fix whatever fails, re-run → PASS.
- [ ] **Step 3:** Commit `test: cross-user isolation suite`.

---

### Task 19: Docker image, compose, GitHub Action, README

**Files:**
- Create: `Dockerfile`, `.dockerignore`, `docker-compose.yml`, `.github/workflows/docker.yml`, `README.md`

**Interfaces:**
- Consumes: the finished app.
- Produces:
  - `Dockerfile`: multi-stage, build on `swift:6.4-noble` (verify the tag exists on Docker Hub; otherwise the newest `swift:6.x-noble`), `swift build -c release --static-swift-stdlib`, copy `Public/` next to the binary; runtime `ubuntu:noble` with `ca-certificates` and `tzdata`, non-root user, `WORKDIR /app`, `VOLUME /data`, `EXPOSE 8080`, `ENTRYPOINT ["./App"]`, `CMD ["serve", "--env", "production"]`.
  - `docker-compose.yml`: service `watchswifty`, image `ghcr.io/<owner>/watchswifty:latest`, `ports: ["8080:8080"]`, env `TMDB_TOKEN`, `ADMIN_USERNAME`, `ADMIN_PASSWORD`, `TZ=Europe/Berlin`, volume `watchswifty-data:/data`, `restart: unless-stopped`.
  - `.github/workflows/docker.yml`: on push to `main` and tags `v*`; job `test` in container `swift:6.4-noble` running `swift test`; job `image` (needs `test`, `permissions: packages: write, contents: read`): `docker/setup-buildx-action`, `docker/login-action` (ghcr.io, `${{ github.actor }}`, `${{ secrets.GITHUB_TOKEN }}`), `docker/metadata-action` (tags: `latest` on main, `sha`, semver from tags), `docker/build-push-action` with `platforms: linux/amd64`, `push: true`, `cache-from/to: type=gha`.
  - `README.md` (German): what it is, start with compose, env table (§9), first login with the admin vars, how to download the Netflix CSV (Profil → Konto → Wiedergabeaktivität → „Alle herunterladen“), import flow, backup = copy the SQLite file from the volume, reverse proxy note for access outside the home network.

- [ ] **Step 1:** `docker build -t watchswifty:dev .` → succeeds.
- [ ] **Step 2:** Run: `docker run --rm -d --name ws -p 8080:8080 -e TMDB_TOKEN=dummy -e ADMIN_USERNAME=admin -e ADMIN_PASSWORD=changeme123 watchswifty:dev`, then `curl -fsS localhost:8080/healthz` → `ok`; `curl -sI localhost:8080/` → `303` with `location: /login`; `docker stop ws`.
- [ ] **Step 3:** Run without `TMDB_TOKEN` → container exits non-zero, logs „Fehlende Umgebungsvariable: TMDB_TOKEN“.
- [ ] **Step 4:** Lint the workflow with `actionlint` if available (`brew install actionlint` only with the user's consent); otherwise review by eye.
- [ ] **Step 5:** Commit `build: Docker image, compose file and CI workflow`.

---

### Task 20: Acceptance run with the real export

Needs a real TMDB read access token from the user (never committed, passed via env only).

- [ ] **Step 1:** Start locally: `TMDB_TOKEN=<token> DATABASE_PATH=<scratch>/accept.sqlite ADMIN_USERNAME=admin ADMIN_PASSWORD=<pw> swift run App serve`.
- [ ] **Step 2:** Log in, upload `/Users/patrickmeindl/Downloads/NetflixViewingHistory.csv` on `/import`. Expect „4268 neu, 0 bereits bekannt, 127 übersprungen (leerer Titel)“ (4,395 data rows minus 127 blank).
- [ ] **Step 3:** Wait until the progress fragment stops polling. Record with `sqlite3 <scratch>/accept.sqlite "select status, count(*) from netflix_rows group by status; select status, count(*) from netflix_mappings group by status;"`. Expectation: no error; most `Staffel N` rows `matched`; remaining names visible under „Zu prüfen“, rows under „Nicht zugeordnet“.
- [ ] **Step 4:** Upload the same file again → „0 neu, 4268 bereits bekannt, 127 übersprungen (leerer Titel)“; row and watch counts unchanged.
- [ ] **Step 5:** Open `/` → „The Mentalist“ card shows a next episode in Staffel 4 and „zuletzt auf Netflix“, dated 07.11.2026.
- [ ] **Step 6:** Report the numbers from Step 3 to the user; spot-check five auto-matched series for wrong matches (anti-goal). Do not commit the database or the CSV.
