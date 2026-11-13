# TMDB Refresh of the Whole Library – Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every user can reload all their series and movies from TMDB with one button under **Konto**, in the background with visible progress; the App API can start and read the same run.

**Architecture:** A `LibraryRefreshWorker` actor in `Application.storage` holds one task and one progress state per user. It walks the user's titles with the user's own TMDB token through `CatalogService.refresh`, like the daily pass. The Konto page shows a fragment that htmx polls every 2 s; the API exposes start and status.

**Tech Stack:** Swift 6.3, Vapor 4, Fluent/SQLite, Elementary + htmx, swift-openapi-generator, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-13-tmdb-refresh-design.md`

## Global Constraints

- UI texts German, verbatim: button „Alle Daten von TMDB neu laden“; running „Lädt neu … {done} von {total}“; finished „Fertig: {done - failed} Titel neu geladen, {failed} fehlgeschlagen“ (without the failed part when 0) with link „Zur Bibliothek“ (`/library`); missing token „Kein TMDB-Token hinterlegt – bitte unter Konto eintragen.“ (`TMDBError.missingToken.description`).
- Code identifiers and comments English; `ExistentialAny`, `MemberImportVisibility` (import every module a file uses).
- No new table, no migration, no new env var. Progress lives in memory only.
- Titles of a user = every title with a `watches` row or a `user_titles` row of that user (watched, rated, hidden, followed), series and movies, TMDB status ignored. Order: titles with `runtime == nil || genres == nil` first, then the rest; within each group by `tmdbID`.
- One run per user at a time; a start while running returns the running state.
- Polling interval: `every 2s` (as import and film list).

## Review Focus

1. Empty library: the run finishes at once with `total 0` and shows „Fertig: 0 Titel neu geladen“ – test in Task 1.
2. Polling `GET` when no run ever started: returns the idle fragment with the button, not an error – test in Task 2.
3. Two tabs click at once: still one run, each title fetched once – test in Task 1 (`secondStartWhileRunningKeepsOneRun`).
4. Another user's run is never visible (web fragment and API) – test in Task 3.
5. Token turns invalid during the run (401): the run stops, shows the TMDB message, button is back – test in Task 1.

---

### Task 1: Worker and title selection

**Files:**
- Create: `Sources/App/Catalog/LibraryRefresh.swift`
- Modify: `Sources/App/configure.swift` (create the worker next to `filmListWorker`; register `LibraryRefreshLifecycle` unconditionally, it only cancels on shutdown)
- Modify: `Tests/AppTests/Support/FakeTMDBClient.swift` (optional `delay: Duration?`, applied in `record`, like `FakeMailSender.delay`)
- Test: `Tests/AppTests/LibraryRefreshTests.swift`

**Interfaces:**
- Produces:
  - `struct LibraryRefreshState: Sendable, Equatable { var running: Bool; var done: Int; var total: Int; var failed: Int; var finishedAt: Date?; var error: String? }` with `static let idle` (all zero, not running, nils) and `var refreshed: Int { done - failed }`.
  - `func libraryRefreshTitles(userID: UUID, on db: any Database) async throws -> [Title]` (selection and order from Global Constraints).
  - `actor LibraryRefreshWorker` — `init(db: any Database, provider: TMDBProvider, logger: Logger, matching: MatchingWorker)`; `func start(userID: UUID, token: String) async throws -> LibraryRefreshState`; `func state(userID: UUID) -> LibraryRefreshState` (`.idle` when none); `func wait(userID: UUID) async` (tests); `func cancelAll()`.
  - `Application.libraryRefresh: LibraryRefreshWorker` (storage accessor like `matchingWorker`).
  - `struct LibraryRefreshLifecycle: LifecycleHandler` (`shutdownAsync` → `cancelAll()`).
- Run per title: `CatalogService(db:tmdb: provider.make(token)).refresh(title)`; for series also `requeueUnmatchedRows(titleID:on:)`; `done += 1` per title, `failed += 1` on any error except `TMDBError.unauthorized`, which sets `error = TMDBError.unauthorized.description` and stops. Stop on `Task.isCancelled`. At the end `running = false`, `finishedAt = .now`; if any rows were requeued, `await matching.kick()`. `start` sets `running = true` and `total` before returning.

- [ ] **Step 1: Write the failing tests** in `LibraryRefreshTests` (`@Suite("LibraryRefresh")`):
  - `titlesCoverOwnSeriesAndMoviesOnly` — user A: watched series 1, hidden movie 2, followed-only series 3, series 4 with `genres` set; user B: series 5. `libraryRefreshTitles(A)` → tmdbIDs `[1, 2, 3, 4]` with 4 last (1–3 lack genres); B's 5 absent.
  - `refreshLoadsEveryTitleAndReportsProgress` — fake registers series 1 and movie 2 with genres; `start` → `wait` → state `running == false`, `done == 2`, `total == 2`, `failed == 0`, `finishedAt != nil`; `fake.calls` contains `"series:1"` and `"movie:2"`; both titles have `genres != nil`.
  - `emptyLibraryFinishesAtOnce` — `start` for a user without titles → after `wait`: `total == 0`, `running == false`, `finishedAt != nil`.
  - `failedTitleIsCountedAndRunContinues` — movie 2 not registered in the fake (→ `notFound`): `done == 2`, `failed == 1`, `error == nil`.
  - `invalidTokenStopsTheRun` — `fake.failure = .unauthorized`: `running == false`, `error == TMDBError.unauthorized.description`, `done == 0`.
  - `secondStartWhileRunningKeepsOneRun` — `fake.delay = .milliseconds(100)`, two titles; `start` twice back to back; second result `running == true`; after `wait` each `"series:…"`/`"movie:…"` call appears once.
- [ ] **Step 2:** `swift test --filter LibraryRefreshTests` → fails to compile (`libraryRefreshTitles` not defined).
- [ ] **Step 3:** Implement the interfaces above in `LibraryRefresh.swift` and wire them in `configure.swift`.
- [ ] **Step 4:** `swift test --filter LibraryRefreshTests` → all pass.
- [ ] **Step 5:** Commit `feat(catalog): reload all of a user's titles from TMDB in the background`.

### Task 2: Konto button and progress

**Files:**
- Create: `Sources/App/Web/Components/LibraryRefreshStatus.swift`
- Modify: `Sources/App/Account/AccountController.swift` (routes, `page` passes the state), `Sources/App/Web/Pages/AccountPage.swift` (TMDB block), `Public/css/app.css` if spacing needs it
- Test: `Tests/AppTests/AccountRefreshTests.swift`

**Interfaces:**
- Consumes: `LibraryRefreshWorker.start/state`, `LibraryRefreshState` (Task 1); `req.tmdbToken`.
- Produces:
  - `POST /account/tmdb-refresh` (protected): without token → htmx: fragment with the missing-token error (status 422), else full page `open: .tmdb` with that error; with token → `start`, htmx: fragment, else full page `open: .tmdb`.
  - `GET /account/tmdb-refresh` (protected): fragment for the current state.
  - `struct LibraryRefreshStatus: HTML { let state: LibraryRefreshState }` — root `div#library-refresh`; while running it carries `hx-get="/account/tmdb-refresh"`, `hx-trigger="every 2s"`, `hx-swap="outerHTML"` and the running text; otherwise the finished line (when `finishedAt != nil`), the error (`p.error`) if any, the sentence „Lädt alle deine Serien und Filme mit diesem Token neu von TMDB.“ and a `form method=post action=/account/tmdb-refresh` with `hx-post`, `hx-target="#library-refresh"`, `hx-swap="outerHTML"` and the button.
  - `AccountPage.libraryRefresh: LibraryRefreshState?` — rendered in the „TMDB-Token“ block below the token forms only when a token is stored (`tokenSuffix != nil`).

- [ ] **Step 1: Write the failing tests:**
  - `tokenBlockShowsRefreshButtonOnlyWithToken` — GET `/account` with token contains „Alle Daten von TMDB neu laden“; user with `tmdbToken: nil` does not.
  - `idlePollShowsButton` — GET `/account/tmdb-refresh` with no run → 200, contains `id="library-refresh"` and the button, no `every 2s`.
  - `startShowsProgressThenResult` — seed one watched series (fake registers it), `fake.delay = .milliseconds(100)`; POST `/account/tmdb-refresh` with `.htmx` + session → body contains „Lädt neu … 0 von 1“ and `hx-trigger="every 2s"`; `await app.libraryRefresh.wait(userID:)`; GET → „Fertig: 1 Titel neu geladen“ and `href="/library"`.
  - `startWithoutTokenShowsError` — user without token, POST htmx → 422, body contains „Kein TMDB-Token hinterlegt – bitte unter Konto eintragen.“, `fake.calls` empty.
- [ ] **Step 2:** `swift test --filter AccountRefreshTests` → fails.
- [ ] **Step 3:** Implement routes, component and page change.
- [ ] **Step 4:** `swift test --filter AccountRefreshTests` → pass.
- [ ] **Step 5:** Commit `feat(account): button to reload all data from TMDB, with progress`.

### Task 3: App API

**Files:**
- Modify: `Sources/WatchSwiftyAPI/openapi.yaml`, `Sources/App/API/APIHandler+Library.swift`
- Test: `Tests/AppTests/APILibraryRefreshTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces: path `/v1/library/refresh` (tag `Library`, `bearerAuth`): `post` `startLibraryRefresh` → `202` `LibraryRefresh` (422 `missingTMDBToken` via the existing `TMDBError` mapping); `get` `getLibraryRefresh` → `200` `LibraryRefresh`. Schema `LibraryRefresh`: required `running` (bool), `done`, `total`, `failed` (int); optional `finishedAt` (date-time), `error` (string). English descriptions; mention that the run uses the caller's TMDB token and progress is lost on a server restart.

- [ ] **Step 1: Write the failing tests:**
  - `startAndPoll` — POST with bearer → 202, `total == 1`; after `wait` GET → `running == false`, `done == 1`, `finishedAt != nil`.
  - `startWithoutTokenIs422` — user with `tmdbToken: nil` → 422, code `missingTMDBToken`.
  - `otherUsersRunIsInvisible` — A starts; B's GET → `running == false`, `total == 0`; B's web GET `/account/tmdb-refresh` shows the idle fragment.
- [ ] **Step 2:** `swift test --filter APILibraryRefreshTests` → fails to compile.
- [ ] **Step 3:** Add the spec, implement both operations in `APIHandler+Library.swift`.
- [ ] **Step 4:** `swift test --filter APILibraryRefreshTests` → pass.
- [ ] **Step 5:** Commit `feat(api): start and read the TMDB refresh of the library`.

### Task 4: Docs and release 0.6.0

**Files:**
- Modify: `VERSION` (`0.6.0`), `CHANGELOG.md` (section `0.5.1` becomes `## [0.6.0] – 2026-11-13` with `### Added` (button, API) above the existing `### Fixed`, plus `### Changed`: episode titles on the series page no longer underlined, more space between episodes), `docs/tmdb.md` (cached data: manual reload under **Konto**), `docs/app-api.md` (scope line mentions the reload).

- [ ] **Step 1:** Edit the files.
- [ ] **Step 2:** `sh scripts/release-notes.sh 0.6.0 | head -3` → starts with `### Added`; `sh scripts/next-version.sh` → `0.6.0`.
- [ ] **Step 3:** `swift test` → all pass.
- [ ] **Step 4:** Commit `docs: release 0.6.0 – reload from TMDB, update notice fix`.
