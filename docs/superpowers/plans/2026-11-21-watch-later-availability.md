# „Später ansehen“, Streamingdienste und Verfügbarkeit – Implementierungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merkliste „Später ansehen“, aktive Streamingdienste und Land pro Nutzer, Verfügbarkeit (TMDB Watch Providers /
JustWatch) auf jeder Detailseite und eine Nachricht, sobald ein gemerkter Titel bei einem eigenen Abo-Dienst läuft.

**Architecture:** Neuer Feature-Ordner `Sources/App/Availability/` mit Modellen, Migrationen und vier Services
(`AvailabilityService`, `AvailabilityNoticeService`, `WatchLaterService`, `StreamingSettingsService`). Der Tageslauf
fragt gemerkte Titel ab und gleicht Meldungen ab; `runNotifications` hängt einen Abschnitt an den Digest. Web (Elementary +
htmx) und App-API rufen dieselben Services.

**Tech Stack:** Swift 6.3, Vapor 4, Fluent/SQLite, Elementary + ElementaryHTMX2, swift-openapi-generator, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-21-watch-later-availability-design.md` (Abschnittsnummern unten = §n dort).

## Global Constraints

- Alle sichtbaren Texte **deutsch**; Code, Kommentare, Doku unter `docs/*.md`, OpenAPI-Beschreibungen, CHANGELOG
  **englisch**. Commits: Conventional Commits auf Englisch, Ende mit
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Arbeit nur auf Branch `feature/watch-later-availability` (von `dev`).
- Upcoming Features aktiv: `any Protocol`, jedes genutzte Modul importieren (`import Fluent` für Queries).
- Migrationen **am Ende** der Liste in `configure.swift` anhängen, alle additiv.
- „Heute“ ist `AppConfig.today()` (`YYYY-MM-DD`), in Tests `2026-11-07`.
- Nutzerdaten immer über den eingeloggten Nutzer laden; fremde IDs → 404.
- Abo-Arten für Benachrichtigung und „Bei deinen Diensten“: `flatrate`, `free`, `ads`. `rent`/`buy` lösen nie etwas aus.
- Detailseite lädt nach, wenn Stand fehlt oder älter als **7 Tage**; Verfügbarkeitsdaten werden nach **30 Tagen** ohne
  Abfrage gelöscht; Standardland **`DE`**.
- Quellenhinweis „Verfügbarkeit: JustWatch“ überall, wo Verfügbarkeit angezeigt oder verschickt wird.
- `watch_later` zählt in `titleUsers`/`usesTitle`; `title_availability`, `title_providers`, `availability_notices` nicht.

## Review Focus

1. **Doppelte Nachricht nach Dienst-/Land-/Schalter-Wechsel:** Wer Dienste ändert, das Land wechselt oder den Schalter
   einschaltet, bekommt keine Nachricht für Titel, die da schon liefen (Test in Task 4).
2. **Land nicht abgedeckt:** Ein Stand ohne das Land des Nutzers zählt als fehlend – keine Löschung seiner Meldungen,
   kein „nirgends verfügbar“ (Tests in Task 3 und 4).
3. **TMDB-Fehler während der Abfrage:** alter Stand bleibt, keine Meldungen gelöscht (Test in Task 3).
4. **Import alter Verläufe:** Netflix-Matching im Hintergrund mit Datum vor `added_on` leert die Liste nicht (Test in
   Task 5).
5. **Nutzer ohne TMDB-Token:** Liste und gespeicherter Stand sichtbar, kein Absturz; Detailblock zeigt Token-Hinweis
   (Test in Task 9).

---

### Task 1: TMDB-Client – Watch Providers, Dienste-Liste, Länder

**Files:**
- Modify: `Sources/App/TMDB/TMDBClient.swift`, `Sources/App/TMDB/LiveTMDBClient.swift`
- Modify: `Tests/AppTests/Support/FakeTMDBClient.swift`
- Test: `Tests/AppTests/TMDBTests.swift`

**Interfaces:**
- Produces (in `TMDBClient.swift`):
  ```swift
  enum OfferKind: String, Codable, Sendable, CaseIterable { case flatrate, free, ads, rent, buy }
  struct TMDBOffer: Sendable, Equatable { let providerID: Int; let name: String; let logoPath: String?; let displayPriority: Int; let kind: OfferKind }
  struct TMDBWatchProviders: Sendable, Equatable { var links: [String: String] = [:]; var offers: [String: [TMDBOffer]] = [:] } // key: region
  struct TMDBProviderInfo: Sendable, Equatable { let providerID: Int; let name: String; let logoPath: String?; let displayPriority: Int }
  struct TMDBRegion: Sendable, Equatable { let code: String; let name: String }
  // protocol TMDBClient gains:
  func watchProviders(kind: TitleKind, id: Int) async throws -> TMDBWatchProviders   // GET /{movie|tv}/{id}/watch/providers
  func providers(kind: TitleKind, region: String) async throws -> [TMDBProviderInfo]  // GET /watch/providers/{movie|tv}?watch_region=
  func providerRegions() async throws -> [TMDBRegion]                                // GET /watch/providers/regions
  ```
- Fake: `setWatchProviders(kind:id:_:)`, `setProviders(kind:region:_:)`, `setRegions(_:)`; records calls
  `"watch_providers:<kind>:<id>"`, `"providers:<kind>:<region>"`, `"regions"`. Unset → `watchProviders` returns empty
  value, lists return `[]`. `MissingTokenTMDBClient` throws `.missingToken`.

- [ ] **Step 1: Write failing decode tests** in `TMDBTests.swift`:
  - `decodeWatchProvidersGroupsByRegionAndKind`: JSON with `results.DE.flatrate=[{provider_id:8,provider_name:"Netflix",logo_path:"/n.jpg",display_priority:1}]`, `results.DE.buy=[…id 2…]`, `results.DE.link="https://…"`, `results.US.ads=[…]` → `offers["DE"]` has 2 offers with kinds `.flatrate`, `.buy`; `offers["US"]!.first!.kind == .ads`; `links["DE"] == "https://…"`.
  - `decodeProviderList`: `{results:[{provider_id:8,provider_name:"Netflix",logo_path:"/n.jpg",display_priority:3}]}` → one `TMDBProviderInfo(providerID: 8, name: "Netflix", logoPath: "/n.jpg", displayPriority: 3)`.
  - `decodeRegions`: `{results:[{iso_3166_1:"DE",english_name:"Germany",native_name:"Deutschland"}]}` → `TMDBRegion(code: "DE", name: "Deutschland")`.
  - Missing `display_priority` decodes as `Int.max`; unknown kinds are ignored.
- [ ] **Step 2:** `swift test --filter TMDBTests` → FAIL (symbols missing).
- [ ] **Step 3: Implement** types, protocol methods, `LiveTMDBClient` (`static func decodeWatchProviders/decodeProviderList/decodeRegions` wrapped in `Self.decoding`, same style as `decodeMovie`; regions request `language=de-DE` is already added by `url(...)`, name = `native_name` falling back to `english_name`), `MissingTokenTMDBClient`, Fake.
- [ ] **Step 4:** `swift test --filter TMDBTests` → PASS; `swift build` → no errors.
- [ ] **Step 5: Commit** `feat(tmdb): watch providers, provider list and regions`

---

### Task 2: Datenmodell, Migrationen, Cache-Regel

**Files:**
- Create: `Sources/App/Availability/AvailabilityModels.swift`, `Sources/App/Availability/AvailabilityMigrations.swift`
- Modify: `Sources/App/Auth/User.swift`, `Sources/App/configure.swift`, `Sources/App/Catalog/CatalogMaintenance.swift`
- Test: `Tests/AppTests/CatalogMaintenanceTests.swift`, new `Tests/AppTests/AvailabilityModelTests.swift`

**Interfaces:**
- Produces (§1):
  ```swift
  final class WatchLaterEntry: Model   // "watch_later": id, @Parent user, @Parent title, added_at: Date, added_on: String (YYYY-MM-DD), baselined: Bool; unique(user_id,title_id)
  final class TitleAvailability: Model // "title_availability": id, @Parent title (unique), fetched_at: Date, regions: String ("DE,AT"), tmdb_link: String?
     var regionList: [String]          // split of `regions`
  final class TitleProvider: Model     // "title_providers": id, @Parent title, region, provider_id: Int, provider_name, logo_path?, kind: String, display_priority: Int; index (title_id, region)
     var offerKind: OfferKind?
  final class UserStreamingService: Model // "user_streaming_services": id, @Parent user, provider_id: Int; unique(user_id, provider_id)
  enum NoticeState: String, Codable, Sendable { case baseline, skipped, pending, sent }
  final class AvailabilityNotice: Model // "availability_notices": id, @Parent user, @Parent title, provider_id: Int, noticed_at: Date, state: String; unique(user_id,title_id,provider_id)
  // User:
  @OptionalField(key: "watch_region") var watchRegion: String?
  @OptionalField(key: "notify_available") var notifyAvailable: Bool?
  var region: String { watchRegion ?? "DE" }
  ```
  All FKs `onDelete: .cascade`. Migrations: `CreateWatchLater`, `CreateTitleAvailability` (both availability tables),
  `CreateStreamingServices` (table + the two `users` columns), `CreateAvailabilityNotice`, appended in that order.

- [ ] **Step 1: Failing tests:**
  - `CatalogMaintenanceTests.watchLaterKeepsTitleCached`: seed movie, user, `WatchLaterEntry` → `titleUsers(on:)` contains the title with that user; `usesTitle(userID:title:on:)` is true.
  - `CatalogMaintenanceTests.availabilityRowsDoNotKeepTitle`: title with only `TitleAvailability`, `TitleProvider`, `AvailabilityNotice` rows → not in `titleUsers`; after `maintainCatalog` deletes the title, all three tables are empty for it (cascade).
  - `AvailabilityModelTests.duplicateWatchLaterRejected`: second entry for same (user, title) throws on save.
  - `AvailabilityModelTests.userRegionDefaultsToDE`: new user → `region == "DE"`.
- [ ] **Step 2:** `swift test --filter "CatalogMaintenanceTests|AvailabilityModelTests"` → FAIL.
- [ ] **Step 3: Implement** models, migrations (revert drops what prepare added), `User` fields, migration registration, `WatchLaterEntry` in `titleUsers` and `usesTitle`, doc comment on `titleUsers` listing it.
- [ ] **Step 4:** same filter → PASS; `swift test` whole suite → PASS.
- [ ] **Step 5: Commit** `feat(availability): data model and migrations`

---

### Task 3: AvailabilityService – Abfrage, Stand, Gruppierung, 30 Tage

**Files:**
- Create: `Sources/App/Availability/AvailabilityService.swift`, `Sources/App/Availability/ProviderLinks.swift`
- Test: `Tests/AppTests/AvailabilityServiceTests.swift`

**Interfaces:**
- Consumes: Task 1 types, Task 2 models.
- Produces:
  ```swift
  struct Offer: Sendable, Equatable { let providerID: Int; let name: String; let logoPath: String?; let kind: OfferKind; let displayPriority: Int }
  struct AvailabilitySnapshot: Sendable, Equatable { let fetchedAt: Date; let offers: [Offer] }  // sorted by displayPriority, name
  struct AvailabilityGroups: Sendable, Equatable {
      let hasServices: Bool
      let mine: [Offer]          // flatrate at own services
      let otherSubscriptions: [Offer] // other flatrate
      let free: [Offer]          // free + ads (all providers)
      let rentOrBuy: [Offer]     // rent + buy, one per provider+kind
      init(snapshot: AvailabilitySnapshot, services: Set<Int>)
  }
  struct AvailabilityService {
      static let staleAfter: TimeInterval = 7 * 86_400
      static let maxAge: TimeInterval = 30 * 86_400
      static let notifyKinds: Set<OfferKind> = [.flatrate, .free, .ads]
      let db: any Database
      func regionsInUse() async throws -> [String]            // distinct users.region, "DE" for nil, sorted
      func refresh(_ title: Title, tmdb: any TMDBClient, now: Date = .now) async throws  // replaces rows in a transaction; TMDB error → throws, nothing changed
      func snapshot(titleID: UUID, region: String) async throws -> AvailabilitySnapshot?  // nil if no row or region not in `regions`
      func needsRefresh(titleID: UUID, region: String, now: Date = .now) async throws -> Bool // snapshot nil or older than staleAfter
      func expire(now: Date = .now) async throws -> Int         // deletes availability + providers older than maxAge; notices untouched
  }
  extension Request { var availability: AvailabilityService }
  // ProviderLinks.swift:
  extension StreamingService { init?(tmdbProviderID: Int) }   // 8 netflix; 9, 119 primeVideo; 337 disneyPlus; 350 appleTV; 30 wow; 531 paramountPlus; 1899, 384 hboMax – verify IDs against /watch/providers/*?watch_region=DE
  ```
- [ ] **Step 1: Failing tests** (`withTestApp`, Fake with `setWatchProviders`):
  - `refreshStoresOnlyRegionsInUse`: users with region nil and `"AT"`; TMDB returns DE, AT, US → rows only for DE and AT; `TitleAvailability.regions == "AT,DE"`; one call `"watch_providers:movie:<id>"`.
  - `refreshFailureKeepsOldState`: refresh once, then `fail("watch_providers:movie:<id>", with: .rateLimited)` → `refresh` throws, rows and `fetchedAt` unchanged.
  - `snapshotNilWhenRegionNotCovered`: stored with regions `"DE"`, `snapshot(region: "AT") == nil`, `needsRefresh(region: "AT")` true.
  - `needsRefreshAfterSevenDays`: fetched now−8 days → true; now−6 days → false.
  - `expireDeletesAfterThirtyDays`: fetched now−31 days → `expire` returns 1, providers gone, an `AvailabilityNotice` for the title still exists.
  - `groupsSplitOwnAndOtherSubscriptions`: offers Netflix(8, flatrate), Disney(337, flatrate), Joyn(ads), Apple(rent), Apple(buy); services `[8]` → `mine==[Netflix]`, `otherSubscriptions==[Disney]`, `free==[Joyn]`, `rentOrBuy.count == 2`; services `[]` → `hasServices == false`.
  - `providerLinkMapping`: `StreamingService(tmdbProviderID: 8) == .netflix`, `(4242) == nil`.
- [ ] **Step 2:** `swift test --filter AvailabilityServiceTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS.
- [ ] **Step 5: Commit** `feat(availability): fetch, store and group watch providers`

---

### Task 4: AvailabilityNoticeService – Ausgangslage, neue Angebote, Fälligkeit

**Files:**
- Create: `Sources/App/Availability/AvailabilityNoticeService.swift`
- Test: `Tests/AppTests/AvailabilityNoticeTests.swift`

**Interfaces:**
- Consumes: `AvailabilityService.snapshot`, `notifyKinds`, models.
- Produces:
  ```swift
  struct AvailabilityDue: Sendable, Equatable {
      let titleID: UUID; let tmdbID: Int; let kind: TitleKind; let name: String; let year: Int?
      let providers: [String]   // names, sorted by displayPriority
      let noticeIDs: [UUID]
  }
  struct AvailabilityNoticeService {
      let db: any Database
      /// After a successful refresh of `titleID`: per watch_later entry of that title whose user's region is covered —
      /// matching = offers in user's region with kind ∈ notifyKinds at the user's services.
      /// baselined == false → insert missing as .baseline, set baselined = true.
      /// baselined == true  → insert missing as .pending (user.notifyAvailable == true) or .skipped.
      /// Then delete this user's notices for the title whose provider is no longer matching.
      func reconcile(titleID: UUID, now: Date = .now) async throws
      func rebaseline(userID: UUID) async throws               // all entries of user → baselined = false
      func due(userID: UUID) async throws -> [AvailabilityDue] // .pending, entry exists, provider still matching; grouped per title, titles by name
      func markSent(_ items: [AvailabilityDue]) async throws   // state = .sent
      func newSince(userID: UUID, since: Date) async throws -> [UUID: Date] // titleID → earliest noticed_at with state ≠ baseline, for „neu seit“
  }
  ```
- [ ] **Step 1: Failing tests** (seed movie, user with services `[8]`, entry, `TitleProvider` rows + `TitleAvailability(regions: "DE")` written directly):
  - `alreadyAvailableWhenAddedIsBaseline`: entry `baselined=false`, Netflix flatrate present → `reconcile` → one notice `.baseline`, `due` empty, entry `baselined == true`.
  - `newOfferBecomesPending`: baselined entry, `notifyAvailable = true`, Netflix appears → `.pending`; `due` has one item with `providers == ["Netflix"]`.
  - `newOfferWithSwitchOffIsSkipped`: `notifyAvailable = false` → `.skipped`, `due` empty, `newSince` contains the title.
  - `rentOrBuyNeverNotifies`: only `buy` at Netflix → no notice.
  - `otherServiceDoesNotNotify`: only Disney flatrate, services `[8]` → no notice.
  - `vanishedOfferDeletesNoticeAndReturnNotifiesAgain`: pending → markSent → offer removed → reconcile → notice gone → offer back → reconcile → `.pending` again.
  - `uncoveredRegionKeepsNotices`: user region `"AT"`, availability regions `"DE"` → reconcile leaves existing notices untouched.
  - `rebaselineSwallowsExisting`: sent notice + new Prime offer, user adds service 9, `rebaseline` → reconcile → Prime notice `.baseline`, `due` empty.
  - `dueIgnoresRemovedEntries`: pending notice, entry deleted → `due` empty.
- [ ] **Step 2:** `swift test --filter AvailabilityNoticeTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS.
- [ ] **Step 5: Commit** `feat(availability): baseline and notice states for watch later offers`

---

### Task 5: WatchLaterService und automatisches Entfernen

**Files:**
- Create: `Sources/App/Availability/WatchLaterService.swift`
- Modify: `Sources/App/Tracking/WatchService.swift` (`markEpisode`, `markMovie`, `markUndated`, `markRound`, `recordImportedWatch`), `Sources/App/Import/StandardImporter.swift:~122`
- Test: `Tests/AppTests/WatchLaterServiceTests.swift`

**Interfaces:**
- Consumes: `CatalogService.title(kind:tmdbID:)`, `AvailabilityService.refresh`, `AvailabilityNoticeService.reconcile`.
- Produces:
  ```swift
  struct WatchLaterItem: Sendable, Equatable { let title: Title; let addedAt: Date; let groups: AvailabilityGroups?; let newSince: Date? }
  struct WatchLaterPage: Sendable { let atMyServices: [WatchLaterItem]; let others: [WatchLaterItem]; let hasServices: Bool; let oldestFetch: Date? }
  struct WatchLaterService {
      let db: any Database
      /// Ensures the title in the catalog, inserts the entry (baselined = false, added_on = today) if missing, then tries
      /// refresh + reconcile with `tmdb`; a TMDB error is logged and swallowed (entry stays). Returns the title.
      func add(userID: UUID, kind: TitleKind, tmdbID: Int, tmdb: any TMDBClient, today: String, now: Date = .now, logger: Logger) async throws -> Title
      func remove(userID: UUID, titleID: UUID) async throws    // entry + the user's notices for the title
      func contains(userID: UUID, titleID: UUID) async throws -> Bool
      func containsTMDB(userID: UUID, kind: TitleKind, tmdbIDs: [Int]) async throws -> Set<Int>  // for search results
      /// .manual → remove; .import → remove only if day != nil && day >= entry.addedOn.
      func removeAfterWatch(userID: UUID, titleID: UUID, day: String?, origin: WatchOrigin) async throws
      func page(user: User, filter: String, now: Date = .now) async throws -> WatchLaterPage  // filter all|tv|movie; sorted by addedAt desc; atMyServices = groups.mine or free at own services non-empty; newSince within 7 days
  }
  extension Request { var watchLater: WatchLaterService }
  ```
- [ ] **Step 1: Failing tests:**
  - `addCreatesTitleAndEntryAndFetches`: Fake `addMovie` + `setWatchProviders` → entry exists, `TitleAvailability` exists, call `"watch_providers:movie:<id>"` recorded; second `add` keeps one entry.
  - `addSurvivesTMDBFailure`: `fail("watch_providers:movie:<id>", …)` → entry exists, no availability, no throw.
  - `manualWatchRemovesEntry` (parametrized over `markMovie`, `markEpisode`, `markSeason`, `markSeries`, `markUpTo`, `markMovie(day: "2020-01-01")`) → entry gone.
  - `importedOldWatchKeepsEntry`: `recordImportedWatch(day: "2020-01-01")` with `added_on == "2026-11-07"` → entry stays; `day: "2026-11-07"` → removed.
  - `standardImportRespectsAddedOn`: run standard import with a watch dated 2019 → entry stays (use existing `StandardImportTests` helpers).
  - `removeDeletesNotices`.
  - `pageGroupsAndSorts`: two items at own services, one not; filter `tv` keeps only series; newest `addedAt` first.
- [ ] **Step 2:** `swift test --filter WatchLaterServiceTests` → FAIL.
- [ ] **Step 3: Implement** service and hooks (one call per created watch; `markUndated`/`markRound` once per title after the loop).
- [ ] **Step 4:** `swift test --filter "WatchLaterServiceTests|WatchServiceTests|StandardImportTests|MatchingWorkerTests"` → PASS.
- [ ] **Step 5: Commit** `feat(availability): watch later list with removal on watch`

---

### Task 6: Streamingdienste-Einstellungen und Schalter

**Files:**
- Create: `Sources/App/Availability/StreamingSettingsService.swift`
- Modify: `Sources/App/Notify/NotificationPrefsService.swift`
- Test: `Tests/AppTests/StreamingSettingsTests.swift`, `Tests/AppTests/AccountNotificationsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct StreamingSettings: Sendable, Equatable { let region: String; let providerIDs: Set<Int> }
  struct StreamingSettingsService {
      static let regionMessage = "Unbekanntes Land."
      let db: any Database
      func settings(user: User) async throws -> StreamingSettings
      /// Validates region (^[A-Z]{2}$) and ids (> 0, at most 200), replaces services, sets user.watchRegion.
      /// Any change → AvailabilityNoticeService.rebaseline. Returns true when the region changed.
      func save(user: User, region: String, providerIDs: [Int]) async throws -> Bool
      /// Background: refresh list titles whose snapshot misses the user's region (one call each, via the shared limiter).
      func fetchMissing(userID: UUID, region: String, tmdb: any TMDBClient, logger: Logger) async
  }
  extension Request { var streamingSettings: StreamingSettingsService }
  // NotificationPrefsService.save gains `titleAvailable: Bool` (after `today:`); switching it on calls rebaseline.
  ```
- [ ] **Step 1: Failing tests:**
  - `saveReplacesServicesAndRegion`; `saveRejectsInvalidRegion` (`"de"`, `"DEU"` → `APIError.validation`).
  - `changeRebaselines`: entry baselined → save with new id → `baselined == false`.
  - `fetchMissingOnlyUncoveredTitles`: two list titles, one covered for `AT` → exactly one `watch_providers` call.
  - `AccountNotificationsTests.switchingAvailableOnRebaselines`.
- [ ] **Step 2:** FAIL → **Step 3:** implement (update all `save(...)` callers: account controller, API handler) → **Step 4:** `swift test --filter "StreamingSettingsTests|AccountNotificationsTests|APINotificationsTests"` PASS.
- [ ] **Step 5: Commit** `feat(availability): streaming services and country per user`

---

### Task 7: Tageslauf und Digest

**Files:**
- Create: `Sources/App/Availability/AvailabilityPass.swift`
- Modify: `Sources/App/Catalog/DailyRefresh.swift` (`runDailyPass`, before `runNotifications`), `Sources/App/Notify/NotificationPass.swift`, `Sources/App/Notify/NotificationTexts.swift`
- Test: `Tests/AppTests/AvailabilityPassTests.swift`, `Tests/AppTests/NotificationPassTests.swift`, `Tests/AppTests/NotificationTextsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct AvailabilityPassResult: Equatable, Sendable { var refreshed = 0; var failed = 0; var expired = 0 }
  /// Every title on any list once, tokens of its list users via withAcceptedToken; reconcile after each success; then expire.
  func refreshWatchLaterAvailability(db: any Database, provider: TMDBProvider, cipher: TokenCipher, logger: Logger, now: Date = .now) async -> AvailabilityPassResult
  // NotificationTexts.digest gains `available: [AvailabilityDue]` (default []).
  ```
- Digest copy (§6): section heading `Jetzt bei deinen Diensten:`; line per title `„<Name>“ (<Jahr>, Film|Serie) – <Dienst, Dienst>` plus `  <baseURL>/<tv|movie>/<tmdbID>` when baseURL is set; subject part `"<n> Titel jetzt verfügbar"`; closing line `Verfügbarkeit: JustWatch`. With only availability items the intro reads `es gibt Neues zu deiner Liste „Später ansehen“:` and the TMDB-dates sentence is omitted.
- [ ] **Step 1: Failing tests:**
  - `passFetchesEachListTitleOnce`: two users with the same title → one call; title not on any list → no call.
  - `passSkipsTitleWithoutValidToken` (all list users without token) → `failed == 0`, no call, `refreshed == 0`.
  - `passExpiresOldData`.
  - `NotificationPassTests.availabilityOnlyUserGetsDigest`: user with `notifyAvailable` only, pending item → one mail, notice `.sent`.
  - `NotificationPassTests.sendFailureKeepsPending`.
  - `NotificationTextsTests.digestWithAvailability`: exact subject `"WatchSwifty: 1 Titel jetzt verfügbar"`, body contains `Jetzt bei deinen Diensten:`, `„Dune“ (2024, Film) – Netflix`, `Verfügbarkeit: JustWatch`.
  - `NotificationTextsTests.digestMixed`: episodes + availability → subject joins both parts with `, `.
- [ ] **Step 2:** FAIL → **Step 3:** implement (user query adds `notifyAvailable == true`; `due` from both services; `markSent` after success) → **Step 4:** `swift test --filter "AvailabilityPassTests|NotificationPassTests|NotificationTextsTests|DailyRefreshTests"` PASS.
- [ ] **Step 5: Commit** `feat(notify): daily availability check and digest section`

---

### Task 8: Konto – Streamingdienste und Schalter

**Files:**
- Modify: `Sources/App/Account/AccountController.swift`, `Sources/App/Web/Pages/AccountPage.swift`, `Public/css/app.css`
- Test: `Tests/AppTests/AccountStreamingTests.swift`

**Routes:** `GET /account` (new section, `AccountBlock.streaming`), `POST /account/streaming` (form: `region`, `providers[]`), `GET /account/streaming/providers?region=XX` (htmx: checkbox list for a region).

- [ ] **Step 1: Failing tests:**
  - `accountShowsServicesWithLogos`: Fake regions + providers → page contains `Streamingdienste`, `Netflix`, `https://image.tmdb.org/t/p/w92/n.jpg`, checked box for saved id 8.
  - `saveStreamingPersists`: POST (`.sameOrigin`) region `AT`, providers `[8, 337]` → settings saved; region changed → `app.backgroundTasks.drain()` → fetchMissing ran.
  - `noTokenShowsHint`: user `tmdbToken: nil` → `Für die Auswahl der Dienste wird ein TMDB-Token benötigt`.
  - `notificationsFormHasAvailabilitySwitch`: label `Wenn ein Titel aus „Später ansehen“ bei einem meiner Dienste verfügbar wird`, saving sets `notifyAvailable`.
- [ ] **Step 2:** FAIL → **Step 3:** implement (region select from `providerRegions()` sorted by name, providers = union movie+tv deduped by id, sorted by displayPriority then name; on save run `fetchMissing` via `req.application.backgroundTasks.run`) → **Step 4:** `swift test --filter "AccountStreamingTests|AccountTests|AccountNotificationsTests"` PASS.
- [ ] **Step 5: Commit** `feat(account): streaming services and availability switch`

---

### Task 9: Detailseite – Umschalter und Block „Verfügbarkeit“

**Files:**
- Create: `Sources/App/Web/Components/WatchLaterToggle.swift`, `Sources/App/Web/Components/AvailabilityBlock.swift`, `Sources/App/Availability/AvailabilityController.swift`
- Modify: `Sources/App/Web/Pages/SeriesPage.swift`, `Sources/App/Web/Pages/MoviePage.swift`, `Sources/App/Tracking/TitleController.swift`, `Sources/App/routes.swift`, `Public/css/app.css`
- Test: `Tests/AppTests/AvailabilityPageTests.swift`

**Routes:** `POST /{tv|movie}/:tmdbID/watch-later` (form `watchLater=true|false`, returns `WatchLaterToggle`), `GET /{tv|movie}/:tmdbID/availability` (fragment; refreshes with `req.tmdb` if `needsRefresh`, then renders).

- Toggle copy: `Später ansehen` / `✓ Später ansehen` (class `follow-toggle`, `active` when on).
- Block copy (§5): heading `Verfügbarkeit` + `<span class="muted">` country name; groups `In deinen Abos` (chips `provider mine`, green border, `✓` after name), `Weitere Abos`, `Gratis / mit Werbung`, `<details><summary>Leihen oder kaufen (n Anbieter)</summary>`; no services → single group `Im Abo` + link `Deine Dienste unter Konto festlegen`; no subscription offers → `Derzeit bei keinem Abo-Dienst verfügbar.` (+ `Steht der Titel auf „Später ansehen“, bekommst du eine Nachricht, sobald er bei einem deiner Dienste im Abo läuft.` when on list); loading → `Verfügbarkeit wird geladen …`; footer `Verfügbarkeit: <a href="https://www.justwatch.com/<land lowercase>">JustWatch</a> · Stand TT.MM.JJJJ`. Chip is a link only when `StreamingService(tmdbProviderID:)?.watchLink(for:)` exists.
- Page render: snapshot present and fresh → block inline; otherwise block with `hx-get=".../availability" hx-trigger="load" hx-swap="outerHTML"` and the loading text.

- [ ] **Step 1: Failing tests:**
  - `seriesPageShowsToggleAndLazyBlock`: no availability → page contains `hx-get="/tv/<id>/availability"` and `Verfügbarkeit wird geladen`; no `watch_providers` call during page load.
  - `availabilityFragmentFetchesWhenStale` / `…DoesNotFetchWhenFresh` (call count 1 / 0).
  - `blockGroupsOwnServices`: services `[8]`, offers Netflix + Disney → `In deinen Abos` before `Netflix`, `Weitere Abos` before `Disney+`, contains `Leihen oder kaufen`, `JustWatch`.
  - `noTokenShowsHintAndStoredData`: user without token, list entry, stored snapshot → offers shown plus `Kein TMDB-Token hinterlegt`.
  - `toggleAddsAndRemoves`: POST `watchLater=true` → entry; `false` → gone; foreign user's list untouched (isolation).
- [ ] **Step 2:** FAIL → **Step 3:** implement → **Step 4:** `swift test --filter "AvailabilityPageTests|TitlePagesTests|RenderingTests"` PASS.
- [ ] **Step 5: Commit** `feat(web): availability block and watch later toggle on title pages`

---

### Task 10: Suche, Seite „Später ansehen“, Menüpunkt

**Files:**
- Create: `Sources/App/Availability/WatchLaterController.swift`, `Sources/App/Web/Pages/WatchLaterPage.swift`
- Modify: `Sources/App/Web/Pages/SearchPage.swift` (`SearchResults`), `Sources/App/Tracking/SearchController.swift`, `Sources/App/Tracking/SearchService.swift` (`SearchHit.watchLater: Bool`), `Sources/App/Web/Layout.swift` (`NavItem.watchLater`, label `Später ansehen`, `/watch-later`, between Bibliothek and Statistik), `Sources/App/routes.swift`, `Public/css/app.css`
- Test: `Tests/AppTests/WatchLaterPageTests.swift`, `Tests/AppTests/IsolationTests.swift`

**Routes:** `GET /watch-later?filter=all|tv|movie`, `POST /watch-later` (form `kind`, `tmdbID`; returns the search button), `POST /watch-later/:tmdbKind/:tmdbID/remove` (htmx, returns empty → card removed).

- Search card: link and button become siblings inside `div.card.search-result`; button `+ Später` / `✓ Später` (`hx-post="/watch-later"`, swap outerHTML).
- Page copy (§3.2): `Später ansehen`, filters `Alle`/`Serien`/`Filme`, `Bei deinen Diensten` + count, `Noch nicht bei deinen Diensten` + count, status lines `Im Abo bei <Dienste>`, `Gratis bei <Dienste>`, `Nur leihen oder kaufen`, `Derzeit nirgends verfügbar`, `Verfügbarkeit noch nicht abgefragt`; `neu seit TT.MM.`; button `Entfernen`; footer `Verfügbarkeit in <Land>: JustWatch · Stand <Datum>` + `Titel verschwinden von der Liste, sobald du sie zu schauen beginnst.`; empty `Noch nichts vorgemerkt. In der Suche fügst du Titel mit + Später hinzu.`; no services → hint with link to `/account?open=streaming`.

- [ ] **Step 1: Failing tests:**
  - `searchShowsAddButtonAndState`: result on list → `✓ Später`; others `+ Später`.
  - `addFromSearchCreatesEntry` (POST `.htmx`), page then lists it.
  - `pageGroupsByOwnServices` and `pageShowsNotFetchedYet`.
  - `pageMakesNoTMDBCalls`: `tmdb.calls` empty after GET.
  - `searchDoesNotMarkListTitleAsInLibrary`: title only on list → no episode-count badge.
  - `IsolationTests.watchLaterIsPerUser`: user B removing A's title via route → 404/no effect; B's page does not show A's entries.
- [ ] **Step 2:** FAIL → **Step 3:** implement → **Step 4:** `swift test --filter "WatchLaterPageTests|IsolationTests|HomeHistoryLibraryTests"` PASS.
- [ ] **Step 5: Commit** `feat(web): watch later page, search button and menu entry`

---

### Task 11: App-API

**Files:**
- Modify: `Sources/WatchSwiftyAPI/openapi.yaml`, `Sources/WatchSwiftyClient/OpenValues.swift`, `Sources/WatchSwiftyClient/openapi-generator-config.yaml`
- Create: `Sources/App/API/APIHandler+Availability.swift`
- Modify: `Sources/App/API/APIHandler+Notifications.swift`, `+Series.swift`, `+Movies.swift`, `+Search.swift`
- Test: `Tests/AppTests/APIAvailabilityTests.swift`, `Tests/WatchSwiftyClientTests/…` (known list)

**Interfaces (§7):**
- `GET /v1/watch-later` → `WatchLaterList { items: [WatchLaterItem] }`, item `{ tmdbID, kind, name, year?, posterPath?, addedAt, availability?: Availability, newSince? }`.
- `PUT /v1/tv/{tmdbID}/watch-later`, `PUT /v1/movies/{tmdbID}/watch-later`, body `WatchLaterInput { watchLater: boolean }` → 204.
- `GET /v1/tv/{tmdbID}/availability`, `GET /v1/movies/{tmdbID}/availability` → `Availability { region, fetchedAt, offers: [ProviderOffer] }`, `ProviderOffer { providerID, name, logoPath?, kind: OfferKind, mine: boolean }`.
- `GET|PUT /v1/me/streaming-services` → `StreamingServices { region, providerIDs: [int] }`. A region change starts `fetchMissing` via `backgroundTasks` (same as web).
- `GET /v1/streaming-providers?region=` → `[StreamingProvider { providerID, name, logoPath?, displayPriority }]`; `GET /v1/streaming-regions` → `[StreamingRegion { code, name }]`.
- `NotificationPrefs.titleAvailable: boolean` (spec §7 calls it `available`; renamed so it is not confused with `availableChannels`) (required in response); `NotificationPrefsUpdate.titleAvailable` **optional** (absent → keep stored value, so old apps keep working).
- `SeriesDetail.watchLater`, `MovieDetail.watchLater`, `SearchHit.watchLater`: optional boolean.
- `OfferKind` enum → `OfferKindValue` in `OpenValues.swift` (`flatrate, free, ads, rent, buy`), registered in `typeOverrides`.

- [ ] **Step 1: Failing tests:** round trip for each endpoint with bearer token; `PUT …/watch-later` on unknown tmdbID → 404 via Fake; another user's list invisible; `PUT /v1/me/notifications` without `titleAvailable` keeps `notifyAvailable`; token-less user `GET …/availability` with stale data → existing missing-token error; `OfferKindValue.known` covers the spec enum (client test).
- [ ] **Step 2:** FAIL → **Step 3:** edit spec, implement handlers via the services → **Step 4:** `swift test --filter "APIAvailabilityTests|APINotificationsTests|APISeriesTests|APIHomeSearchMovieTests|WatchSwiftyClientTests"` PASS.
- [ ] **Step 5: Commit** `feat(api): watch later, availability and streaming services endpoints`

---

### Task 12: Doku und Abschluss

**Files:** `docs/notifications.md`, `docs/tmdb.md`, `docs/accounts.md`, `docs/app-api.md`, `README.md` (feature list), `CHANGELOG.md` (`## [Unreleased]`-style section per repo convention, `### Added`), `CLAUDE.md` (feature folder `Availability`, cache-rule note), privacy docs check (§8).

- [ ] **Step 1:** Write docs in English, German UI labels quoted with meaning, e.g. **Später ansehen** (watch later); `docs/tmdb.md` names JustWatch attribution, 30-day deletion, one request per listed title per day; add `DocsLink` in the Konto section to `accounts` page.
- [ ] **Step 2:** `swift build && swift test` → all green.
- [ ] **Step 3:** Start preview (`watchswifty` in `.claude/launch.json`), check search button, list page, detail block, Konto section in the browser; screenshot.
- [ ] **Step 4: Commit** `docs: watch later and streaming availability`
