# Einzelne Sichtungen löschen – Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete one chosen viewing of an episode or movie from where it is shown; the episode checkbox becomes a
green check (watched) or a clickable circle (mark as watched).

**Architecture:** One new `WatchService` method deletes a single watch that belongs to the user and to the given
title/episode. Two new web routes call it and re-render the season section or the movie's „Gesehen“ section. A shared
`WatchList` component lists the viewings with a „Löschen“ button each.

**Tech Stack:** Swift 6.3, Vapor 4, Fluent/SQLite, Elementary + htmx, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-13-single-watch-delete-design.md`

## Global Constraints

- UI text German, verbatim: „Löschen“, „Diese Sichtung löschen?“, „ohne Datum“ (via `watchSummary`), „gesehen“.
- Another user's watch, or a watch of another episode/movie, yields 404 (`TrackingError.notFound`).
- Deleting marks linked Netflix rows `discarded` (reuse `deleteDiscardingRows`).
- App API unchanged (`unmarkEpisode`/`unmarkMovie`/`deleteWatch` in `WatchService` stay).

## Review Focus

- Stale click (watch already deleted in another tab): 404 into `#flash`, page stays usable – Task 2 test.
- Undated viewings („Ganze Staffel gesehen“) appear as „ohne Datum“ with their own „Löschen“ – Task 2 test.
- Deleting the last viewing turns the row back into a clickable circle – Task 2 test.
- Not yet aired episodes show a circle that cannot be clicked – Task 2 test.
- Imported Netflix viewing deleted → its row is `discarded` – Task 1 test.

---

### Task 1: `WatchService.deleteWatch(userID:watchID:titleID:episodeID:)`

**Files:**
- Modify: `Sources/App/Tracking/WatchService.swift` (section „Single watches“)
- Test: `Tests/AppTests/SingleWatchDeleteTests.swift` (new suite `SingleWatchDelete`)

**Interfaces:**
- Produces: `func deleteWatch(userID: UUID, watchID: UUID, titleID: UUID, episodeID: UUID?) async throws` –
  `episodeID == nil` means a movie watch (its `episode_id` must be NULL). Throws `TrackingError.notFound` unless the
  watch is the user's and matches title and episode.

- [ ] **Step 1: Write the failing tests**
  - `deletesOnlyTheChosenWatch`: two watches of one episode (`markEpisode` day "2026-11-01", then
    `markEpisode(..., rewatch: true)` day "2026-11-05"); delete the first → `#expect(remaining.map(\.watchedOn) == ["2026-11-05"])`.
  - `watchOfAnotherEpisodeIsNotFound`: watch of 1x1, call with episode 1x2 → `#expect(throws: TrackingError.notFound)`,
    watch still exists. Same for a movie watch passed with an `episodeID`.
  - `deletingDiscardsLinkedNetflixRows`: modeled on `ImportIngestTests.unmarkEpisodeDiscardsLinkedRows`, using
    `deleteWatch` → linked row status `discarded`.
- [ ] **Step 2: Run** `swift test --filter SingleWatchDelete` – expect compile failure (method missing).
- [ ] **Step 3: Implement** via `ownWatch`, compare `$title.id` and `$episode.id`, then `deleteDiscardingRows` on the id.
- [ ] **Step 4: Run** `swift test --filter SingleWatchDelete` – PASS.
- [ ] **Step 5: Commit** `feat(tracking): delete a single watch of a given episode or movie`

### Task 2: Episode row – check/circle, viewing list, delete route

**Files:**
- Create: `Sources/App/Web/Components/WatchList.swift`
- Modify: `Sources/App/Web/Components/SeasonSection.swift` (`EpisodeRow`), `Sources/App/Tracking/TitleController.swift`
  (routes, remove `unmarkEpisode` handler), `Public/css/app.css` (replace `.episode-row > input[type=checkbox]`)
- Test: `Tests/AppTests/TitlePagesTests.swift` (replace `unmarkEpisode`), `Tests/AppTests/IsolationTests.swift`

**Interfaces:**
- Consumes: Task 1 `deleteWatch`.
- Produces: `struct WatchList: HTML { let watches: [Watch]; let deletePath: @Sendable (UUID) -> String; let target: String }`
  – `ul.watch-list`, one `li` per watch: `watchSummary([watch])` and
  `button(.hx.delete(deletePath(id)), .hx.confirm("Diese Sichtung löschen?"), .hx.target(target), .hx.swap(.outerHTMLGuarded)) { "Löschen" }`.
- Route `DELETE /tv/:tmdbID/episodes/:season/:number/watches/:watchID` → `deleteEpisodeWatch`, answers
  `seasonResponse(..., openEpisode: episode.number)`. `DELETE /tv/:tmdbID/episodes/:season/:number/watch` is removed.

- [ ] **Step 1: Write the failing tests** (TitlePagesTests, `withUser`):
  - `deleteOneEpisodeWatch`: POST `/tv/1399/episodes/1/1/watch`, POST again with `rewatch: "true"`; DELETE
    `/tv/1399/episodes/1/1/watches/<newest id>` → 200, body contains `Staffel 1 · 1/2 gesehen` and
    `class="watched-mark"`; DELETE the other → `Staffel 1 · 0/2 gesehen` and
    `hx-post="/tv/1399/episodes/1/1/watch"` (circle back); `userWatches` empty.
  - `staleWatchDeleteIs404`: DELETE the same id twice → second `.notFound`.
  - `oldUnmarkRouteIsGone`: DELETE `/tv/1399/episodes/1/1/watch` → `.notFound`.
  - `episodeRowShowsCheckCircleAndList`: mark 1x1 via season form (undated); GET `/tv/1399` → no `type="checkbox"`
    inside `episode-row`s, contains `class="watched-mark"`, `aria-label="S01E02 als gesehen markieren"`,
    `ohne Datum`, `hx-delete="/tv/1399/episodes/1/1/watches/`, `hx-confirm="Diese Sichtung löschen?"`; season 2
    episodes (unaired in the fake? if not, seed a series with `unaired`) show `class="watch-mark unaired"` without `hx-post`.
  - IsolationTests `foreignIDsAre404`: Bob DELETE `/tv/1/episodes/1/1/watches/<aliceWatch>` → `.notFound`.
- [ ] **Step 2: Run** `swift test --filter "TitlePages|Isolation"` – new tests FAIL.
- [ ] **Step 3: Implement** `WatchList`; `EpisodeRow` left marker:
  watched → `span(.class("watched-mark"), role "img", aria-label "gesehen") { "✓" }`;
  aired, unwatched → `button(.type(.button), .class("watch-mark"), hx-post "\(path)/watch", aria-label "<code> als gesehen markieren")`
  (same target/swap as the old checkbox); unaired → `span(.class("watch-mark unaired"), aria-label "<code> noch nicht erschienen")`.
  In the details panel, before the `WatchForm`, `WatchList(watches: model.watches, deletePath: { "\(path)/watches/\($0)" }, target: target)`
  when watched. Route + handler; remove the old route and handler.
  CSS: `.watch-mark` 1.1rem circle (2px `--ink-3` border, transparent, pointer, hover/focus border `--ok`),
  `.watch-mark.unaired` opacity 0.4 and default cursor, `.watched-mark` `--ok` bold check of the same box size,
  `.watch-list` compact rows (summary left, button right, `--text-sm`).
- [ ] **Step 4: Run** `swift test` – all PASS.
- [ ] **Step 5: Commit** `feat(series): green check instead of a checkbox, delete single viewings in the episode details`

### Task 3: Movie page – viewing list with delete, no „Nicht gesehen“

**Files:**
- Modify: `Sources/App/Web/Pages/MoviePage.swift` (`MovieWatchesSection`), `Sources/App/Tracking/TitleController.swift`
- Test: `Tests/AppTests/TitlePagesTests.swift` (`movieWatchedInCinema`)

**Interfaces:**
- Consumes: Task 1 `deleteWatch` (with `episodeID: nil`), Task 2 `WatchList`.
- Route `DELETE /movie/:tmdbID/watches/:watchID` → `deleteMovieWatch`, answers `MovieWatchesSection` with
  `movieWatches(...)`. `DELETE /movie/:tmdbID/watch` and its handler are removed.

- [ ] **Step 1: Update the test** `movieWatchedInCinema`: instead of DELETE `/movie/603/watch`, DELETE
  `/movie/603/watches/<id>` → 200, body lacks `01.11.2026`, contains `Noch nicht gesehen.`; before that, GET
  `/movie/603` contains `hx-delete="/movie/603/watches/` and not `>Nicht gesehen<`. Add `oldMovieUnmarkRouteIsGone`
  (DELETE `/movie/603/watch` → `.notFound`).
- [ ] **Step 2: Run** `swift test --filter TitlePages` – FAIL.
- [ ] **Step 3: Implement**: `MovieWatchesSection` renders `WatchList(watches:, deletePath: { "/movie/\(tmdbID)/watches/\($0)" }, target: "#movie-watches")`
  instead of the plain `ul`; drop the „Nicht gesehen“ button; route + handler; remove the old route.
- [ ] **Step 4: Run** `swift test` – all PASS.
- [ ] **Step 5: Commit** `feat(movies): delete single viewings on the movie page`

### Task 4: Check in the browser

- [ ] Run the dev server, open a series and a movie: circle marks, check shows, list deletes one viewing after the
  confirm, last deletion brings the circle back; check a phone width (375 px).
- [ ] CHANGELOG entry goes into the release section when the PR is opened (`### Changed`).
