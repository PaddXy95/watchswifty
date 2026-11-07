@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct WatchFormInput: Content { var day: String?; var service: String?; var rewatch: String? }
struct RatingInput: Content { var rating: String }
struct HiddenInput: Content { var hidden: Bool }

@Suite("TitlePages")
struct TitlePagesTests {
    static func fake() -> FakeTMDBClient {
        let tmdb = FakeTMDBClient()
        tmdb.addSeries(TMDBSeries(id: 1399, name: "Testserie", originalName: nil, year: 2011, posterPath: "/t.jpg",
                                  status: "Returning Series", seasonNumbers: [1, 2]),
                       episodes: [1: ["Eins", "Zwei"], 2: ["Drei", "Vier"]])
        tmdb.addMovie(TMDBMovie(id: 603, name: "Matrix", originalName: "The Matrix", year: 1999, posterPath: "/m.jpg"))
        tmdb.setSearch("multi", "Test", [
            TMDBSearchResult(id: 1399, kind: .tv, name: "Testserie", originalName: nil, year: 2011, posterPath: "/t.jpg"),
            TMDBSearchResult(id: 603, kind: .movie, name: "Matrix", originalName: nil, year: 1999, posterPath: nil),
        ])
        return tmdb
    }

    /// Runs `body` with a logged-in user "pat" (htmx + session headers).
    func withUser(_ body: (Application, User, HTTPHeaders) async throws -> Void) async throws {
        try await withTestApp(tmdb: Self.fake()) { app in
            let user = try await createUser(app, "pat")
            let headers = try await login(app, "pat").adding(.htmx)
            try await body(app, user, headers)
        }
    }

    func userWatches(_ app: Application, _ user: User) async throws -> [Watch] {
        try await Watch.query(on: app.db).filter(\.$user.$id == user.requireID()).all()
    }

    var todayDisplay: String { "07.11.2026" }   // AppConfig.testing pins today

    @Test func searchListsBothKinds() async throws {
        try await withUser { app, _, headers in
            try await app.testing().test(.GET, "/search/results?q=Test", headers: headers) { res async in
                #expect(res.status == .ok)
                let body = res.body.string
                #expect(body.contains("Serie"))
                #expect(body.contains("Film"))
                #expect(body.contains("/tv/1399"))
                #expect(body.contains("/movie/603"))
            }
        }
    }

    @Test func shortQueryGivesNoResults() async throws {
        try await withUser { app, _, headers in
            try await app.testing().test(.GET, "/search/results?q=T", headers: headers) { res async in
                #expect(!res.body.string.contains("/tv/"))
            }
        }
    }

    @Test func searchShowsOwnStatus() async throws {
        try await withUser { app, user, headers in
            let catalog = CatalogService(db: app.db, tmdb: app.tmdbProvider.make("test-token"))
            let show = try await catalog.title(kind: .tv, tmdbID: 1399)
            let ws = WatchService(db: app.db)
            _ = try await ws.markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(), day: nil, service: nil)
            try await ws.setRating(userID: user.requireID(), titleID: show.requireID(), rating: 8)
            try await app.testing().test(.GET, "/search/results?q=Test", headers: headers) { res async in
                #expect(res.body.string.contains("1/4 gesehen"))
                #expect(res.body.string.contains("★ 8"))
            }
        }
    }

    @Test func seriesPageShowsSeasons() async throws {
        try await withUser { app, _, headers in
            try await app.testing().test(.GET, "/tv/1399", headers: headers) { res async in
                #expect(res.status == .ok)
                let body = res.body.string
                #expect(body.contains("Testserie"))
                #expect(body.contains("Staffel 1 · 0/2 gesehen"))
                #expect(body.contains("Ganze Staffel gesehen"))
                #expect(body.contains("bis hier gesehen"))
            }
        }
    }

    @Test func markEpisodeReturnsCheckedRow() async throws {
        try await withUser { app, user, headers in
            try await app.testing().test(.POST, "/tv/1399/episodes/1/1/watch", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains(todayDisplay))
                #expect(res.body.string.contains("checked"))
                #expect(res.body.string.contains("Staffel 1 · 1/2 gesehen"))
            }
            #expect(try await userWatches(app, user).count == 1)
        }
    }

    @Test func markWithPastDateAndService() async throws {
        try await withUser { app, user, headers in
            try await app.testing().test(.POST, "/tv/1399/episodes/1/2/watch", headers: headers, beforeRequest: { req in
                try req.content.encode(WatchFormInput(day: "2026-11-01", service: "disney_plus"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("01.11.2026"))
                #expect(res.body.string.contains("Disney+"))
            })
        }
    }

    @Test func checkboxUsesLastService() async throws {
        try await withUser { app, user, headers in
            try await app.testing().test(.POST, "/tv/1399/episodes/1/1/watch", headers: headers, beforeRequest: { req in
                try req.content.encode(WatchFormInput(day: "2026-11-01", service: "netflix"), as: .urlEncodedForm)
            }, afterResponse: { _ async in })
            try await app.testing().test(.POST, "/tv/1399/episodes/1/2/watch", headers: headers) { res async in
                #expect(res.status == .ok)
            }
            let services = try await userWatches(app, user).map(\.streamingService)
            #expect(services == [.netflix, .netflix])
        }
    }

    @Test func futureDate422() async throws {
        try await withUser { app, _, headers in
            try await app.testing().test(.POST, "/tv/1399/episodes/1/1/watch", headers: headers, beforeRequest: { req in
                try req.content.encode(WatchFormInput(day: "2999-01-01", service: ""), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("Datum liegt in der Zukunft."))
            })
        }
    }

    @Test func invalidServiceIs400() async throws {
        try await withUser { app, _, headers in
            try await app.testing().test(.POST, "/tv/1399/episodes/1/1/watch", headers: headers, beforeRequest: { req in
                try req.content.encode(WatchFormInput(day: nil, service: "hbo"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test func unmarkEpisode() async throws {
        try await withUser { app, user, headers in
            try await app.testing().test(.POST, "/tv/1399/episodes/1/1/watch", headers: headers) { _ async in }
            try await app.testing().test(.DELETE, "/tv/1399/episodes/1/1/watch", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Staffel 1 · 0/2 gesehen"))
            }
            #expect(try await userWatches(app, user).isEmpty)
        }
    }

    @Test func markSeason() async throws {
        try await withUser { app, _, headers in
            try await app.testing().test(.POST, "/tv/1399/seasons/1/watch", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Staffel 1 · 2/2 gesehen"))
            }
        }
    }

    @Test func markUpToCount() async throws {
        try await withUser { app, user, headers in
            try await app.testing().test(.POST, "/tv/1399/episodes/2/2/watch-up-to", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Staffel 2 · 2/2 gesehen"))
            }
            let all = try await userWatches(app, user)
            #expect(all.count == 4)
            #expect(all.allSatisfy { $0.watchedOn == nil })
        }
    }

    @Test func rating() async throws {
        try await withUser { app, user, headers in
            try await app.testing().test(.POST, "/tv/1399/rating", headers: headers, beforeRequest: { req in
                try req.content.encode(RatingInput(rating: "11"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("Bewertung muss zwischen 1 und 10 liegen."))
            })
            try await app.testing().test(.POST, "/tv/1399/rating", headers: headers, beforeRequest: { req in
                try req.content.encode(RatingInput(rating: "8"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("★ 8"))
            })
            let show = try #require(try await Title.query(on: app.db).filter(\.$tmdbID == 1399).first())
            let entry = try await WatchService(db: app.db).userTitle(userID: user.requireID(), titleID: show.requireID())
            #expect(entry.rating == 8)
        }
    }

    @Test func hideAndUnhide() async throws {
        try await withUser { app, user, headers in
            try await app.testing().test(.POST, "/tv/1399/hidden", headers: headers, beforeRequest: { req in
                try req.content.encode(HiddenInput(hidden: true), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.body.string.contains("Einblenden"))
            })
            let show = try #require(try await Title.query(on: app.db).filter(\.$tmdbID == 1399).first())
            #expect(try await WatchService(db: app.db).userTitle(userID: user.requireID(), titleID: show.requireID()).hidden)
            try await app.testing().test(.POST, "/tv/1399/hidden", headers: headers, beforeRequest: { req in
                try req.content.encode(HiddenInput(hidden: false), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.body.string.contains("Ausblenden"))
            })
        }
    }

    @Test func movieWatchedInCinema() async throws {
        try await withUser { app, _, headers in
            try await app.testing().test(.POST, "/movie/603/watch", headers: headers, beforeRequest: { req in
                try req.content.encode(WatchFormInput(day: "2026-11-01", service: "cinema"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Kino"))
                #expect(res.body.string.contains("01.11.2026"))
            })
            try await app.testing().test(.GET, "/movie/603", headers: headers) { res async in
                #expect(res.body.string.contains("Matrix"))
                #expect(res.body.string.contains("Erneut gesehen"))
            }
            try await app.testing().test(.DELETE, "/movie/603/watch", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(!res.body.string.contains("01.11.2026"))
            }
        }
    }

    @Test func unknownTMDBIDIs404() async throws {
        try await withUser { app, _, headers in
            try await app.testing().test(.GET, "/tv/42", headers: headers) { res async in
                #expect(res.status == .notFound)
            }
        }
    }
}

@Suite("SearchWithoutToken")
struct SearchWithoutTokenTests {
    @Test func searchShowsHint() async throws {
        let tmdb = TitlePagesTests.fake()
        try await withTestApp(tmdb: tmdb) { app in
            try await createUser(app, "pat", tmdbToken: nil)
            let headers = try await login(app, "pat").adding(.htmx)
            try await app.testing().test(.GET, "/search", headers: headers) { res async in
                #expect(res.body.string.contains("TMDB-Token"))
                #expect(res.body.string.contains(#"href="/account""#))
            }
            try await app.testing().test(.GET, "/search/results?q=Test", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("TMDB-Token"))
                #expect(!res.body.string.contains("/tv/1399"))
            }
            #expect(!tmdb.calls.contains { $0.hasPrefix("multi:") })
        }
    }

    @Test func cachedSeriesPageWorksWithoutToken() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat", tmdbToken: nil)
            _ = try await seedSeries(app, tmdbID: 5, name: "Schon bekannt", seasons: [1: 2])
            let headers = try await login(app, "pat").adding(.htmx)
            try await app.testing().test(.GET, "/tv/5", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Schon bekannt"))
            }
            try await app.testing().test(.GET, "/tv/6", headers: headers) { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("Kein TMDB-Token hinterlegt"))
            }
        }
    }
}

@Suite("PurchasedService")
struct PurchasedServiceTests {
    @Test func markWithPurchasedService() async throws {
        try await withTestApp(tmdb: TitlePagesTests.fake()) { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat").adding(.htmx)
            try await app.testing().test(.POST, "/tv/1399/episodes/1/1/watch", headers: headers, beforeRequest: { req in
                try req.content.encode(WatchFormInput(day: "2026-11-01", service: "purchased"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("01.11.2026 · Gekauft"))
            })
        }
    }
}

@Suite("WatchAll")
struct WatchAllTests {
    @Test func watchAllRouteAndButton() async throws {
        try await withTestApp(tmdb: TitlePagesTests.fake()) { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat").adding(.htmx)
            try await app.testing().test(.GET, "/tv/1399", headers: headers) { res async in
                #expect(res.body.string.contains("Gesamte Serie gesehen"))
                #expect(res.body.string.contains("/tv/1399/watch-all"))
            }
            try await app.testing().test(.POST, "/tv/1399/watch-all", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Staffel 1 · 2/2 gesehen"))
                #expect(res.body.string.contains("Staffel 2 · 2/2 gesehen"))
            }
        }
    }
}
