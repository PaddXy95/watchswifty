@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct EditWatchInput: Content { var day: String; var service: String }
struct HiddenCardInput: Content { var hidden: Bool; var context: String }

@Suite("HomeHistoryLibrary")
struct HomeHistoryLibraryTests {
    func withUser(_ body: (Application, User, HTTPHeaders) async throws -> Void) async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let headers = try await login(app, "pat").adding(.htmx)
            try await body(app, user, headers)
        }
    }

    func mark(_ app: Application, _ user: User, _ title: Title, _ s: Int, _ n: Int, day: String? = "2026-11-01",
              service: StreamingService? = .netflix) async throws {
        _ = try await WatchService(db: app.db).markEpisode(userID: user.requireID(), episodeID: episode(app, title, s, n).requireID(),
                                                           day: day, service: service, rewatch: true)
    }

    func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    @Test func continueCardContent() async throws {
        try await withUser { app, user, headers in
            let show = try await seedSeries(app, tmdbID: 1420, name: "The Mentalist", seasons: [4: 24], unaired: ["4x24"])
            try await mark(app, user, show, 4, 14)
            try await app.testing().test(.GET, "/", headers: headers) { res async in
                let body = res.body.string
                #expect(res.status == .ok)
                #expect(body.contains("Weiter mit S04E15"))
                #expect(body.contains("„Folge 4x15“"))
                #expect(body.contains("noch 9 Folgen"))
                #expect(body.contains("zuletzt auf Netflix"))
                #expect(body.contains("zuletzt 01.11.2026"))
                #expect(body.contains("✓ gesehen"))
                #expect(body.contains("https://www.netflix.com/search?q=The%20Mentalist"))
            }
        }
    }

    @Test func netflixLinkOnlyWithNetflixData() async throws {
        try await withUser { app, user, headers in
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 3])
            try await mark(app, user, show, 1, 1, service: .disneyPlus)
            try await app.testing().test(.GET, "/", headers: headers) { res async in
                #expect(res.body.string.contains("Weiter mit S01E02"))
                #expect(!res.body.string.contains("Auf Netflix suchen"))
            }
        }
    }

    @Test func emptyState() async throws {
        try await withUser { app, _, headers in
            try await app.testing().test(.GET, "/", headers: headers) { res async in
                #expect(res.body.string.contains("Noch nichts zum Weiterschauen."))
            }
        }
    }

    @Test func quickMarkAdvancesCard() async throws {
        try await withUser { app, user, headers in
            let show = try await seedSeries(app, tmdbID: 1420, seasons: [4: 24])
            try await mark(app, user, show, 4, 14)
            try await app.testing().test(.POST, "/tv/1420/next", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Weiter mit S04E16"))
            }
            let watches = try await Watch.query(on: app.db).filter(\.$user.$id == user.requireID()).all()
            #expect(watches.count == 2)
            #expect(watches.allSatisfy { $0.streamingService == .netflix })
        }
    }

    @Test func quickMarkLastEpisodeRemovesCard() async throws {
        try await withUser { app, user, headers in
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 2])
            try await mark(app, user, show, 1, 1)
            try await app.testing().test(.POST, "/tv/1/next", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.isEmpty)
            }
        }
    }

    @Test func hideFromCardRemovesIt() async throws {
        try await withUser { app, user, headers in
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 3])
            try await mark(app, user, show, 1, 1)
            try await app.testing().test(.POST, "/tv/1/hidden", headers: headers, beforeRequest: { req in
                try req.content.encode(HiddenCardInput(hidden: true, context: "card"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.isEmpty)
            })
            try await app.testing().test(.GET, "/", headers: headers) { res async in
                #expect(res.body.string.contains("Noch nichts zum Weiterschauen."))
            }
        }
    }

    @Test func historyExcludesUndated() async throws {
        try await withUser { app, user, headers in
            let show = try await seedSeries(app, tmdbID: 1, name: "Verlaufserie", seasons: [1: 3])
            try await mark(app, user, show, 1, 1, day: "2026-10-01")
            try await mark(app, user, show, 1, 2, day: nil)
            _ = try await WatchService(db: app.db).markSeason(userID: user.requireID(), titleID: show.requireID(), season: 1, service: nil)
            try await app.testing().test(.GET, "/history", headers: headers) { res async in
                let body = res.body.string
                #expect(body.contains("01.10.2026"))
                #expect(body.contains("S01E01 · Folge 1x1"))
                #expect(count("class=\"history-row\"", in: body) == 2)
                #expect(body.contains("Netflix"))
                #expect(body.contains("manuell"))
            }
        }
    }

    @Test func historyPaginates() async throws {
        try await withUser { app, user, headers in
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 60])
            for n in 1...60 { try await mark(app, user, show, 1, n, day: "2026-09-01") }
            try await app.testing().test(.GET, "/history", headers: headers) { res async in
                #expect(count("class=\"history-row\"", in: res.body.string) == 50)
                #expect(res.body.string.contains("Mehr laden"))
            }
            try await app.testing().test(.GET, "/history?page=2", headers: headers) { res async in
                #expect(count("class=\"history-row\"", in: res.body.string) == 10)
                #expect(!res.body.string.contains("Mehr laden"))
            }
        }
    }

    @Test func editWatchFromHistory() async throws {
        try await withUser { app, user, headers in
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1])
            try await mark(app, user, show, 1, 1, day: "2026-10-01")
            let watch = try #require(try await Watch.query(on: app.db).first())
            try await app.testing().test(.POST, "/watches/\(watch.requireID())", headers: headers, beforeRequest: { req in
                try req.content.encode(EditWatchInput(day: "2026-10-03", service: "prime_video"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("03.10.2026"))
                #expect(res.body.string.contains("Prime Video"))
            })
        }
    }

    @Test func deleteWatchAndForeignIs404() async throws {
        try await withUser { app, user, headers in
            let other = try await createUser(app, "other")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 2])
            try await mark(app, user, show, 1, 1)
            try await mark(app, other, show, 1, 2)
            let mine = try #require(try await Watch.query(on: app.db).filter(\.$user.$id == user.requireID()).first())
            let theirs = try #require(try await Watch.query(on: app.db).filter(\.$user.$id == other.requireID()).first())
            try await app.testing().test(.DELETE, "/watches/\(theirs.requireID())", headers: headers) { res async in
                #expect(res.status == .notFound)
            }
            try await app.testing().test(.DELETE, "/watches/\(mine.requireID())", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.isEmpty)
            }
            #expect(try await Watch.query(on: app.db).count() == 1)
        }
    }

    @Test func libraryFilters() async throws {
        try await withUser { app, user, headers in
            let visible = try await seedSeries(app, tmdbID: 1, name: "Sichtbare Serie", seasons: [1: 2])
            let hidden = try await seedSeries(app, tmdbID: 2, name: "Versteckte Serie", seasons: [1: 2])
            let movie = try await seedMovie(app, tmdbID: 3, name: "Ein Film")
            let ws = WatchService(db: app.db)
            try await mark(app, user, visible, 1, 1)
            try await mark(app, user, hidden, 1, 1)
            try await ws.setHidden(userID: user.requireID(), titleID: hidden.requireID(), hidden: true)
            _ = try await ws.markMovie(userID: user.requireID(), titleID: movie.requireID(), day: nil, service: nil)
            try await app.testing().test(.GET, "/library", headers: headers) { res async in
                #expect(res.body.string.contains("Sichtbare Serie"))
                #expect(res.body.string.contains("Ein Film"))
                #expect(!res.body.string.contains("Versteckte Serie"))
            }
            try await app.testing().test(.GET, "/library?filter=hidden", headers: headers) { res async in
                #expect(res.body.string.contains("Versteckte Serie"))
                #expect(!res.body.string.contains("Sichtbare Serie"))
                #expect(res.body.string.contains("Einblenden"))
            }
            try await app.testing().test(.GET, "/library?filter=movie", headers: headers) { res async in
                #expect(res.body.string.contains("Ein Film"))
                #expect(!res.body.string.contains("Sichtbare Serie"))
            }
        }
    }

    @Test func librarySortByRating() async throws {
        try await withUser { app, user, headers in
            let a = try await seedSeries(app, tmdbID: 1, name: "Alpha", seasons: [1: 1])
            let z = try await seedMovie(app, tmdbID: 2, name: "Zulu")
            let ws = WatchService(db: app.db)
            try await ws.setRating(userID: user.requireID(), titleID: a.requireID(), rating: 5)
            try await ws.setRating(userID: user.requireID(), titleID: z.requireID(), rating: 9)
            try await app.testing().test(.GET, "/library?sort=rating", headers: headers) { res async in
                let body = res.body.string
                let zulu = try? #require(body.range(of: "Zulu"))
                let alpha = try? #require(body.range(of: "Alpha"))
                if let zulu, let alpha { #expect(zulu.lowerBound < alpha.lowerBound) }
            }
            try await app.testing().test(.GET, "/library?sort=name", headers: headers) { res async in
                let body = res.body.string
                if let zulu = body.range(of: "Zulu"), let alpha = body.range(of: "Alpha") { #expect(alpha.lowerBound < zulu.lowerBound) }
            }
        }
    }
}

@Suite("DoubleClick")
struct DoubleClickTests {
    @Test func staleQuickMarkDoesNotAdvanceTwice() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let headers = try await login(app, "pat").adding(.htmx)
            let show = try await seedSeries(app, tmdbID: 1420, seasons: [4: 24])
            _ = try await WatchService(db: app.db).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 4, 14).requireID(),
                                                               day: "2026-11-01", service: .netflix)
            let expected = try await episode(app, show, 4, 15).requireID()
            struct NextInput: Content { var episodeID: UUID }
            for _ in 0..<2 {   // double click: both requests name S04E15
                try await app.testing().test(.POST, "/tv/1420/next", headers: headers, beforeRequest: { req in
                    try req.content.encode(NextInput(episodeID: expected), as: .urlEncodedForm)
                }, afterResponse: { res async in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("Weiter mit S04E16"))
                })
            }
            let count = try await Watch.query(on: app.db).filter(\.$user.$id == user.requireID()).count()
            #expect(count == 2)
        }
    }

    @Test func cardButtonCarriesEpisodeAndSettleGuard() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1420, seasons: [4: 3])
            _ = try await WatchService(db: app.db).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 4, 1).requireID(),
                                                               day: nil, service: nil)
            let next = try await episode(app, show, 4, 2).requireID()
            try await app.testing().test(.GET, "/", headers: headers) { res async in
                #expect(res.body.string.contains(next.uuidString))
                #expect(res.body.string.contains("settle:500ms"))
            }
            try await app.testing().test(.GET, "/tv/1420", headers: headers) { res async in
                #expect(res.body.string.contains("settle:500ms"))
            }
        }
    }

    @Test func freshlySwappedControlsIgnoreClicks() throws {
        let css = try String(contentsOfFile: "Public/css/app.css", encoding: .utf8)
        #expect(css.contains(".htmx-added button"))
        #expect(css.contains("pointer-events: none"))
    }
}


@Suite("ContinueCutoff")
struct ContinueCutoffTests {
    func setup(_ app: Application, _ user: User) async throws {
        let ws = WatchService(db: app.db, today: { "2026-11-07" })
        let old = try await seedSeries(app, tmdbID: 1, name: "Alte Serie", seasons: [1: 3])
        let edge = try await seedSeries(app, tmdbID: 2, name: "Grenzfall", seasons: [1: 3])
        _ = try await ws.markEpisode(userID: user.requireID(), episodeID: episode(app, old, 1, 1).requireID(), day: "2026-08-06", service: nil)
        _ = try await ws.markEpisode(userID: user.requireID(), episodeID: episode(app, edge, 1, 1).requireID(), day: "2026-08-07", service: nil)
    }

    @Test func oldSeriesHiddenByDefault() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            try await setup(app, user)
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/", headers: headers) { res async in
                let body = res.body.string
                #expect(!body.contains("Alte Serie"))
                #expect(body.contains("Grenzfall"))
                #expect(body.contains("1 ältere Serie anzeigen"))
                #expect(body.contains(#"href="/?all=1""#))
            }
        }
    }

    @Test func allParameterShowsOldSeries() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            try await setup(app, user)
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/?all=1", headers: headers) { res async in
                #expect(res.body.string.contains("Alte Serie"))
                #expect(res.body.string.contains("Grenzfall"))
                #expect(res.body.string.contains("Nur letzte 3 Monate"))
            }
        }
    }

    @Test func bulkMarkedCountsAsRecent() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 3, name: "Frisch markiert", seasons: [1: 3])
            _ = try await WatchService(db: app.db).markUpTo(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(), service: nil)
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/", headers: headers) { res async in
                #expect(res.body.string.contains("Frisch markiert"))
                #expect(!res.body.string.contains("ältere"))
            }
        }
    }
}
