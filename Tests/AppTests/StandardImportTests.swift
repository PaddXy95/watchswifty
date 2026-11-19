@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("StandardImport")
struct StandardImportTests {
    static let today = "2026-11-07"
    static let dune = TMDBSearchResult(id: 438631, kind: .movie, name: "Dune", originalName: nil, year: 2021, posterPath: nil)
    static let dune84 = TMDBSearchResult(id: 841, kind: .movie, name: "Dune", originalName: nil, year: 1984, posterPath: nil)
    static let severance = TMDBSearchResult(id: 95396, kind: .tv, name: "Severance", originalName: nil, year: 2022, posterPath: nil)

    static func severanceSeries(seasons: [Int]) -> TMDBSeries {
        TMDBSeries(id: 95396, name: "Severance", originalName: nil, year: 2022, posterPath: nil, status: "Returning Series",
                   seasonNumbers: seasons)
    }

    static func fake() -> FakeTMDBClient {
        let tmdb = FakeTMDBClient()
        tmdb.addMovie(TMDBMovie(id: 438631, name: "Dune", originalName: nil, year: 2021, posterPath: nil, runtime: 155))
        tmdb.addMovie(TMDBMovie(id: 841, name: "Dune", originalName: nil, year: 1984, posterPath: nil, runtime: 137))
        tmdb.addSeries(severanceSeries(seasons: [0, 1]), episodes: [0: ["Special"], 1: ["E1", "E2", "E3"]])
        tmdb.setFind("tt1520211", TMDBFindResult(movies: [dune]))
        tmdb.setFind("tt99", TMDBFindResult(episodeShowIDs: [95396]))
        tmdb.setSearch("movie", "Dune", [dune, dune84])
        tmdb.setSearch("tv", "Severance", [severance])
        return tmdb
    }

    static func draft(_ kind: TitleKind, _ title: String, year: Int? = nil, tmdb: Int? = nil, imdb: String? = nil,
                      watches: [ImportWatch] = [], rating: Int? = nil, comment: String? = nil) -> ImportDraft {
        ImportDraft(kind: kind, title: title, year: year, tmdbHint: tmdb, imdbID: imdb, watches: watches, rating: rating, comment: comment)
    }

    static func watch(_ day: String? = nil, season: Int? = nil, episode: Int? = nil, service: StreamingService? = nil) -> ImportWatch {
        ImportWatch(season: season, episode: episode, day: day, service: service)
    }

    func entries(_ app: Application, _ user: User, _ drafts: [ImportDraft]) async throws -> [ImportEntry] {
        let service = ImportEntryService(db: app.db)
        try await service.replace(userID: user.requireID(), drafts: drafts)
        return try await service.entries(userID: user.requireID())
    }

    func importer(_ app: Application, _ tmdb: FakeTMDBClient) -> StandardImporter {
        StandardImporter(db: app.db, tmdb: tmdb, today: Self.today)
    }

    func title(_ app: Application, _ tmdbID: Int) async throws -> Title {
        try #require(try await Title.query(on: app.db).filter(\.$tmdbID == tmdbID).first())
    }

    func watches(_ app: Application, _ title: Title) async throws -> [Watch] {
        try await Watch.query(on: app.db).filter(\.$title.$id == title.requireID()).sort(\.$watchedOn).all()
    }

    func reload(_ app: Application, _ entry: ImportEntry) async throws -> ImportEntry {
        try #require(try await ImportEntry.find(entry.requireID(), on: app.db))
    }

    // MARK: Matching

    @Test func idMatchIsAutomatic() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let entry = try await entries(app, user, [Self.draft(.movie, "Dune", year: 2021, tmdb: 438631, watches: [Self.watch("2024-03-02")])])[0]
            try await importer(app, tmdb).resolve(entry)
            let saved = try await reload(app, entry)
            #expect(saved.entryStatus == .imported)
            #expect(saved.tmdbID == 438631)
            #expect(saved.addedWatches == 1)
            #expect(try await watches(app, try await title(app, 438631)).count == 1)
            #expect(!tmdb.calls.contains { $0.hasPrefix("search:") })
        }
    }

    @Test func implausibleIDGoesToReview() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let entry = try await entries(app, user, [Self.draft(.movie, "Severance", year: 2024, tmdb: 438631)])[0]
            try await importer(app, tmdb).resolve(entry)
            let saved = try await reload(app, entry)
            #expect(saved.entryStatus == .review)
            #expect(saved.candidateList.first?.id == 438631)
            #expect(try await Watch.query(on: app.db).count() == 0)
        }
    }

    @Test func unknownTMDBIDFallsBackToSearch() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let entry = try await entries(app, user, [Self.draft(.tv, "Severance", tmdb: 1)])[0]
            try await importer(app, tmdb).resolve(entry)
            let saved = try await reload(app, entry)
            #expect(saved.entryStatus == .imported)
            #expect(saved.tmdbID == 95396)
        }
    }

    @Test func imdbIDFindsMovie() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let entry = try await entries(app, user, [Self.draft(.movie, "Der Wüstenplanet", year: 2021, imdb: "tt1520211")])[0]
            try await importer(app, tmdb).resolve(entry)
            #expect(try await reload(app, entry).tmdbID == 438631)
        }
    }

    @Test func imdbEpisodeIDResolvesSeries() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let entry = try await entries(app, user, [Self.draft(.tv, "Severance", imdb: "tt99")])[0]
            try await importer(app, tmdb).resolve(entry)
            let saved = try await reload(app, entry)
            #expect(saved.entryStatus == .imported)
            #expect(saved.tmdbID == 95396)
        }
    }

    @Test func titleSearchAmbiguousGoesToReview() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let list = try await entries(app, user, [Self.draft(.movie, "Dune"), Self.draft(.movie, "Nichts")])
            try await importer(app, tmdb).resolve(list[0])
            try await importer(app, tmdb).resolve(list[1])
            let ambiguous = try await reload(app, list[0])
            #expect(ambiguous.entryStatus == .review)
            #expect(ambiguous.candidateList.map(\.id) == [438631, 841])
            #expect(try await reload(app, list[1]).entryStatus == .notFound)
        }
    }

    // MARK: Recording

    @Test func episodesAreRecorded() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let entry = try await entries(app, user, [Self.draft(.tv, "Severance", watches: [
                Self.watch("2024-05-10", season: 1, episode: 1, service: .appleTV),
                Self.watch(season: 1, episode: 3),
                Self.watch(season: 2, episode: 1),
            ])])[0]
            try await importer(app, tmdb).record(entry, tmdbID: 95396)
            let list = try await watches(app, try await title(app, 95396))
            #expect(list.count == 2)
            #expect(list.allSatisfy { $0.watchOrigin == .manual && $0.$episode.id != nil })
            #expect(list.first { $0.watchedOn == "2024-05-10" }?.streamingService == .appleTV)
            let saved = try await reload(app, entry)
            #expect(saved.missingEpisodes == 1)
            #expect(saved.addedWatches == 2)
            #expect(saved.entryStatus == .imported)
        }
    }

    @Test func specialsMatch() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let entry = try await entries(app, user, [Self.draft(.tv, "Severance", watches: [Self.watch(season: 0, episode: 1)])])[0]
            try await importer(app, tmdb).record(entry, tmdbID: 95396)
            let list = try await watches(app, try await title(app, 95396))
            #expect(list.count == 1)
            let episode = try #require(try await Episode.find(list[0].$episode.id, on: app.db))
            #expect(episode.season == 0)
        }
    }

    @Test func staleCacheRefreshesOnce() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let first = try await entries(app, user, [Self.draft(.tv, "Severance", watches: [Self.watch(season: 1, episode: 1)])])[0]
            try await importer(app, tmdb).record(first, tmdbID: 95396)
            tmdb.addSeries(Self.severanceSeries(seasons: [0, 1, 2]), episodes: [0: ["Special"], 1: ["E1", "E2", "E3"], 2: ["N1"]])
            let second = try await entries(app, user, [Self.draft(.tv, "Severance", watches: [Self.watch(season: 2, episode: 1)])])[0]
            try await importer(app, tmdb).record(second, tmdbID: 95396)
            #expect(try await watches(app, try await title(app, 95396)).count == 2)
            #expect(try await reload(app, second).missingEpisodes == 0)
            #expect(tmdb.calls.filter { $0 == "series:95396" }.count == 2)
        }
    }

    @Test func reimportDoesNotDuplicate() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let movie = try await CatalogService(db: app.db, tmdb: tmdb).title(kind: .movie, tmdbID: 438631)
            try await Watch(userID: user.requireID(), titleID: movie.requireID(), episodeID: nil, watchedOn: "2024-03-03",
                            service: .netflix, origin: .import).save(on: app.db)
            let drafts = [
                Self.draft(.movie, "Dune", watches: [Self.watch("2024-03-02"), Self.watch()]),
                Self.draft(.tv, "Severance", watches: [Self.watch("2024-05-10", season: 1, episode: 1), Self.watch(season: 1, episode: 2)]),
            ]
            for _ in 1...2 {
                let list = try await entries(app, user, drafts)
                try await importer(app, tmdb).record(list[0], tmdbID: 438631)
                try await importer(app, tmdb).record(list[1], tmdbID: 95396)
            }
            #expect(try await watches(app, movie).count == 1)
            #expect(try await watches(app, try await title(app, 95396)).count == 2)
            #expect(try await ImportEntryService(db: app.db).entries(userID: user.requireID()).map(\.addedWatches) == [0, 0])
        }
    }

    @Test func ratingAndCommentAppend() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let movie = try await CatalogService(db: app.db, tmdb: tmdb).title(kind: .movie, tmdbID: 438631)
            try await WatchService(db: app.db).setComment(userID: user.requireID(), titleID: movie.requireID(), comment: "Alt")
            for _ in 1...2 {
                let entry = try await entries(app, user, [Self.draft(.movie, "Dune", watches: [Self.watch()], rating: 7, comment: "Neu")])[0]
                try await importer(app, tmdb).record(entry, tmdbID: 438631)
            }
            let userTitle = try await WatchService(db: app.db).userTitle(userID: user.requireID(), titleID: movie.requireID())
            #expect(userTitle.comment == "Alt\n\nNeu")
            #expect(userTitle.rating == 7)
        }
    }

    @Test func seriesRowOnlyAddsToLibrary() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let series = try await CatalogService(db: app.db, tmdb: tmdb).title(kind: .tv, tmdbID: 95396)
            try await WatchService(db: app.db).setHidden(userID: user.requireID(), titleID: series.requireID(), hidden: true)
            let entry = try await entries(app, user, [Self.draft(.tv, "Severance", rating: 9)])[0]
            try await importer(app, tmdb).record(entry, tmdbID: 95396)
            let userTitle = try await WatchService(db: app.db).userTitle(userID: user.requireID(), titleID: series.requireID())
            #expect(userTitle.rating == 9)
            #expect(userTitle.hidden)
            #expect(userTitle.isFollowed == false)
            #expect(try await watches(app, series).isEmpty)
        }
    }

    @Test func importUnhidesTitlesWithNewWatches() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            // Only series can be hidden in the app.
            let series = try await CatalogService(db: app.db, tmdb: tmdb).title(kind: .tv, tmdbID: 95396)
            try await WatchService(db: app.db).setHidden(userID: user.requireID(), titleID: series.requireID(), hidden: true)
            let entry = try await entries(app, user, [Self.draft(.tv, "Severance", watches: [Self.watch(season: 1, episode: 1)])])[0]
            try await importer(app, tmdb).record(entry, tmdbID: 95396)
            #expect(try await WatchService(db: app.db).userTitle(userID: user.requireID(), titleID: series.requireID()).hidden == false)
        }
    }

    @Test func futureDayBecomesUndated() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let entry = try await entries(app, user, [Self.draft(.movie, "Dune", watches: [Self.watch("2027-01-01")])])[0]
            try await importer(app, tmdb).record(entry, tmdbID: 438631)
            #expect(try await watches(app, try await title(app, 438631)).map(\.watchedOn) == [nil])
        }
    }

    // MARK: Worker and service

    @Test func workerResolvesAndKeepsErrors() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let pat = try await createUser(app, "pat")
            let ann = try await createUser(app, "ann", tmdbToken: nil)
            _ = try await entries(app, pat, [Self.draft(.movie, "Dune", year: 2021, tmdb: 438631)])
            _ = try await entries(app, ann, [Self.draft(.movie, "Dune", year: 2021, tmdb: 438631)])
            _ = try await app.importWorker.processAll()
            let service = ImportEntryService(db: app.db)
            #expect(try await service.entries(userID: pat.requireID()).map(\.entryStatus) == [.imported])
            let waiting = try await service.entries(userID: ann.requireID())
            #expect(waiting.map(\.entryStatus) == [.pending])
            #expect(waiting.first?.error == TMDBError.missingToken.description)
            try await service.retry(userID: ann.requireID())
            #expect(try await service.entries(userID: ann.requireID()).first?.error == nil)
        }
    }

    @Test func uploadReplacesAndReports() async throws {
        try await withTestApp(tmdb: Self.fake()) { app in
            let user = try await createUser(app, "pat")
            let service = ImportEntryService(db: app.db)
            let summary = try await service.upload(userID: user.requireID(),
                                                   text: "type,title,season,episode\nmovie,Dune,,\nepisode,Severance,1,1\npodcast,X,,\n")
            #expect(summary == ImportUploadSummary(titles: 2, skippedRows: 1))
            #expect(try await service.entries(userID: user.requireID()).map(\.titleKind) == [.movie, .tv])
            _ = try await service.upload(userID: user.requireID(), text: "type,title\nmovie,Heat\n")
            #expect(try await service.entries(userID: user.requireID()).map(\.title) == ["Heat"])
            await #expect(throws: APIError.validation(ImportEntryService.noHeaderMessage)) {
                _ = try await service.upload(userID: user.requireID(), text: "Filmname\nDune\n")
            }
            await #expect(throws: APIError.validation(ImportEntryService.emptyMessage)) {
                _ = try await service.upload(userID: user.requireID(), text: "type,title\n")
            }
            #expect(ImportEntryService.noHeaderMessage
                    == "Kein Standard-Import erkannt – erwartet wird eine CSV mit einer Kopfzeile, die „type“ und „title“ enthält.")
            #expect(ImportEntryService.emptyMessage == "Die Datei enthält keine Titel.")
        }
    }

    @Test func tooManyTitlesAreRejected() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let service = ImportEntryService(db: app.db, maxTitles: 2)
            _ = try await service.upload(userID: user.requireID(), text: "type,title\nmovie,A\nmovie,A\nmovie,B\n")
            await #expect(throws: APIError.validation(ImportEntryService.tooManyTitlesMessage(limit: 2))) {
                _ = try await service.upload(userID: user.requireID(), text: "type,title\nmovie,A\nmovie,B\nmovie,C\n")
            }
            #expect(try await service.entries(userID: user.requireID()).map(\.title) == ["A", "B"])
            #expect(ImportEntryService.tooManyTitlesMessage(limit: 20_000)
                    == "Die Datei enthält mehr als 20.000 Titel – bitte in mehrere Dateien aufteilen.")
        }
    }

    @Test func resolveOfDeletedEntryIsHarmless() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let stale = try await entries(app, user, [Self.draft(.movie, "Dune", year: 2021, tmdb: 438631, watches: [Self.watch()])])[0]
            try await ImportEntryService(db: app.db).replace(userID: user.requireID(), drafts: [])
            try await importer(app, tmdb).resolve(stale)
            #expect(try await ImportEntry.query(on: app.db).count() == 0)
            #expect(try await Watch.query(on: app.db).count() == 0)
        }
    }

    @Test func entriesArePrivate() async throws {
        try await withTestApp(tmdb: Self.fake()) { app in
            let owner = try await createUser(app, "pat")
            let other = try await createUser(app, "other")
            let id = try await entries(app, owner, [Self.draft(.movie, "Dune")])[0].requireID()
            await #expect(throws: TrackingError.notFound) {
                _ = try await ImportEntryService(db: app.db).ownEntry(userID: other.requireID(), id: id)
            }
        }
    }
}
