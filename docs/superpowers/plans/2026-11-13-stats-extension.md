# Statistik erweitern – Umsetzungsplan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Ziel:** Statistik um meistgesehene Folgen/Serien/Filme, längste Filme, Anzahl pro Dienst und Genres erweitern – Web und App-API.

**Architektur:** Alles im bestehenden `StatsService.stats` aus den schon geladenen Sichtungen; „komplett gesehen“ lädt zusätzlich die regulären Folgen der gesehenen Serien. Neue Werte in `Stats`, neue Blöcke auf `StatsPage`, neue optionale Felder in `GET /v1/stats`.

**Tech Stack:** Swift 6.3, Vapor 4, Fluent/SQLite, Elementary + htmx, swift-openapi-generator, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-13-stats-extension-design.md`

## Globale Vorgaben

- UI deutsch, Code/Kommentare/Commits englisch (Conventional Commits). „Today“ = `StatsService.today` (Tests: `2026-11-07`).
- Listen höchstens 5 Einträge (`StatsService.listLimit = 5`); Häufigkeitslisten erst ab 2 Sichtungen.
- Jahresfilter gilt für alles außer `mostCompletedSeries` (immer alle Jahre).
- Neue API-Antwortfelder optional (nicht `required`), Client-Kompatibilität mit älteren Servern.
- Branch `feat/feedback-round`, `swift test` grün je Commit, kein Push.

## Review Focus

1. Film ohne Laufzeit, mehrfach gesehen → in „Meistgesehene Filme“, nicht in „Längste Filme“. *Test Task 1.*
2. Serie mit unerschienener Folge (Datum in der Zukunft oder ohne Datum) und Special → zählen nicht für „komplett“. *Test Task 1.*
3. Titel mit `genres == nil` → fehlt in der Genre-Statistik, kein Absturz. *Test Task 1.*
4. Dienst nur mit Sichtungen ohne Laufzeit → erscheint mit 0 Min. und Anzahl. *Test Task 1.*
5. Jahr ohne Mehrfachsichtungen → Blöcke „Meistgesehene …“ ausgeblendet, Seite rendert. *Test Task 2.*

---

### Task 1: Berechnung in `StatsService`

**Dateien:** Ändern `Sources/App/Tracking/StatsService.swift`; Test `Tests/AppTests/StatsTests.swift` (neue Suite `StatsListsTests`).

**Schnittstellen (neu in `StatsService.swift`):**
```swift
struct MovieStat: Equatable, Sendable { let tmdbID: Int; let name: String; let posterPath: String?; let watches: Int; let minutes: Int; let rating: Int? }
struct EpisodeStat: Equatable, Sendable { let tmdbID: Int; let seriesName: String; let posterPath: String?; let code: String; let season: Int; let number: Int; let name: String; let watches: Int }
struct CompletedSeries: Equatable, Sendable { let tmdbID: Int; let name: String; let posterPath: String?; let completions: Int; let rating: Int? }
struct GenreStat: Equatable, Sendable { let genre: Genre; var seriesMinutes = 0; var movieMinutes = 0; var series = 0; var movies = 0 }
// ServiceShare bekommt: var episodes = 0; var movies = 0
// Stats bekommt: var longestMovies: [MovieStat] = []; var mostWatchedMovies: [MovieStat] = []; var mostWatchedEpisodes: [EpisodeStat] = []
//                var mostCompletedSeries: [CompletedSeries] = []; var genres: [GenreStat] = []
```
Sortierung: längste Filme `(minutes, watches, Name aufsteigend)` absteigend, nur `minutes > 0`; meistgesehene Filme/Folgen `(watches, minutes bzw. Code)` absteigend, nur `watches ≥ 2`; komplett `(completions, Name)`; Genres nach `seriesMinutes + movieMinutes` absteigend, dann Label; Dienste wie bisher nach Minuten, dann Anzahl, dann Label, enthalten jetzt auch Dienste mit 0 Min.
„komplett“: für jede Serie mit Sichtungen die Folgen mit `season ≥ 1` und `airDate ≤ today` (ohne Datum = nicht erschienen); `completions = min(Sichtungen je Folge)`, nur `> 0`, über alle Sichtungen (nicht `inRange`).
Genres: je Titel mit `genreList` (nil → übersprungen) Minuten der Sichtungen im Zeitraum auf jedes Genre; `series`/`movies` = verschiedene Titel.

- [ ] **Schritt 1: Tests** (`StatsListsTests`, eigener Seed): `longestMoviesByTotalTime` (Film A 100 Min. 2×, Film B 150 Min. 1×, Film C ohne Laufzeit 3× → `[A 200, B 150]`); `mostWatchedMoviesFromTwo` (→ `[C 3×, A 2×]`, B fehlt); `mostWatchedEpisodesFromTwo` (S01E01 3×, S01E02 1× → nur S01E01 mit `code == "S01E01"`); `completionsCountAiredRegularEpisodes` (2 Folgen je 2×, unerschienene Folge `2999-01-01`, Special ungesehen → `completions == 2`; eine Folge nur 1× → 1); `completionsIgnoreYearFilter` (Sichtungen 2025, Filter 2026 → trotzdem enthalten); `genresSumPerGenre` (Serie drama+crime 90 Min., Film drama 100 Min., Titel mit `genres: nil` → drama 90/100, 1/1; crime 90/0, 1/0; kein Eintrag für den nil-Titel); `serviceCountsEpisodesAndMovies` (Netflix 2 Folgen + 1 Film ohne Laufzeit → `episodes == 2, movies == 1`); `listsFollowYearFilter` (Mehrfachsichtungen nur 2025 → 2026-Listen leer); `listsCapAtFive` (6 Filme je 2× → 5).
- [ ] **Schritt 2:** `swift test --filter StatsListsTests` → FAIL (Typen fehlen).
- [ ] **Schritt 3:** Umsetzen.
- [ ] **Schritt 4:** `swift test --filter "StatsTests|StatsDashboardTests|StatsListsTests"` → PASS (bestehender `servicesShareByMinutes` mit `ServiceShare(service:minutes:)` muss weiter kompilieren: Initialisierer mit Default-Werten).
- [ ] **Schritt 5: Commit** `feat(stats): most watched episodes, series and movies, longest movies, genres, counts per service`

### Task 2: Statistik-Seite

**Dateien:** Ändern `Sources/App/Web/Pages/StatsPage.swift`, `Sources/App/Web/Components/StatsCharts.swift`, `Public/css/app.css`, `README.md` (Feature-Zeile Statistik); Test `Tests/AppTests/StatsTests.swift`.

Blöcke im Raster `stats-grid` nach „Dienste“: „Längste Serien“ (bisher „Meistgesehen“), „Längste Filme“, „Meistgesehene Serien“ (Untertitel „über alle Jahre“), „Meistgesehene Filme“, „Meistgesehene Folgen“; danach eigener Block „Genres“ (Balken wie `ServiceBars`, zweifarbig Serien/Filme, `ChartLegend`, Hinweis „Ein Titel zählt bei jedem seiner Genres.“). Dienste-Zeile: „12 Std. · 45 % · 80 Folgen · 3 Filme“ (Teile mit 0 weglassen). Listen-Komponente für Filme/Serien wie `TopSeriesList` (Poster, Link, Text, Bewertung).

- [ ] **Schritt 1: Tests** – `statsPageShowsDashboard` anpassen („Längste Serien“ statt „Meistgesehen“); neu `statsPageShowsNewLists` (Seed mit Mehrfachsichtungen und Genres: Body enthält „Längste Filme“, „Meistgesehene Filme“, „3×“, „Meistgesehene Folgen“, „S01E01“, „Meistgesehene Serien“, „2× komplett“, „Genres“, „Drama“, „2 Folgen“); `statsPageHidesEmptyLists` (nur Einfachsichtungen → kein „Meistgesehene Filme“).
- [ ] **Schritt 2:** Tests → FAIL.
- [ ] **Schritt 3:** Umsetzen.
- [ ] **Schritt 4:** Tests grün; im Browser prüfen (Desktop und Handy).
- [ ] **Schritt 5: Commit** `feat(stats): show the new lists, genres and counts per service`

### Task 3: App-API

**Dateien:** Ändern `Sources/WatchSwiftyAPI/openapi.yaml` (Schemas `MovieStat`, `EpisodeStat`, `CompletedSeries`, `GenreStat`; `Stats` + `ServiceShare` erweitern, alles optional, Beschreibungen „up to 5 …, from 2 watches“, „all years“), `Sources/App/API/APIHandler+Stats.swift`, `docs/app-api.md`; Test `Tests/AppTests/APILibraryStatsTests.swift`, `Tests/WatchSwiftyClientTests/OpenValueTests.swift`.

- [ ] **Schritt 1: Tests** – `statsListsInAPI`: `GET /api/v1/stats` liefert `mostWatchedMovies[0].watches == 3`, `mostCompletedSeries[0].completions == 2`, `genres` mit `"drama"`, `services[0].episodes`; Client: `Components.Schemas.Stats` dekodiert eine Antwort ohne die neuen Felder.
- [ ] **Schritt 2:** Tests → FAIL.
- [ ] **Schritt 3:** Umsetzen (Genre über `Components.Schemas.Genre(rawValue:)`).
- [ ] **Schritt 4:** `swift test` komplett grün.
- [ ] **Schritt 5: Commit** `feat(api): new statistics in GET /v1/stats`
