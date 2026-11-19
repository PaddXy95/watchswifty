# Standard-Import (CSV) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the private film list import with an open CSV format for movies, episodes and series (web UI, App API, iOS app).

**Architecture:** A pure parser turns the CSV into rows and groups them into one draft per title. Drafts are stored as
`import_entries`. A background worker (`ImportWorker`) matches each entry to TMDB: first by ID (with a plausibility
check), then by title and year. `StandardImporter.record` then creates the viewings, using the existing duplicate
protection. The web UI and the API call the same `ImportEntryService` / `StandardImporter`. The old film list code is
removed once the new path is complete.

**Tech Stack:** Swift 6.3, Vapor 4, Fluent/SQLite, Elementary + htmx, swift-openapi-generator, Swift Testing; iOS app
SwiftUI + `WatchSwiftyCore`.

**Spec:** `docs/superpowers/specs/2026-11-19-standard-import-design.md` (German; read it before each task, section
numbers below refer to it).

## Global Constraints

- Branch `feature/standard-import` (server, already exists). The iOS work goes on `feature/standard-import` in
  `../watchswifty-ios`, branched from its `main`.
- The task ends at the merge into `dev`: no release, no push to `main`, no changes to `VERSION` and no CHANGELOG release section (spec §8).
- iOS builds against the local path `.package(path: "../../../watchswifty")`; **never commit** that line or the
  resulting `Package.resolved` change (spec §8).
- Everything users see is German; code, comments, docs, OpenAPI descriptions are English (CLAUDE.md).
- Upload limit **5 MB** (5 * 1024 * 1024) on the web and the API, with an API body limit of 6 MB (spec §1).
- Migrations are appended at the end of the list in `configure.swift`; `CreateFilmListEntry` stays in the list (spec §5).
- Viewings get `origin: .manual`; dates after `today` → no date (spec §4).
- Error copy, exact: `Kein Standard-Import erkannt – erwartet wird eine CSV mit einer Kopfzeile, die „type“ und „title“ enthält.`
  and `Die Datei enthält keine Titel.` (spec §1).
- Commits: English Conventional Commits ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Run `swift test` (whole suite) before every commit that touches shared code; the filters given are for the TDD loop.

## Review Focus

1. **A file re-saved in German Excel**: `;` as the separator, Windows-1252 umlauts, dates like `02.03.2024`. Expected: it
   parses like the UTF-8 original. Test in Task 1 (`excelSemicolonFile`) and Task 4 (`uploadWindows1252`).
2. **A long Trakt history close to the limit** (≈ 4 MB): expected to be accepted on the web and the API, not rejected by
   the 2 MB body limits that still apply elsewhere. Tests in Task 4 (`uploadFourMegabytes`) and Task 5 (`apiUploadLimit`).
3. **Titles containing quotes, commas, semicolons or line breaks** (`"Love, Death & Robots"`): they must stay one field.
   Test in Task 1 (`quotedFields`).
4. **Specials (season 0) and a series whose newer seasons are missing from the cache**: specials are matched, and a
   missing episode triggers one refresh before it counts as missing. Tests in Task 3 (`specialsMatch`,
   `staleCacheRefreshesOnce`).
5. **A new upload while the worker is still working through the previous list**: entries are deleted under the
   worker. Expected: no crash, no viewings from the deleted list after the replace, and the next pass handles the new
   list. Test in Task 3 (`resolveOfDeletedEntryIsHarmless`).

---

### Task 1: Format parser and grouping

**Files:**
- Create: `Sources/App/Import/StandardImportFormat.swift`
- Modify: `Sources/App/Tracking/StreamingService.swift` (move `init?(label:)` here from `Import/FilmList.swift`, unchanged)
- Modify: `Sources/App/Import/FilmList.swift` (delete the moved extension)
- Test: `Tests/AppTests/StandardImportFormatTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum StandardRowType: String, Sendable { case movie, episode, series }
  struct StandardImportRow: Sendable, Equatable {
      let type: StandardRowType; let title: String; let year: Int?; let tmdbID: Int?; let imdbID: String?
      let season: Int?; let episode: Int?; let day: String?; let service: StreamingService?; let rating: Int?; let comment: String?
  }
  struct StandardImportFile: Sendable, Equatable { let rows: [StandardImportRow]; let skippedRows: Int }
  enum StandardImportError: Error, Equatable { case noHeader }
  func parseStandardImport(_ text: String) throws -> StandardImportFile
  func importDay(_ raw: String) -> String?
  func importRating(_ raw: String) -> Int?
  extension StreamingService { init?(importValue: String) }   // raw key (`prime_video`) first, else init(label:)
  struct ImportWatch: Codable, Sendable, Equatable { let season: Int?; let episode: Int?; let day: String?; let service: StreamingService? }
  struct ImportDraft: Sendable, Equatable {
      let kind: TitleKind; let title: String; let year: Int?; let tmdbHint: Int?; let imdbID: String?
      let watches: [ImportWatch]; let rating: Int?; let comment: String?
  }
  func groupStandardImport(_ rows: [StandardImportRow]) -> [ImportDraft]
  ```

- [ ] **Step 1: Write the failing tests** in suite `@Suite("StandardImportFormat")`:
  - `parsesAllRowTypes`: the spec §1 sample (3 rows) → types `[.movie, .episode, .series]`, row 0 `tmdbID == 438631`,
    `day == "2024-03-02"`, `service == .netflix`, `rating == 8`, `comment == "Im Kino besser"`; row 1 `imdbID == "tt11280740"`,
    `season == 1`, `episode == 3`, `service == .appleTV`; row 2 `rating == 9`, no day; `skippedRows == 0`.
  - `headerIsCaseInsensitiveAndMayBePreceded`: text `"My export\n\n Type ;TITLE;Year\nMovie;Dune;2021\n"` → 1 row, type `.movie`, year 2021.
  - `excelSemicolonFile`: `"\u{FEFF}type;title;watched_on;rating\nmovie;Amélie;02.03.2024;7,5\n"` → day `"2024-03-02"`, rating 8.
  - `quotedFields`: `"type,title,comment\nseries,\"Love, Death & Robots\",\"Zeile 1\nZeile 2; mit \"\"Zitat\"\"\"\n"` → title
    `Love, Death & Robots`, comment `Zeile 1\nZeile 2; mit "Zitat"`.
  - `invalidRowsAreCounted`: rows `podcast,X` / `movie,` / `episode,Show,,,,,1,` (no episode number) / `episode,Show,,,,,1,2` /
    empty line → 1 row, `skippedRows == 3`.
  - `missingHeaderThrows`: `"Filmname;Jahr\nDune;2021\n"` → `#expect(throws: StandardImportError.noHeader)`.
  - `dates`: `importDay` of `"2024-03-02"`, `"2024-03-02T20:15:00Z"`, `"2024-03-02 20:15"`, `"02.03.2024"`, `"2.3.2024"` →
    `"2024-03-02"`; `"3/2/24"` → `"2024-03-02"`; `"2024-02-31"`, `"gestern"`, `""` → nil.
  - `ratings`: `importRating` `"8"`→8, `"7.5"`→8, `"7,4"`→7, `"12"`→10, `"0.4"`→1, `"0"`→nil, `""`→nil, `"gut"`→nil.
  - `services`: `StreamingService(importValue:)` `"prime_video"`→`.primeVideo`, `"Netflix"`→`.netflix`, `"Amazon Prime"`→`.primeVideo`,
    `"YouTube"`→`.other`, `""`→nil.
  - `imdbIDsAreValidated`: an `imdb_id` of `"tt0123"` is kept, `"123"` and `"https://imdb.com/title/tt1"` → nil.
  - `groupsByIDThenTitle`: rows (in order) movie Dune 2021 tmdb 438631 (rating 7, comment "A"); movie „Dune“ 2021 tmdb 438631
    (rating 9, comment "B"); movie dune 2021 without ID; three episode rows of Severance 2022 with *different*
    imdb IDs `tt1`/`tt2`/`tt3`; series Severance 2022 imdb `tt11280740` → 4 drafts in first-appearance order:
    `[Dune/438631 (2 watches, rating 9, comment "A\n\nB"), dune/no ID (1 watch), Severance tv (3 watches, imdbID "tt1"),
    Severance tv imdbID "tt11280740" (0 watches)]`.
  - `seriesRowAddsNoWatch` and `commentIsCappedAtMaxLength` (comment of `WatchService.maxCommentLength + 50` chars →
    `count == WatchService.maxCommentLength`).

- [ ] **Step 2: Run them to make sure they fail.** Run `swift test --filter StandardImportFormat`. Expected: compile errors (the types don't exist yet).

- [ ] **Step 3: Implement** in `StandardImportFormat.swift`. Reuse `splitCSVRecords(_:delimiter:)` and `netflixDay(_:)` from
  `NetflixCSV.swift` and `normalizeTitle` for keys:
  - Delimiter: the first record that, split by `;`, contains both `type` and `title` (trimmed, lowercased) → `;`; else `,`.
  - Header: the first record with both columns; records before it are ignored.
  - `importDay`: try `netflixDay` on the part before the first `T` or space when it matches `^\d{4}-\d{2}-\d{2}[T ]`,
    else on the whole string.
  - Grouping key: `movie` → `"movie#t<tmdb>"` | `"movie#i<imdb>"` | `"movie#n<normalized>#<year>"`; `episode` → tmdb or
    name key (never imdb); `series` → tmdb | imdb | name. The kind for `episode` and `series` is `.tv`. Keep the first
    non-nil `imdbID` of the group (also from episode rows) and the first non-nil tmdb. Rating: the last non-nil value.
    Comment: the distinct non-empty comments joined with `"\n\n"`, cut with `prefix(WatchService.maxCommentLength)`.
    Watches: one per `movie`/`episode` row, in file order.

- [ ] **Step 4: Run the tests and make sure they pass.** Run `swift test --filter StandardImportFormat` → PASS. Then run
  `swift test --filter FilmList` → PASS (the move of `init?(label:)` broke nothing).

- [ ] **Step 5: Commit.** Message: `feat(import): parser and grouping for the standard CSV format`.

---

### Task 2: TMDB `/find` and the generalized title choice

**Files:**
- Modify: `Sources/App/TMDB/TMDBClient.swift`, `Sources/App/TMDB/LiveTMDBClient.swift`
- Modify: `Tests/AppTests/Support/FakeTMDBClient.swift`
- Create: `Sources/App/Import/TitleChooser.swift` (move `FilmChoice`/`chooseFilm` out of `FilmList.swift`, renamed)
- Modify: `Sources/App/Import/FilmListImporter.swift`, `Tests/AppTests/FilmListTests.swift` (follow the rename)
- Test: `Tests/AppTests/TitleChooserTests.swift`, `Tests/AppTests/TMDBTests.swift` (decoding test for `find`)

**Interfaces:**
- Produces:
  ```swift
  struct TMDBFindResult: Sendable, Equatable { var movies: [TMDBSearchResult] = []; var series: [TMDBSearchResult] = []; var episodeShowIDs: [Int] = [] }
  // TMDBClient:
  func find(imdbID: String) async throws -> TMDBFindResult      // GET find/{id}?external_source=imdb_id
  // FakeTMDBClient: setFind(_ imdbID: String, _ result: TMDBFindResult); records "find:<id>"; unknown id → empty result
  enum TitleChoice: Equatable { case match(TMDBSearchResult); case review([TMDBSearchResult]); case notFound }
  func chooseTitle(query: String, year: Int?, results: [TMDBSearchResult]) -> TitleChoice   // body of chooseFilm, unchanged
  func plausibleIDMatch(title: String, year: Int?, found: TMDBSearchResult) -> Bool
  ```

- [ ] **Step 1: Write the failing tests.**
  - The existing tests `choosesUniqueYearMatch`/`ambiguousGoesToReview` move to `TitleChooserTests`, calling `chooseTitle`.
    Add `choosesSeriesByFirstAirYear`: tv results `Dark (2017)` and `Dark (2005)`, query `Dark`, year 2017 → `.match` id of 2017.
  - `plausibility`: `plausibleIDMatch(title: "Dune", year: 2021, found: Dune 2021)` true; title `"Der Wüstenplanet"`, year 2021,
    found `Dune` 2021 → true (year fits); title `"Dune"`, year 1984, found `Dune` 2021 with originalName nil → true (title fits);
    title `"Severance"`, year 2022, found `Dune` 2021 → false; title `"Foo"`, year nil, found `Dune` 2021 → true.
  - Decoding test for `find`: a JSON with one `movie_results` entry (`id 438631, title "Dune", original_title "Dune",
    release_date "2021-09-15"`), one `tv_results` entry (`id 95396, name "Severance", first_air_date "2022-02-17"`)
    and one `tv_episode_results` entry (`show_id 95396`) → `movies[0].year == 2021`, `series[0].kind == .tv`,
    `episodeShowIDs == [95396]`. Use the same decoding entry point style the existing tests use (add a
    `static func decodeFind(_ data: Data) throws -> TMDBFindResult` to `LiveTMDBClient`).

- [ ] **Step 2: Run them to make sure they fail.** Run `swift test --filter "TitleChooser|TMDB"` → compile errors.

- [ ] **Step 3: Implement.**
  - `find` goes in the protocol, in `MissingTokenTMDBClient` (throws `.missingToken`), in `LiveTMDBClient` and in the fake.
  - `decodeFind` reuses the movie and tv result mapping of `decodeSearch`.
  - `plausibleIDMatch` is true when the normalized `title` equals the normalized `found.name` or `found.originalName`,
    or when `year` is nil, or when `found.year` is within ±1 of `year`.

- [ ] **Step 4: Run the whole suite** (`swift test`) → PASS.

- [ ] **Step 5: Commit.** Message: `feat(tmdb): find titles by IMDb id; generalize the title choice`.

---

### Task 3: Import entries, matching, recording, worker

**Files:**
- Create: `Sources/App/Import/ImportEntry.swift` (model, `CreateImportEntry`, `ImportEntryService`)
- Create: `Sources/App/Import/StandardImporter.swift` (`StandardImporter`, `ImportWorker`, `Application.importWorker`)
- Modify: `Sources/App/Tracking/WatchService.swift` (`unhide` becomes `func unhide(userID:titleID:)`, no longer private)
- Modify: `Sources/App/configure.swift` (append `CreateImportEntry()`; create `app.importWorker` next to `filmListWorker`,
  with the same arguments)
- Modify: `Sources/App/Catalog/CatalogMaintenance.swift` (`titleUsers` adds `import_entries` with `tmdb_id`, resolved by
  kind and tmdbID; candidate clean-up for `import_entries` older than the cutoff, same as the film list)
- Test: `Tests/AppTests/StandardImportTests.swift`, `Tests/AppTests/CatalogMaintenanceTests.swift` (one new test)

**Interfaces:**
- Consumes: Task 1 `ImportDraft`, `ImportWatch`, `parseStandardImport`, `groupStandardImport`; Task 2 `find`,
  `chooseTitle`, `plausibleIDMatch`.
- Produces:
  ```swift
  enum ImportEntryStatus: String, Codable, Sendable { case pending, imported, review; case notFound = "not_found"; case skipped }
  final class ImportEntry: Model  // schema "import_entries"; fields per spec §5:
      // id, user (parent, cascade), position, kind, title, year?, tmdbHint ("tmdb_hint")?, imdbID ("imdb_id")?,
      // watches (JSON [ImportWatch]), rating?, comment?, status, tmdbID ("tmdb_id")?, candidates?,
      // missingEpisodes ("missing_episodes", default 0), addedWatches ("added_watches", default 0), error?, createdAt
      init(userID: UUID, position: Int, draft: ImportDraft)
      var entryStatus: ImportEntryStatus; var titleKind: TitleKind; var watchList: [ImportWatch]
      var candidateList: [TMDBSearchResult]; func setCandidates(_: [TMDBSearchResult])
  struct ImportUploadSummary: Sendable, Equatable { let titles: Int; let skippedRows: Int }
  struct ImportEntryService {   // db
      static let noHeaderMessage: String; static let emptyMessage: String   // exact copy, see Global Constraints
      func replace(userID: UUID, drafts: [ImportDraft]) async throws
      func upload(userID: UUID, text: String) async throws -> ImportUploadSummary   // throws APIError.validation(...)
      func retry(userID: UUID) async throws
      func skip(userID: UUID, id: UUID) async throws -> ImportEntry
      func entries(userID: UUID) async throws -> [ImportEntry]                       // sorted by position
      func ownEntry(userID: UUID, id: UUID) async throws -> ImportEntry              // TrackingError.notFound for others
  }
  struct StandardImporter {     // db, tmdb, today: String
      func resolve(_ entry: ImportEntry) async throws
      func search(_ entry: ImportEntry, query: String) async throws                  // search in entry's kind, ≤ 8 hits, status review/notFound
      func record(_ entry: ImportEntry, tmdbID: Int) async throws
  }
  actor ImportWorker { func kick(); func processAll() async throws -> Int }          // same shape as FilmListWorker
  extension Application { var importWorker: ImportWorker }
  ```

- [ ] **Step 1: Write the failing tests** in `@Suite("StandardImport")`. Seed the data with a `static func fake()`: movie Dune
  438631 (2021); series Severance 95396 (2022), seasons 0 (`["Special"]`), 1 (`["E1","E2","E3"]`); imdb `tt1520211`
  → movie Dune via `setFind`; imdb `tt99` (an episode) → `episodeShowIDs [95396]`; searches for `Dune` (two results 2021/1984)
  and `Severance` (one result).
  - `idMatchIsAutomatic`: an entry with tmdbHint 438631, title "Dune", year 2021 → `imported`, `tmdbID == 438631`, 1 watch.
  - `implausibleIDGoesToReview`: tmdbHint 438631 with title "Severance", year 2022 → `review`, `candidateList.first?.id == 438631`.
  - `unknownTMDBIDFallsBackToSearch`: tmdbHint 1 (not in the fake) title "Severance" → `imported` 95396.
  - `imdbEpisodeIDResolvesSeries`: a tv entry with imdbID `tt99`, title "Severance" → `imported` 95396.
  - `titleSearchAmbiguousGoesToReview`: "Dune", no year → `review` with 2 candidates; no hits → `not_found`.
  - `episodesAreRecorded`: Severance entry with watches S1E1 2024-05-10 apple_tv, S1E3 undated, S2E1 → 2 episode watches
    (`origin == .manual`, service `.appleTV` on the first), `missingEpisodes == 1`, `addedWatches == 2`.
  - `specialsMatch`: watch S0E1 → 1 watch on the special.
  - `staleCacheRefreshesOnce`: record once (seasons 1 only), then `setSeason(seriesID: 95396, number: 2, …)` with the
    series' `seasonNumbers` grown to include 2, and record again with S2E1 → the S2E1 watch exists; `tmdb.calls` contains
    `series:95396` exactly twice in total.
  - `reimportDoesNotDuplicate`: replace and record the same drafts twice → the same watch count; an existing watch one
    day off is not duplicated; an undated row adds nothing when any watch exists.
  - `ratingAndCommentAppend`: existing comment "Alt" → `"Alt\n\nNeu"`; rating set from the draft.
  - `seriesRowOnlyAddsToLibrary`: a series draft with no watches, rating 9 → a `UserTitle` with rating 9, zero watches,
    `hidden` unchanged (set to true beforehand → still true).
  - `importUnhidesTitlesWithNewWatches`: a hidden movie → `hidden == false` after the record.
  - `futureDayBecomesUndated`: day `2027-01-01` with today `2026-11-07` → `watchedOn == nil`.
  - `workerResolvesAndKeepsErrors`: `app.importWorker.processAll()` resolves; a user without a token → stays `pending`,
    `error == TMDBError.missingToken.description`; `retry` clears the error.
  - `uploadReplacesAndReports`: `upload(text:)` with 2 valid rows + 1 invalid → `ImportUploadSummary(titles: 2, skippedRows: 1)`;
    a second upload replaces the entries; the header error and the empty file throw `APIError.validation` with the exact copy.
  - `resolveOfDeletedEntryIsHarmless`: load an entry, delete all of the user's entries with `replace(… drafts: [])`, then call
    `resolve` on the stale object → no throw, `ImportEntry.query.count() == 0`, no `Watch` rows.
  - `entriesArePrivate`: `ownEntry` of another user's ID → throws `TrackingError.notFound`.
  - In `CatalogMaintenanceTests`: `importEntriesKeepTheirTitles`: an imported tv entry keeps its title out of the
    "unused" deletion.

- [ ] **Step 2: Run them to make sure they fail.** Run `swift test --filter StandardImport` → compile errors.

- [ ] **Step 3: Implement.**
  - **`resolve` order (spec §3):**
    1. With a tmdbHint: fetch `movie(id:)` or `series(id:)` and turn it into a `TMDBSearchResult`. On `TMDBError.notFound`,
       continue with the next step.
    2. With an imdbID: call `find(imdbID:)`. For a movie, use `movies.first`. For a series, use `series.first`, or else
       `episodeShowIDs.first` resolved through `series(id:)`.
    3. A hit from step 1 or 2 with `plausibleIDMatch` → `record`. Without the match → `review`, with that hit first,
       then the search results (deduplicated by id, at most 5).
    4. Otherwise `search(title, kind:)` and `chooseTitle`.
  - **`record`:** load the title through `CatalogService.title(kind:tmdbID:)`. Rules:
    - **Movies:** the duplicate rule of `FilmListImporter.record`.
    - **Series:** look episodes up by `(season, number)` from `CatalogService.episodes(of:)`. If any are missing and
      the title existed before this call, run `CatalogService.refresh(title)` **once**, then look them up again.
    - **Duplicates per episode:** a watch counts as a duplicate when the same episode has a watch within ±1 day, or
      for an undated row when the episode has any watch. Watches added earlier in the same call count too.
    - **Hidden titles:** when `added > 0`, call `WatchService.unhide`.
    - **Rating and comment:** as in `FilmListImporter.record`.
    - **Entry fields:** set `status = imported`, `tmdbID`, `missingEpisodes`, `addedWatches = added`, clear the
      candidates and the error.
  - **`ImportWorker`:** a copy of the `FilmListWorker` loop over `ImportEntry`, with log prefix `Standard-Import:`.

- [ ] **Step 4: Run the tests** (`swift test --filter "StandardImport|CatalogMaintenance"`, then `swift test`) → PASS.

- [ ] **Step 5: Commit.** Message: `feat(import): standard import entries, TMDB matching and recording`.

---

### Task 4: Web UI

**Files:**
- Create: `Sources/App/Import/StandardImportController.swift`
- Create: `Sources/App/Web/Pages/StandardImportPage.swift` (`StandardImportPage`, `ImportStatusBox`, `ImportEntryCard`)
- Create: `Public/import/watchswifty-import-example.csv` (the 3 sample rows from spec §1, plus one `episode` row
  without a date)
- Modify: `Sources/App/routes.swift` (register the new controller)
- Modify: `Sources/App/Web/Pages/ImportPage.swift:36-39` (link)
- Modify: `Tests/AppTests/FilmListTests.swift` (`uploadAndReviewFlow`: drop the `/import` link assertion; the link is gone)
- Test: `Tests/AppTests/StandardImportWebTests.swift`

**Interfaces:**
- Consumes: Task 3 `ImportEntryService`, `StandardImporter`, `app.importWorker`, `ImportEntry`.
- Produces: routes `GET /import/standard`, `POST /import/standard` (multipart `file`, `body: .collect(maxSize: "6mb")`, rejects
  > 5 MB with 413), `GET /import/standard/status[?polling=1]`, `POST /import/standard/retry`,
  `POST /import/standard/:entryID/accept` (form `tmdbID`), `…/search` (form `q`), `…/skip`.

- [ ] **Step 1: Write the failing tests** (`@Suite("StandardImportWeb")`, reuse `StandardImportTests.fake()`, `UploadForm`, `login`):
  - `importPageLinksToStandardImport`: `GET /import` contains `href="/import/standard"` and **not** `/import/films`.
  - `pageShowsFormatHelp`: `GET /import/standard` contains `href="/import/watchswifty-import-example.csv"` and the `DocsLink`
    to `import.md`.
  - `uploadAndReviewFlow`: an upload with a Dune (no year) + Severance episode + 1 invalid row → 200, the body contains
    `2 Titel übernommen` and `1 Zeile übersprungen`. Then `processAll`, then `GET` → it contains `Film`/`Serie` labels, the
    candidate `Übernehmen` button and the `/tv/95396` link. Accept, search and skip work as in the old film list
    test (status changes in the DB).
  - `uploadErrors`: a file without a header → 422 with the exact header copy; an empty file → 422 with `Die Datei enthält keine Titel.`.
  - `uploadWindows1252`: bytes of `"type;title\nmovie;Amélie\n"` encoded with `.windowsCP1252` → 200, an entry titled `Amélie`.
  - `uploadFourMegabytes`: valid header + rows padded with a 4 MB `comment` column → 200; 5 MB + 1 byte → 413.
  - `cardShowsMissingEpisodes`: an imported tv entry with `missingEpisodes = 2` renders `2 Episoden nicht gefunden`.
  - `entriesArePrivate`: another user's `…/skip` → 404.

- [ ] **Step 2: Run them to make sure they fail.** Run `swift test --filter StandardImportWeb` → FAIL / compile errors.

- [ ] **Step 3: Implement.**
  - Mirror `FilmListController`/`FilmListPage`, reusing their CSS classes (`film-status`, `film-entry`, `film-entry-body`,
    `film-imported`, `candidates`, `inline-form`).
  - Decode with UTF-8, falling back to `.windowsCP1252`.
  - Fixed copy:
    - Page title and h1: `Aus anderen Trackern importieren`
    - Intro: `CSV im WatchSwifty-Format – zum Beispiel aus Letterboxd, IMDb oder Trakt umgebaut. Pflicht sind die Spalten type und title, alles andere ist optional.`
    - Links: `Beispieldatei herunterladen`, `DocsLink(page: "import.md#other-trackers-standard-csv", label: "Format und Umbau-Hinweise")`
    - List items: `Jede movie- und episode-Zeile wird eine Sichtung.` / `Eine series-Zeile nimmt die Serie mit Bewertung und Kommentar in die Bibliothek auf.` / `Ein neuer Upload ersetzt diese Liste; schon vorhandene Sichtungen werden nicht doppelt angelegt.`
    - Notice: `\(titles) Titel übernommen – die Zuordnung zu TMDB läuft im Hintergrund.`, plus
      ` \(n) Zeile(n) übersprungen (unbekannter Typ, fehlender Titel oder fehlende Staffel/Episode).` when n > 0
      (`1 Zeile`, `n Zeilen`).
    - Card line: `Film`/`Serie` · `N Sichtung(en)` · `★ r`. For tv with `missingEpisodes > 0`: `M Episode(n) nicht gefunden`.
      Imported cards link `Film öffnen` → `/movie/<id>` and `Serie öffnen` → `/tv/<id>`.
    - Imported section summary: `Übernommene Titel anzeigen (N)`.
  - `ImportPage`: replace the film list paragraph with `Verlauf aus einem anderen Tracker? ` + `a(.href("/import/standard")) { "Aus anderen Trackern importieren" }`.

- [ ] **Step 4: Run the tests** (`swift test --filter "StandardImportWeb|FilmList"`, then `swift test`) → PASS. Start the
  `watchswifty` preview, upload `Public/import/watchswifty-import-example.csv` and check the page renders.

- [ ] **Step 5: Commit.** Message: `feat(import): web page for the standard import`.

---

### Task 5: App API (replace the film list endpoints)

**Files:**
- Modify: `Sources/WatchSwiftyAPI/openapi.yaml` (remove `/v1/imports/films*` and the `FilmUploadResult`, `FilmEntry`,
  `FilmCounts`, `FilmList`, `FilmAccept`, `FilmSearch`, `FilmStatus` schemas and the `Movie list` tag; add the new ones)
- Delete: `Sources/App/API/APIHandler+FilmList.swift`, `Tests/AppTests/APIFilmListTests.swift`
- Create: `Sources/App/API/APIHandler+StandardImport.swift`, `Tests/AppTests/APIStandardImportTests.swift`
- Modify: `Sources/App/API/BodyLimitMiddleware.swift:8` (`"uploadStandardImport": 6 * 1024 * 1024`, drop `uploadFilmList`)
- Modify: `Sources/WatchSwiftyClient/OpenValues.swift`, `Sources/WatchSwiftyClient/openapi-generator-config.yaml`,
  `Tests/WatchSwiftyClientTests/OpenValueTests.swift` (`FilmStatusValue` → `ImportStatusValue`, same values)

**Interfaces:**
- Consumes: Task 3 services.
- Produces (tag `Standard import`, all `bearerAuth`, responses as the film ones had, including 401/404/413/422):
  - `POST /v1/imports/standard` `uploadStandardImport` (multipart `file`, ≤ 5 MB) → `ImportUploadResult {titles, skippedRows}`
  - `GET /v1/imports/standard` `getStandardImport` → `ImportList {counts: ImportCounts, error?, entries: [ImportEntry]}`
  - `POST /v1/imports/standard/retry` `retryStandardImport` → `ImportList`
  - `POST /v1/imports/standard/{id}/accept` `acceptImportEntry` (`ImportAccept {tmdbId}`) → `ImportEntry`
  - `POST /v1/imports/standard/{id}/search` `searchImportEntry` (`ImportSearch {q}`) → `ImportEntry`
  - `POST /v1/imports/standard/{id}/skip` `skipImportEntry` → `ImportEntry`
  - `ImportEntry {id, kind (string enum [tv, movie], as in SearchResult), title, year?, watchCount, rating?,
    status: ImportStatus, tmdbId?, candidates: [SearchResult], missingEpisodes, addedWatches, error?}`;
    `ImportCounts {imported, review, notFound, skipped, pending}`; `ImportStatus` enum
    `[pending, imported, review, not_found, skipped]`.

- [ ] **Step 1: Write the failing tests** in `APIStandardImportTests`, following the structure of the old `APIFilmListTests`:
  - `apiUploadAndResolve`: upload → `titles`/`skippedRows`; `pending` count; after `processAll` the counts, the
    candidates and `watchCount`/`missingEpisodes`/`kind`.
  - `apiUploadLimit`: 5 MB + 1 → 413 `payloadTooLarge`; ≈ 4 MB valid → 200.
  - `apiUploadErrors`: no header → 422 with the exact copy.
  - `apiAcceptSearchSkip`.
  - `apiForeignEntry404`.
  - `oldFilmEndpointsAreGone`: `GET /api/v1/imports/films` → 404.
  - `OpenValueTests`: `ImportStatusValue.known.map(\.rawValue) == ["pending", "imported", "review", "not_found", "skipped"]`.

- [ ] **Step 2: Run them to make sure they fail.** Run `swift test --filter "APIStandardImport|OpenValue"` → compile errors.

- [ ] **Step 3: Implement** the spec changes first, then the handler (same pattern as the old `APIHandler+FilmList`,
  `uploadedText(_:allowLatin: true)`, `app.importWorker.kick()`), then the client open value.

- [ ] **Step 4: Run** `swift build` and `swift test` → PASS.

- [ ] **Step 5: Commit.** Message: `feat(api)!: standard import endpoints replace the film list API`, with a body
  line `BREAKING CHANGE: /v1/imports/films is removed; use /v1/imports/standard.`.

---

### Task 6: Remove the film list

**Files:**
- Delete: `Sources/App/Import/FilmList.swift`, `FilmListEntry.swift`, `FilmListImporter.swift`, `FilmListController.swift`,
  `Sources/App/Web/Pages/FilmListPage.swift`, `Tests/AppTests/FilmListTests.swift`
- Create: `Sources/App/Import/FilmListMigrations.swift` with `CreateFilmListEntry` (same schema, table and field names
  written out, `User.schema` reference kept) and `DropFilmListEntries` (`prepare`: delete `film_list_entries`;
  `revert`: recreate it like `CreateFilmListEntry`)
- Modify: `Sources/App/configure.swift` (append `DropFilmListEntries()`; remove `filmListWorker`), `Sources/App/routes.swift`,
  `Sources/App/Catalog/CatalogMaintenance.swift` (drop the `FilmListEntry` parts and the doc comment mention)
- Test: `Tests/AppTests/StandardImportWebTests.swift` (add), `Tests/AppTests/StandardImportWebTests.swift` (table check via `(app.db as! any SQLDatabase).raw(...)`)

- [ ] **Step 1: Write the failing tests.**
  - `oldFilmRoutesAreGone`: `GET /import/films` → 404.
  - `filmListTableIsDropped`: after `withTestApp`, `SELECT name FROM sqlite_master WHERE name = 'film_list_entries'` is empty
    and `import_entries` exists.

- [ ] **Step 2: Run them to make sure they fail.** Run `swift test --filter "oldFilmRoutesAreGone|filmListTableIsDropped"` → FAIL.

- [ ] **Step 3: Delete and move** as listed. Then run `grep -rn "FilmList\|filmList\|chooseFilm\|germanDay\|filmRating" Sources Tests`.
  The only hits allowed are in `FilmListMigrations.swift`.

- [ ] **Step 4: Run** `swift test` → PASS.

- [ ] **Step 5: Commit.** Message: `refactor(import): remove the personal film list import`.

---

### Task 7: Documentation

**Files:**
- Modify: `docs/import.md` (replace "Your own film list" with the section `## Other trackers (standard CSV)` so the anchor
  `#other-trackers-standard-csv` from Task 4 resolves), `docs/app-api.md:32` ("film list" → "standard import"), `README.md:67`
  (`Netflix viewing history and other trackers (standard CSV)`)

- [ ] **Step 1: Write the section** per spec §1 and §10. It contains:
  - the column table and the 3-line example;
  - row meaning, skipped rows, the 5 MB limit, the example file `/import/watchswifty-import-example.csv`;
  - matching order: IDs with the plausibility check, then title + year, then **Zu prüfen** (to review);
  - conversion hints for Letterboxd `diary.csv` and the IMDb ratings export, exactly as in spec §10;
  - a note that `imdb_id` on episode rows may be the episode's own ID.
  The German UI labels are quoted with their English meaning (CLAUDE.md).

- [ ] **Step 2: Check the links.** Run `grep -rn "film list\|Filmliste" README.md docs/*.md` → no hits outside
  `docs/superpowers/`.

- [ ] **Step 3: Commit.** Message: `docs: standard import replaces the film list`.

---

### Task 8: iOS app (`../watchswifty-ios`)

**Files** (paths relative to `../watchswifty-ios`):
- Modify (local only, **do not commit**): `Packages/WatchSwiftyCore/Package.swift`. Swap the watchswifty dependency
  for `.package(path: "../../../watchswifty")`.
- Create: `Packages/WatchSwiftyCore/Sources/WatchSwiftyCore/Stores/StandardImportStore.swift`.
  Delete `FilmListStore.swift`.
- Modify: `Packages/WatchSwiftyCore/Sources/WatchSwiftyCore/Stores/ImportSupport.swift`. Replace `filmListLimit` with
  `standardImportLimit = 5_242_880`.
- Create: `WatchSwifty/Import/StandardImportView.swift`. Delete `FilmListView.swift`.
- Modify: `WatchSwifty/Import/ImportsView.swift`. The case becomes `standardImport`, the label
  `Aus anderen Trackern` with the SF Symbol `tray.and.arrow.down`.
- Create: `Packages/WatchSwiftyCore/Tests/WatchSwiftyCoreTests/StandardImportStoreTests.swift`.
  Delete `FilmListStoreTests.swift`.
- Modify: `WatchSwifty/Localizable.xcstrings` (or the project's String Catalog) for the new German strings, if the
  project lists strings there.

**Interfaces:**
- Consumes: Task 5 operations through `WatchSwiftyClient`: `uploadStandardImport`, `getStandardImport`,
  `retryStandardImport`, `acceptImportEntry`, `searchImportEntry`, `skipImportEntry`; `Components.Schemas.ImportList`,
  `ImportEntry`, `ImportStatusValue`.
- Produces: `StandardImportStore` with the same public surface as `FilmListStore`. The differences:
  `list: Loadable<Components.Schemas.ImportList>`, and `lastUpload: Components.Schemas.ImportUploadResult?` instead of
  `lastUploadCount`.

- [ ] **Step 1: Branch.** Run `git switch main && git pull && git switch -c feature/standard-import` in `../watchswifty-ios`.
  Then switch the package to the local path.

- [ ] **Step 2: Write the failing store tests.** Port the 5 film tests. Size limit: 5 MB + 1 byte is rejected locally.
  The upload must send the file. Polling must stop when nothing is pending. An action must replace the list. A search
  must replace only that entry's candidates. Add `uploadKeepsSkippedRows`: `lastUpload?.skippedRows == 2`.

- [ ] **Step 3: Run them to make sure they fail.** Run `swift test --package-path Packages/WatchSwiftyCore` → compile errors.

- [ ] **Step 4: Implement the store and the view.**
  - Mirror `FilmListView`.
  - Upload footer: `CSV im WatchSwifty-Format (höchstens 5 MB), z. B. aus Letterboxd, IMDb oder Trakt umgebaut.`
    with a `Link("Format", destination: <server>/…)`. If the app has no server-docs URL helper, link the GitHub page
    `https://github.com/PaddXy95/watchswifty/blob/main/docs/import.md#other-trackers-standard-csv`.
  - Each row shows `Film`/`Serie`, the viewings and, when greater than 0, `M Episoden nicht gefunden`.
  - The notice after upload reads `N Titel hochgeladen` plus `· K Zeilen übersprungen`.

- [ ] **Step 5: Run** `swift test --package-path Packages/WatchSwiftyCore` → PASS, then the `xcodebuild … build` from the
  iOS CLAUDE.md → `BUILD SUCCEEDED`. Launch it in the simulator against the preview server and upload the example file.

- [ ] **Step 6: Commit without the package path.** Run `git restore Packages/WatchSwiftyCore/Package.swift` and restore
  `Package.resolved` if it changed. Check that `git status` shows only the intended files. Commit with the message
  `feat(import): standard import replaces the film list`. Don't merge: the branch waits for the server release (spec §8).

---

### Finish

- [ ] Run the whole server suite: `swift test`. Run the whole-branch review. Ask the user to confirm the result. Then
  merge into `dev` per CLAUDE.md: `git switch dev && git merge --no-ff feature/standard-import`; on conflicts,
  `git merge --abort` and ask. Delete the branch with `git branch -d`. The iOS branch stays open.
