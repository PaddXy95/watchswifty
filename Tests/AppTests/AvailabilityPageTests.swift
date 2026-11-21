@testable import App
import Elementary
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("AvailabilityPage")
struct AvailabilityPageTests {
    struct ToggleForm: Content { var watchLater: String }

    func fake() -> FakeTMDBClient {
        let tmdb = FakeTMDBClient()
        tmdb.setWatchProviders(kind: .tv, id: 9, TMDBWatchProviders(offers: ["DE": [
            offer(8, "Netflix", .flatrate, priority: 1), offer(337, "Disney Plus", .flatrate, priority: 2),
            offer(2, "Apple TV", .buy, priority: 3), offer(10, "Amazon Video", .rent, priority: 4),
        ]]))
        return tmdb
    }

    func pat(_ app: Application, token: Bool = true) async throws -> (User, HTTPHeaders) {
        let user = try await createUser(app, "pat", tmdbToken: token ? try app.tokenCipher.seal("tok") : nil)
        try await UserStreamingService(userID: user.requireID(), providerID: 8).save(on: app.db)
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

    @Test func seriesPageShowsToggleAndLazyBlock() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            let (_, headers) = try await pat(app)
            _ = try await seedSeries(app, tmdbID: 9, seasons: [1: 2])
            let body = try await get(app, "/tv/9", headers)
            #expect(body.contains("Später ansehen"))
            #expect(body.contains(#"hx-get="/tv/9/availability""#))
            #expect(body.contains("Verfügbarkeit wird geladen"))
            #expect(!tmdb.calls.contains { $0.hasPrefix("watch_providers") })
        }
    }

    @Test func availabilityFragmentFetchesWhenStale() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            let (_, headers) = try await pat(app)
            _ = try await seedSeries(app, tmdbID: 9, seasons: [1: 2])
            let body = try await get(app, "/tv/9/availability", headers.adding(.htmx))
            #expect(tmdb.calls.filter { $0 == "watch_providers:tv:9" }.count == 1)
            #expect(body.contains("Netflix"))
            _ = try await get(app, "/tv/9/availability", headers.adding(.htmx))
            #expect(tmdb.calls.filter { $0 == "watch_providers:tv:9" }.count == 1)   // fresh: no second fetch
            #expect(!(try await get(app, "/tv/9", headers)).contains(#"hx-get="/tv/9/availability""#))
        }
    }

    @Test func blockGroupsOwnServices() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            let (_, headers) = try await pat(app)
            _ = try await seedSeries(app, tmdbID: 9, seasons: [1: 2])
            let body = try await get(app, "/tv/9/availability", headers.adding(.htmx))
            let mine = try #require(body.range(of: "In deinen Abos")), netflix = try #require(body.range(of: "Netflix")),
                others = try #require(body.range(of: "Weitere Abos")), disney = try #require(body.range(of: "Disney Plus"))
            #expect(mine.lowerBound < netflix.lowerBound && netflix.lowerBound < others.lowerBound && others.lowerBound < disney.lowerBound)
            #expect(body.contains("Leihen oder kaufen (2 Anbieter)"))
            #expect(body.contains(#"href="https://www.justwatch.com/de""#))
            #expect(body.contains("Verfügbarkeit"))
            #expect(body.contains("Deutschland"))
            #expect(body.contains("https://www.netflix.com/search?q=Serie"))   // chip links to the existing service search
        }
    }

    @Test func noServicesShowsSingleGroup() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            _ = try await createUser(app, "pat", tmdbToken: try app.tokenCipher.seal("tok"))
            let headers = try await login(app, "pat")
            _ = try await seedSeries(app, tmdbID: 9, seasons: [1: 2])
            let body = try await get(app, "/tv/9/availability", headers.adding(.htmx))
            #expect(body.contains("Im Abo"))
            #expect(!body.contains("In deinen Abos"))
            #expect(body.contains("Deine Dienste unter Konto festlegen"))
        }
    }

    @Test func noSubscriptionOffers() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let (pat, headers) = try await pat(app)
            let series = try await seedSeries(app, tmdbID: 9, seasons: [1: 2])
            try await WatchLaterEntry(userID: pat.requireID(), titleID: series.requireID(), addedAt: .now, addedOn: "2026-11-07")
                .save(on: app.db)
            let body = try await get(app, "/tv/9/availability", headers.adding(.htmx))
            #expect(body.contains("Derzeit bei keinem Abo-Dienst verfügbar."))
            #expect(body.contains("bekommst du eine Nachricht"))
        }
    }

    @Test func noTokenShowsHintAndStoredData() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            let (pat, headers) = try await pat(app, token: false)
            let series = try await seedSeries(app, tmdbID: 9, seasons: [1: 2])
            try await WatchLaterEntry(userID: pat.requireID(), titleID: series.requireID(), addedAt: .now, addedOn: "2026-11-07")
                .save(on: app.db)
            try await AvailabilityService(db: app.db).refresh(series, tmdb: tmdb, now: Date().addingTimeInterval(-10 * 86_400))
            let before = tmdb.calls.count
            let body = try await get(app, "/tv/9", headers)
            #expect(body.contains("Netflix"))
            #expect(body.contains("Kein TMDB-Token hinterlegt"))
            #expect(!body.contains(#"hx-get="/tv/9/availability""#))
            #expect(tmdb.calls.count == before)
        }
    }

    @Test func toggleAddsAndRemoves() async throws {
        let tmdb = fake()
        try await withTestApp(tmdb: tmdb) { app in
            let (pat, headers) = try await pat(app)
            let sepp = try await createUser(app, "sepp")
            let series = try await seedSeries(app, tmdbID: 9, seasons: [1: 2])
            try await WatchLaterEntry(userID: sepp.requireID(), titleID: series.requireID(), addedAt: .now, addedOn: "2026-11-07")
                .save(on: app.db)
            try await app.testing().test(.POST, "/tv/9/watch-later", headers: headers.adding(.htmx), beforeRequest: { req in
                try req.content.encode(ToggleForm(watchLater: "true"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.body.string.contains("✓ Später ansehen"))
            })
            #expect(try await WatchLaterService(db: app.db).contains(userID: pat.requireID(), titleID: series.requireID()))
            try await app.testing().test(.POST, "/tv/9/watch-later", headers: headers.adding(.htmx), beforeRequest: { req in
                try req.content.encode(ToggleForm(watchLater: "false"), as: .urlEncodedForm)
            })
            #expect(try await !WatchLaterService(db: app.db).contains(userID: pat.requireID(), titleID: series.requireID()))
            #expect(try await WatchLaterService(db: app.db).contains(userID: sepp.requireID(), titleID: series.requireID()))
        }
    }

    @Test func moviePageHasToggleAndBlock() async throws {
        let tmdb = FakeTMDBClient()
        try await withTestApp(tmdb: tmdb) { app in
            let (_, headers) = try await pat(app)
            _ = try await seedMovie(app, tmdbID: 603)
            let body = try await get(app, "/movie/603", headers)
            #expect(body.contains(#"hx-post="/movie/603/watch-later""#))
            #expect(body.contains(#"hx-get="/movie/603/availability""#))
        }
    }

    @Test func freeAtOwnServiceHasNoFalsePromise() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.setWatchProviders(kind: .tv, id: 9, TMDBWatchProviders(offers: ["DE": [offer(8, "Netflix", .ads)]]))
        try await withTestApp(tmdb: tmdb) { app in
            let (pat, headers) = try await pat(app)
            let series = try await seedSeries(app, tmdbID: 9, seasons: [1: 2])
            try await WatchLaterEntry(userID: pat.requireID(), titleID: series.requireID(), addedAt: .now, addedOn: "2026-11-07")
                .save(on: app.db)
            let body = try await get(app, "/tv/9/availability", headers.adding(.htmx))
            #expect(body.contains("Gratis / mit Werbung"))
            #expect(!body.contains("bekommst du eine Nachricht"))
        }
    }

    @Test func justWatchLinkUsesItsCountryPath() {
        let html = JustWatchLink(region: "GB").render()
        #expect(html.contains("https://www.justwatch.com/uk"))
        #expect(JustWatchLink(region: "DE").render().contains("https://www.justwatch.com/de"))
    }
}
