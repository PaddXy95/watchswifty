@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("WatchLaterPage")
struct WatchLaterPageTests {
    struct AddForm: Content { var kind: String; var tmdbID: Int }

    static let dune = TMDBSearchResult(id: 693134, kind: .movie, name: "Dune", originalName: nil, year: 2024, posterPath: nil)
    static let andor = TMDBSearchResult(id: 83867, kind: .tv, name: "Andor", originalName: nil, year: 2022, posterPath: nil)

    func fake() -> FakeTMDBClient {
        let tmdb = FakeTMDBClient()
        tmdb.setSearch("multi", "du", [Self.dune, Self.andor])
        tmdb.addMovie(TMDBMovie(id: 693134, name: "Dune", originalName: nil, year: 2024, posterPath: nil))
        tmdb.setWatchProviders(kind: .movie, id: 693134, TMDBWatchProviders(offers: ["DE": [offer(8, "Netflix", .flatrate)]]))
        return tmdb
    }

    func pat(_ app: Application) async throws -> (User, HTTPHeaders) {
        let user = try await createUser(app, "pat", tmdbToken: try app.tokenCipher.seal("tok"))
        return (user, try await login(app, "pat"))
    }

    func get(_ app: Application, _ path: String, _ headers: HTTPHeaders) async throws -> String {
        var body = ""
        try await app.testing().test(.GET, path, headers: headers) { res async in
            #expect(res.status == .ok)
            body = res.body.string
        }
        return body
    }

    func add(_ app: Application, _ headers: HTTPHeaders, kind: String = "movie", tmdbID: Int = 693134) async throws -> String {
        var body = ""
        try await app.testing().test(.POST, "/watch-later", headers: headers.adding(.htmx), beforeRequest: { req in
            try req.content.encode(AddForm(kind: kind, tmdbID: tmdbID), as: .urlEncodedForm)
        }, afterResponse: { res async in body = res.body.string })
        return body
    }

    @Test func searchShowsAddButtonAndState() async throws {
        try await withTestApp(tmdb: fake()) { app in
            let (_, headers) = try await pat(app)
            var body = try await get(app, "/search/results?q=du", headers.adding(.htmx))
            #expect(body.components(separatedBy: "+ Später").count == 3)
            #expect(try await add(app, headers).contains("✓ Später"))
            body = try await get(app, "/search/results?q=du", headers.adding(.htmx))
            #expect(body.contains("✓ Später"))
            #expect(body.components(separatedBy: "+ Später").count == 2)
            #expect(body.contains(##"hx-indicator="closest .search-result, #page-loader""##))
        }
    }

    @Test func addFromSearchCreatesEntry() async throws {
        try await withTestApp(tmdb: fake()) { app in
            let (pat, headers) = try await pat(app)
            _ = try await add(app, headers)
            #expect(try await WatchLaterEntry.query(on: app.db).filter(\.$user.$id == pat.requireID()).count() == 1)
            let body = try await get(app, "/watch-later", headers)
            #expect(body.contains("Dune"))
            #expect(body.contains("Später ansehen"))
        }
    }

    @Test func addRejectsBadKind() async throws {
        try await withTestApp(tmdb: fake()) { app in
            let (_, headers) = try await pat(app)
            try await app.testing().test(.POST, "/watch-later", headers: headers.adding(.htmx), beforeRequest: { req in
                try req.content.encode(AddForm(kind: "book", tmdbID: 1), as: .urlEncodedForm)
            }, afterResponse: { res async in #expect(res.status == .badRequest) })
        }
    }

    @Test func pageGroupsByOwnServices() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            let (pat, headers) = try await pat(app)
            try await UserStreamingService(userID: pat.requireID(), providerID: 8).save(on: app.db)
            _ = try await add(app, headers)
            let other = try await seedMovie(app, tmdbID: 1, name: "Poor Things")
            tmdb.setWatchProviders(kind: .movie, id: 1, TMDBWatchProviders(offers: ["DE": [offer(337, "Disney Plus", .flatrate),
                                                                                        offer(2, "Apple TV", .buy)]]))
            try await WatchLaterService(db: app.db).add(userID: pat.requireID(), title: other, tmdb: tmdb, today: "2026-11-07",
                                                        logger: app.logger)
            let body = try await get(app, "/watch-later", headers)
            let mine = try #require(body.range(of: "Bei deinen Diensten")), dune = try #require(body.range(of: ">Dune<")),
                rest = try #require(body.range(of: "Noch nicht bei deinen Diensten")), poor = try #require(body.range(of: ">Poor Things<"))
            #expect(mine.lowerBound < dune.lowerBound && dune.lowerBound < rest.lowerBound && rest.lowerBound < poor.lowerBound)
            #expect(body.contains("Im Abo bei Disney Plus"))
            #expect(body.contains("JustWatch"))
            #expect(body.contains("Entfernen"))
        }
    }

    @Test func pageStatusLines() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let (pat, headers) = try await pat(app)
            let service = WatchLaterService(db: app.db)
            let rent = try await seedMovie(app, tmdbID: 1, name: "Leihfilm")
            tmdb.setWatchProviders(kind: .movie, id: 1, TMDBWatchProviders(offers: ["DE": [offer(2, "Apple TV", .rent)]]))
            try await service.add(userID: pat.requireID(), title: rent, tmdb: tmdb, today: "2026-11-07", logger: app.logger)
            let nothing = try await seedMovie(app, tmdbID: 2, name: "Nirgends")
            try await service.add(userID: pat.requireID(), title: nothing, tmdb: tmdb, today: "2026-11-07", logger: app.logger)
            let unknown = try await seedMovie(app, tmdbID: 3, name: "Unbekannt")
            try await WatchLaterEntry(userID: pat.requireID(), titleID: unknown.requireID(), addedAt: .now, addedOn: "2026-11-07")
                .save(on: app.db)
            let body = try await get(app, "/watch-later", headers)
            #expect(body.contains("Nur leihen oder kaufen"))
            #expect(body.contains("Derzeit nirgends verfügbar"))
            #expect(body.contains("Verfügbarkeit noch nicht abgefragt"))
            #expect(body.contains("Deine Dienste unter Konto festlegen"))
        }
    }

    @Test func emptyPage() async throws {
        try await withTestApp(tmdb: fake()) { app in
            let (_, headers) = try await pat(app)
            #expect(try await get(app, "/watch-later", headers).contains("Noch nichts vorgemerkt."))
        }
    }

    @Test func pageMakesNoTMDBCalls() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            let (_, headers) = try await pat(app)
            _ = try await add(app, headers)
            let before = tmdb.calls.count
            _ = try await get(app, "/watch-later", headers)
            _ = try await get(app, "/watch-later?filter=tv", headers)
            #expect(tmdb.calls.count == before)
        }
    }

    @Test func removeFromPage() async throws {
        try await withTestApp(tmdb: fake()) { app in
            let (_, headers) = try await pat(app)
            _ = try await add(app, headers)
            try await app.testing().test(.POST, "/watch-later/movie/693134/remove", headers: headers.adding(.htmx)) { res async in
                #expect(res.status == .ok)
            }
            #expect(try await WatchLaterEntry.query(on: app.db).count() == 0)
        }
    }

    @Test func navHasMenuEntry() async throws {
        try await withTestApp(tmdb: fake()) { app in
            let (_, headers) = try await pat(app)
            let body = try await get(app, "/watch-later", headers)
            #expect(body.contains(#"href="/watch-later""#))
            let library = try #require(body.range(of: ">Bibliothek<")), later = try #require(body.range(of: #"href="/watch-later""#)),
                stats = try #require(body.range(of: ">Statistik<"))
            #expect(library.lowerBound < later.lowerBound && later.lowerBound < stats.lowerBound)
        }
    }

    @Test func searchDoesNotMarkListTitleAsInLibrary() async throws {
        try await withTestApp(tmdb: fake()) { app in
            let (pat, headers) = try await pat(app)
            _ = try await add(app, headers)
            let hits = try await SearchService(db: app.db, tmdb: fake()).search(userID: pat.requireID(), query: "du")
            #expect(hits.first { $0.result.id == 693134 }?.inLibrary == false)
            #expect(hits.first { $0.result.id == 693134 }?.watchLater == true)
            _ = headers
        }
    }
}
