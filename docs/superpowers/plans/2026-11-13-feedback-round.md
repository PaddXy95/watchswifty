# Feedback-Runde – Umsetzungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Ziel:** Die zwölf Rückmeldungen aus der Nutzung von 0.4.0 umsetzen (UI-Fixes, Import-Infos, Webhook ohne Passwort, Genres mit Bibliotheksfilter, aufklappbare Folgen, Dienst bei Staffel/Serie, einklappbare System-Seite) – Web und App-API.

**Architektur:** Kleine, voneinander unabhängige Änderungen an Web-Komponenten und Services; neue Daten nur bei Genres (Spalte `titles.genres` + Mapping-Enum `Genre`). Jede neue Information geht über den Service, den Web und API teilen; die API bekommt die Felder aus der Tabelle „App-API“ der Spec.

**Tech Stack:** Swift 6.3, Vapor 4, Fluent/SQLite, Elementary + htmx, swift-openapi-generator, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-13-feedback-round-design.md` (Punkte §1–§13, Tabelle „App-API“).

## Globale Vorgaben

- Alles Sichtbare deutsch; Code, Kommentare, Commit-Messages englisch (Conventional Commits). Englische Doku zitiert deutsche UI-Texte wörtlich mit englischer Bedeutung in Klammern.
- `ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility`: jedes genutzte Modul importieren.
- Neue Migration ans **Ende** der Liste in `configure.swift`.
- Kein eigenes JavaScript; nur htmx und native HTML-Mittel (`<details>`, `popover`).
- API zuerst in `Sources/WatchSwiftyAPI/openapi.yaml` ändern, dann Handler. Neue Antwortfelder als `required`, neue Eingaben optional.
- Arbeit auf neuem Branch `feat/feedback-round` (von `beta`). `swift test` grün bei jedem Commit. Kein Push.
- Kein Release: `VERSION`/CHANGELOG-Abschnitt nicht anfassen.

## Review Focus

1. Genre-Filter mit einem Schlüssel, den es nicht gibt (`?genre=quatsch`, Web) → Filter ignoriert, Seite lädt normal; API → 400 wie bei unbekanntem `filter`. *Test in Task 7.*
2. Titel mit `genres == nil` (noch nicht nachgeladen) → erscheint ohne Genre, Filter schließt ihn aus, keine Abstürze; Bibliotheks-Auswahl zeigt nur vorhandene Genres. *Test in Task 7.*
3. Gleicher TMDB-Kandidat in zwei „Zu prüfen“-Einträgen → Popover-IDs eindeutig (sonst öffnet der falsche). *Test in Task 5.*
4. „Ganze Staffel gesehen“ mit „unbekannt“ → Sichtungen ohne Dienst (nicht der zuletzt genutzte). *Test in Task 9.*
5. Checkbox einer aufgeklappten Folge → nach dem Swap ist alles zu (kein `open` ohne `open=1`). *Test in Task 8.*

---

### Task 1: Kleine UI-Fixes (§1 Version, §6 Abstand Konto)

**Dateien:**
- Ändern: `Sources/App/Web/Components/SiteFooter.swift`, `Sources/App/Web/Layout.swift`, `Public/css/app.css`
- Test: `Tests/AppTests/RenderingTests.swift`

**Schnittstellen:** `SiteFooter(updateVersion: String?, showVersion: Bool)`; `PageLayout` übergibt `showVersion: nav != nil`.

- [ ] **Schritt 1: Test schreiben** – `@Test func footerHidesVersionWithoutLogin()`: `GET /login` → Body enthält nicht `class="version"`; eingeloggt `GET /library` → enthält `class="version"`.
- [ ] **Schritt 2:** `swift test --filter RenderingTests` → FAIL.
- [ ] **Schritt 3:** `showVersion` umsetzen (ohne Version auch kein Update-Hinweis). CSS: `.notification-prefs` und das Test-Formular bekommen Abstand (z. B. `.notification-prefs button { margin-top: var(--space-2) }` und Abstand oberhalb des Testnachricht-Formulars), „Senden per …“ nicht direkt am Knopf.
- [ ] **Schritt 4:** Test grün; Abstand im Browser prüfen (Konto → Benachrichtigungen, mit nur einem Weg).
- [ ] **Schritt 5: Commit** `fix(web): hide the version without login, space the notification buttons`

### Task 2: Texte (§2 Netflix-Anleitung, §3 Pocket ID)

**Dateien:**
- Ändern: `Sources/App/Web/Pages/ImportPage.swift:26`, `docs/import.md`, `Sources/App/Web/Pages/SystemPage.swift:301,318`, `docs/sso.md`
- Test: `Tests/AppTests/ImportPageTests.swift`, `Tests/AppTests/SystemOIDCTests.swift`

- [ ] **Schritt 1: Tests** – `pageShowsSections` zusätzlich: Body enthält `Konto → Einstellungen → Titelverlauf` und `„Alle herunterladen“`. In `SystemOIDCTests` neu `placeholderNamesPocketID`: System-Seite enthält `z. B. Pocket ID` und nicht `z. B. Authentik`.
- [ ] **Schritt 2:** Tests → FAIL.
- [ ] **Schritt 3:** Import-Text exakt: `Netflix im Browser: Konto → Einstellungen → Titelverlauf → ganz unten „Alle herunterladen“. Die Datei heißt NetflixViewingHistory.csv.` OIDC-Intro: Aufzählung beginnt mit „Pocket ID, Authentik, Keycloak, Authelia …“. `docs/import.md` Schritt 1 entsprechend (**Konto** → **Einstellungen** → **Titelverlauf** (viewing history) → **Alle herunterladen** (download all)). `docs/sso.md`: Pocket ID zuerst in Liste und Provider-Hinweisen, Beispiel-Anzeigename „Pocket ID“.
- [ ] **Schritt 4:** Tests grün.
- [ ] **Schritt 5: Commit** `docs: Netflix path „Titelverlauf“, Pocket ID as the SSO example`

### Task 3: Webhook-Schlüssel ohne Passwort (§5)

**Dateien:**
- Ändern: `Sources/App/Notify/NotificationPrefsService.swift`, `Sources/App/Account/AccountController.swift`, `Sources/App/Web/Pages/AccountPage.swift` (`AccountNotifications.needsPassword` und Passwortfelder entfernen), `Sources/App/API/APIHandler+Notifications.swift`, `Sources/WatchSwiftyAPI/openapi.yaml` (setWebhookKey/deleteWebhookKey-Texte, `WebhookKeyChange.currentPassword`/`WebhookKeyRemove.currentPassword` mit `deprecated: true` und „Ignored; kept for older apps.“), `docs/notifications.md`, `docs/app-api.md`, `docs/superpowers/specs/2026-11-11-notifications-design.md` (Regel durchstreichen + Verweis auf 2026-11-13)
- Test: `Tests/AppTests/AccountNotificationsTests.swift`, `Tests/AppTests/APINotificationsTests.swift`

**Schnittstellen:** `NotificationPrefsService.setWebhookKey(user: User, key: String) async throws` (Parameter `currentPassword` entfällt; `hasher` bleibt nur, falls noch gebraucht).

- [ ] **Schritt 1: Tests umbauen** – `keyWithWrongPasswordFails` → `keySavedWithoutPassword` (POST nur `key` → 200, „Webhook-Schlüssel gespeichert.“, `webhookKey != nil`); `removeKey` ohne `currentPassword`; Seite enthält im Webhook-Block kein `name="currentPassword"`. API: `keyNeedsPassword` → `keyIgnoresPassword` (PUT mit `currentPassword: "falsch"` → 200; DELETE ohne Body → 200/204 wie bisher).
- [ ] **Schritt 2:** Tests → FAIL.
- [ ] **Schritt 3:** Umsetzen; `swift build` (Generator) muss mit dem geänderten YAML durchlaufen.
- [ ] **Schritt 4:** `swift test --filter "AccountNotificationsTests|APINotificationsTests|DeviceNoticeTests"` grün.
- [ ] **Schritt 5: Commit** `feat(notify): webhook key without the current password`

### Task 4: „Zu prüfen“ mit Sichtungsdaten (§4)

**Dateien:**
- Ändern: `Sources/App/Web/Components/ImportComponents.swift` (`ReviewItem`, `MappingReviewItem`), `Sources/App/Import/ImportStateService.swift:33`, `Sources/WatchSwiftyAPI/openapi.yaml` (`MappingReview`: `firstDay`, `lastDay`, `rows` – Items `{rawTitle, day}` als neues Schema `ReviewRow`, alle required), `Sources/App/API/APIHandler+NetflixImport.swift:34`, `docs/import.md`
- Test: `Tests/AppTests/ImportPageTests.swift`, `Tests/AppTests/APINetflixImportTests.swift`

**Schnittstellen:**
```swift
struct ReviewItem {
    let mapping: NetflixMapping
    let rows: [NetflixRow]            // offene Zeilen, neueste zuerst (watchedOn absteigend, dann rawTitle)
    static let rowLimit = 20
    var rowCount: Int                 // rows.count
    var firstDay: String              // ältestes watchedOn
    var lastDay: String               // neuestes watchedOn
    var shownRows: ArraySlice<NetflixRow>   // rows.prefix(rowLimit)
}
```

- [ ] **Schritt 1: Tests** – Web: `reviewShowsWatchDate` (Fixture: Rick and Morty, eine Zeile → Body enthält `gesehen am 06.11.2026`); `reviewShowsDateRange` (eigenes CSV mit zwei Zeilen desselben unklaren Namens an `3/2/25` und `11/6/26` → `gesehen 02.03.2025 – 06.11.2026`, beide Zeilen im `<details>`). API: Review-Eintrag hat `firstDay == lastDay == "2026-11-06"` und `rows.count == 1`.
- [ ] **Schritt 2:** Tests → FAIL.
- [ ] **Schritt 3:** Umsetzen. Markup: `p.muted` „N Zeilen · Serie · gesehen am …/gesehen … – …“, darunter `details { summary { "Zeilen anzeigen" } ul { li { rawTitle · Datum } } }`, bei mehr als 20: `li.muted { "… und N weitere" }`. API: `rows` = `shownRows`.
- [ ] **Schritt 4:** `swift test --filter "ImportPageTests|APINetflixImportTests"` grün.
- [ ] **Schritt 5: Commit** `feat(import): show when a row to review was watched`

### Task 5: Kandidaten mit großem Poster und TMDB-Link (§4.1)

**Dateien:**
- Ändern: `Sources/App/Web/Components/ImportComponents.swift` (`CandidateList` nutzt `CandidateRow`), `Sources/App/Web/Pages/FilmListPage.swift:112-118`, `Public/css/app.css` (`.candidate`, `.poster-popover`)
- Neu: `CandidateRow` in `ImportComponents.swift`
- Test: `Tests/AppTests/ImportPageTests.swift` (`CandidateLabelTests`), `Tests/AppTests/FilmListTests.swift`

**Schnittstellen:**
```swift
struct CandidateRow: HTML {
    let result: TMDBSearchResult
    let popoverID: String      // eindeutig pro Seite, z. B. "poster-\(mappingID)-\(result.id)" bzw. "poster-film-\(entryID)-\(result.id)"
    let acceptURL: String
    let vals: String           // hx-vals-JSON
    let target: String
}
```
Markup: `div.candidate { button.poster-button(type=button, popovertarget=popoverID, aria-label „Poster von … vergrößern“) { Poster 40 } div(popover, id) { Poster displayWidth 342 } span { name (Jahr) } a(href "https://www.themoviedb.org/\(kind)/\(id)", target _blank, rel noopener noreferrer) { "TMDB ↗" } button.primary(hx-post acceptURL, hx-vals, hx-target, hx-swap outerHTML) { "Übernehmen" } }`. Ohne Poster: Platzhalter ohne Button.

- [ ] **Schritt 1: Tests** – `candidateLabel` anpassen: enthält `Aftermath (2021)`, `https://www.themoviedb.org/movie/1`, `popovertarget=`, `>Übernehmen<`; `candidatePopoverIDsUnique`: zwei `CandidateList` mit verschiedenen `mappingID` und gleichem Ergebnis → zwei verschiedene `id="poster-…"`. Filmliste: Seite enthält TMDB-Link des Kandidaten.
- [ ] **Schritt 2:** Tests → FAIL.
- [ ] **Schritt 3:** Umsetzen; CSS: Popover zentriert, max. 90 vw, `::backdrop` abgedunkelt.
- [ ] **Schritt 4:** Tests grün; im Browser Poster öffnen/schließen (Klick daneben, Escape) prüfen.
- [ ] **Schritt 5: Commit** `feat(import): larger poster and TMDB link for candidates`

### Task 6: Genres speichern (§7, Daten)

**Dateien:**
- Neu: `Sources/App/Catalog/Genre.swift`, `Tests/AppTests/GenreTests.swift`
- Ändern: `Sources/App/TMDB/TMDBClient.swift` (`TMDBSeries.genreIDs`, `TMDBMovie.genreIDs`, je `var … : [Int] = []`), `Sources/App/TMDB/LiveTMDBClient.swift` (`genres: [{id}]` dekodieren), `Sources/App/Catalog/Title.swift` (`@OptionalField(key: "genres") var genres: String?`), `Sources/App/Catalog/CatalogMigrations.swift` (`AddTitleGenres`), `Sources/App/configure.swift`, `Sources/App/Catalog/CatalogService.swift`, `Sources/App/Tracking/SeriesDetailService.swift:29`, `Sources/App/Catalog/DailyRefresh.swift`, `Sources/App/Catalog/CatalogMaintenance.swift:113-130`
- Test: `GenreTests`, `TMDBTests`, `CatalogServiceTests`, `RuntimeTests`, `CatalogMaintenanceTests`

**Schnittstellen:**
```swift
enum Genre: String, CaseIterable, Sendable {
    case action, adventure, animation, comedy, crime, documentary, drama, family, fantasy, history, horror, music,
         mystery, romance, scienceFiction = "science_fiction", tvMovie = "tv_movie", thriller, war, western,
         kids, news, reality, soap, talk, politics
    var label: String                                  // deutsch, s. u.
    static func from(tmdbIDs: [Int]) -> [Genre]        // Reihenfolge des ersten Auftretens, ohne Doppelte, unbekannte IDs ignoriert
    static func sortedByLabel(_ genres: some Sequence<Genre>) -> [Genre]
}
extension Title { var genreList: [Genre]? { get set } }   // nil ⇔ genres == nil; "" ⇔ []; Speicherung "action,adventure"
```
Labels: Action, Abenteuer, Animation, Komödie, Krimi, Dokumentation, Drama, Familie, Fantasy, Historie, Horror, Musik, Mystery, Liebesfilm, Science-Fiction, TV-Film, Thriller, Krieg, Western, Kinder, Nachrichten, Reality, Soap, Talk, Politik.
TMDB-IDs: 28 action, 12 adventure, 16 animation, 35 comedy, 80 crime, 99 documentary, 18 drama, 10751 family, 14 fantasy, 36 history, 27 horror, 10402 music, 9648 mystery, 10749 romance, 878 scienceFiction, 10770 tvMovie, 53 thriller, 10752 war, 37 western, 10762 kids, 10763 news, 10764 reality, 10766 soap, 10767 talk; **10759 → action + adventure, 10765 → scienceFiction + fantasy, 10768 → war + politics**.

- [ ] **Schritt 1: Tests** – `GenreTests`: `from(tmdbIDs: [10759, 28, 99999]) == [.action, .adventure]`; `from([10765]) == [.scienceFiction, .fantasy]`; `from([10768]) == [.war, .politics]`; `genreList` Round-Trip inkl. `[]` ↔ `""` und `nil`. `TMDBTests`: `decodeSeries`/`decodeMovie` mit `"genres":[{"id":18,"name":"Drama"}]` → `genreIDs == [18]`, ohne Feld → `[]`. `CatalogServiceTests`: Refresh von Serie mit `genreIDs: [10759]` → `title.genres == "action,adventure"`; Film ohne Genres → `""`. `RuntimeTests`: gesehener Titel mit `runtime` gesetzt, `genres == nil` → wird von `titlesMissingDetails` geliefert und nachgeladen. `CatalogMaintenanceTests`: nach 180 Tagen ohne Refresh ist `genres == nil`.
- [ ] **Schritt 2:** Tests → FAIL.
- [ ] **Schritt 3:** Umsetzen. `titlesMissingRuntime`/`backfillRuntimes` umbenennen in `titlesMissingDetails`/`backfillDetails` (Filter `runtime == nil OR genres == nil`), Aufrufer und Tests mitziehen. `refreshForDetails`: auch bei `title.genres == nil` voller Refresh. `clearTMDBTexts`: `genres` mit löschen (auch in der Guard-Bedingung). `FakeTMDBClient` braucht keine Änderung (Default `[]`).
- [ ] **Schritt 4:** `swift test` komplett grün (Migration läuft in jedem Test).
- [ ] **Schritt 5: Commit** `feat(catalog): store TMDB genres as one shared list`

### Task 7: Genres anzeigen, Bibliothek filtern, API (§7)

**Dateien:**
- Ändern: `Sources/App/Web/Pages/SeriesPage.swift`, `Sources/App/Web/Pages/MoviePage.swift`, `Sources/App/Tracking/LibraryService.swift`, `Sources/App/Tracking/LibraryController.swift`, `Sources/App/Web/Pages/LibraryPage.swift`, `Public/css/app.css`, `Sources/WatchSwiftyAPI/openapi.yaml` (Schema `Genre` = String-Enum der Rohwerte; `genres` required an `SeriesDetail`, `MovieDetail`, `LibraryEntry`; Query `genre` an `getLibrary`), `Sources/App/API/APIHandler+Library.swift`, `APIHandler+Series.swift`, `APIHandler+Movies.swift`, `Sources/WatchSwiftyClient/OpenValues.swift` (`GenreValue`), `Sources/WatchSwiftyClient/openapi-generator-config.yaml` (`Genre: GenreValue`), `docs/app-api.md`
- Test: `Tests/AppTests/TitlePagesTests.swift`, `Tests/AppTests/HomeHistoryLibraryTests.swift`, `Tests/AppTests/APILibraryStatsTests.swift`, `Tests/AppTests/APISeriesTests.swift`, `Tests/WatchSwiftyClientTests/OpenValueTests.swift`

**Schnittstellen:**
- `LibraryService.items(userID: UUID, filter: String, sort: String, genre: Genre? = nil) async throws -> [LibraryItem]`
- `LibraryService.availableGenres(userID: UUID) async throws -> [Genre]` – Genres aller Titel der eigenen Bibliothek (inkl. ausgeblendeter), `Genre.sortedByLabel`.
- `LibraryPage(navContext:items:filter:sort:genre: Genre?, genres: [Genre])`
- Web-Parameter `genre` mit unbekanntem Wert → `nil`; API mit unbekanntem Wert → 400 (vom Generator).

- [ ] **Schritt 1: Tests** – Serienseite mit `genres = "drama,crime"` zeigt `Drama · Krimi`; Filmseite zeigt Genres hinter der Laufzeit. Bibliothek: zwei gesehene Titel (Drama / Komödie), `GET /library?genre=drama` zeigt nur den Drama-Titel, Auswahl enthält genau „Drama“ und „Komödie“; `?genre=quatsch` → 200 mit beiden; Titel mit `genres == nil` erscheint ungefiltert, bei `?genre=drama` nicht; Filter-/Sortierlinks behalten `genre=drama`. API: `GET /api/v1/library?genre=drama` filtert, Einträge haben `genres`; `GET /api/v1/tv/{id}` und `/movies/{id}` liefern `genres`; `?genre=quatsch` → 400. Client: `GenreValue.known.map(\.rawValue)` == Liste der Rohwerte in Enum-Reihenfolge.
- [ ] **Schritt 2:** Tests → FAIL.
- [ ] **Schritt 3:** Umsetzen. Bibliothek: `form.genre-filter` mit verstecktem `filter`/`sort`, `select(name: genre)` (erste Option „Alle Genres“ = leer), `hx-get="/library"`, `hx-trigger="change"`, `hx-target="main"`, `hx-select="main"`, `hx-swap="outerHTML"`, `hx-push-url="true"`; ohne vorhandene Genres keine Auswahl.
- [ ] **Schritt 4:** `swift test` komplett grün.
- [ ] **Schritt 5: Commit** `feat(library): genres on detail pages and a genre filter`

### Task 8: Folgen aufklappbar (§8)

**Dateien:**
- Ändern: `Sources/App/Web/Components/SeasonSection.swift` (`SeasonModel.openEpisode: Int? = nil`, `EpisodeRow`), `Sources/App/Web/Components/WatchForm.swift` (`var keepOpen = false` → `input hidden name=open value=1`), `Sources/App/Tracking/TitleController.swift` (`WatchInput.open: String?`; `seasonResponse(..., openEpisode: Int?)`; `markEpisode` setzt `openEpisode` bei `open == "1"`; `markUpTo` setzt ihn immer für die Folge), `Public/css/app.css` (`.episode-row` als Grid, `.episode-menu`-Regeln ersetzen)
- Test: `Tests/AppTests/TitlePagesTests.swift`

Markup je Folge: `div.episode-row#ep-S-N { checkbox; details.episode[open?] { summary.episode-summary { span.code; span.name.episode-title; span.runtime; span.meta } div.episode-panel { Beschreibung; WatchForm(keepOpen: true); „bis hier gesehen“ } } }`. Ohne Panel-Inhalt (nicht erschienen, keine Beschreibung): `div.episode-summary` mit denselben Spans statt `<details>`. Titel als Knopf gestaltet (Akzentfarbe, ▸/▾-Marker).

- [ ] **Schritt 1: Tests** – `episodesStartClosed`: Serienseite enthält `<details class="episode"` und kein `<details class="episode" open`. `watchFromFormKeepsEpisodeOpen`: POST `/tv/1399/episodes/1/1/watch` mit `day`, `service`, `open=1` → im Abschnitt zwischen `id="ep-1-1"` und `id="ep-1-2"` steht `<details class="episode" open`, sonst nirgends. `checkboxLeavesAllClosed`: POST ohne `open` → kein `<details class="episode" open`. `upToKeepsEpisodeOpen`: POST `watch-up-to` für 1/2 → `ep-1-2` offen.
- [ ] **Schritt 2:** Tests → FAIL.
- [ ] **Schritt 3:** Umsetzen.
- [ ] **Schritt 4:** `swift test --filter TitlePagesTests` grün; im Browser auf- und zuklappen, „Gesehen“ hält die Folge offen, Checkbox klappt nichts auf.
- [ ] **Schritt 5: Commit** `feat(series): episode title opens its details, the watched episode stays open`

### Task 9: Dienst bei Staffel, Serie und „bis hier“ (§12)

**Dateien:**
- Neu: `ServiceSelect` in `Sources/App/Web/Components/WatchForm.swift` (`label „Dienst“ + select name=service`, Option „unbekannt“ = leer, `selected: StreamingService?`); `WatchForm` nutzt ihn.
- Ändern: `Sources/App/Web/Components/SeasonSection.swift` (Staffel-Knopf → `form.season-action` mit `ServiceSelect` + Knopf „Ganze Staffel gesehen“), `Sources/App/Web/Pages/SeriesPage.swift` (Serien-Knopf → `form.series-action` mit `ServiceSelect` + Knopf „Gesamte Serie gesehen“, `hx-confirm` am Formular), `WatchForm` (`var upToAction: String? = nil` → zweiter Knopf `type=button` mit `hx-post` auf `watch-up-to`, Ziel `#seasons`; htmx schickt die Formularwerte mit), `Public/css/app.css`
- Test: `Tests/AppTests/TitlePagesTests.swift`

- [ ] **Schritt 1: Tests** – `seasonWithChosenService`: POST `/tv/1399/seasons/1/watch` mit `service=prime_video` → alle Sichtungen `prime_video`. `seasonWithUnknownService`: vorher eine Netflix-Sichtung, dann `service=` (leer) → neue Sichtungen ohne Dienst. `upToTakesService`: POST `watch-up-to` mit `service=wow` → Sichtungen `wow`. `seasonFormPreselectsLastService`: nach einer Netflix-Sichtung enthält der Staffel-Block `<option value="netflix" selected`.
- [ ] **Schritt 2:** Tests → FAIL (Markup-Test; die Controller-Tests können schon grün sein – dann nur Markup nachziehen).
- [ ] **Schritt 3:** Umsetzen.
- [ ] **Schritt 4:** `swift test --filter TitlePagesTests` grün; im Browser Staffel und Serie mit Dienst markieren.
- [ ] **Schritt 5: Commit** `feat(series): choose the service when marking a season or the whole series`

### Task 10: System-Seite einklappbar (§10)

**Dateien:**
- Ändern: `Sources/App/Web/Pages/SystemPage.swift` (`enum SystemBlock: String { case updates, mail, notifications, oidc }`; `SystemPage.openBlock: SystemBlock?`; „Version“ + „Updates“ zu einem Block „Version & Updates“; `MailSection`, `NotificationsSection`, `OIDCSection` bekommen `var open = false` und rendern `details.system-block#block-<raw>[open] { summary { h2 } … }`), `Sources/App/Admin/SystemController.swift` (`page(..., open: SystemBlock?)`; jede Aktion übergibt ihren Block, auch auf Fehlerwegen; `show` liest `?open=`), `Sources/App/Web/Components/SiteFooter.swift` (Update-Link `/admin/system?open=updates`), `Public/css/app.css`
- Test: `Tests/AppTests/SystemMailTests.swift`, `Tests/AppTests/UpdateCheckTests.swift`

- [ ] **Schritt 1: Tests** – `systemBlocksStartClosed`: `GET /admin/system` enthält vier `class="system-block"` und kein `class="system-block" id="block-…" open`. `savedBlockStaysOpen`: nach Speichern der Mail-Einstellungen enthält die Antwort `id="block-mail" open`; nach „Jetzt prüfen“ `id="block-updates" open`. `openQueryOpensBlock`: `GET /admin/system?open=updates` → `id="block-updates" open`; `?open=quatsch` → alle zu.
- [ ] **Schritt 2:** Tests → FAIL. (Vorhandene Tests, die Texte in den Blöcken suchen, bleiben grün – `<details>` rendert den Inhalt mit.)
- [ ] **Schritt 3:** Umsetzen (Attributreihenfolge `class`, `id`, dann `open`, damit die Tests stabil sind).
- [ ] **Schritt 4:** `swift test` komplett grün; im Browser auf- und zuklappen, Speichern lässt den Block offen.
- [ ] **Schritt 5: Commit** `feat(system): collapsible blocks, the block of the last action stays open`

### Task 11: Abschluss

- [ ] **Schritt 1:** `swift test` komplett grün; `swift build` ohne Warnungen aus den geänderten Dateien.
- [ ] **Schritt 2:** Browser-Durchgang (Preview `watchswifty`): Login ohne Version, Import (Daten, Popover, TMDB-Link), Konto (Abstände, Schlüssel ohne Passwort), Serie (Genres, Folgen, Dienst), Film (Genres), Bibliothek (Genre-Filter, auch mobil), System (Blöcke).
- [ ] **Schritt 3:** Spec-Status bleibt „freigegeben“; README nur, falls ein Feature-Punkt fehlt (Genres in der Feature-Liste ergänzen).
- [ ] **Schritt 4: Commit** (falls Änderungen) `docs: feedback round`
