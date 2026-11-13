@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct SeasonWatchForm: Content { var service: String?; var rewatch: String? }

/// „Ganze Staffel / Gesamte Serie erneut gesehen“: once every aired episode is watched, the buttons start a new round.
@Suite("RewatchSeason")
struct RewatchSeasonTests {
    func ws(_ app: Application) -> WatchService {
        WatchService(db: app.db, today: { "2026-11-07" })
    }

    /// Watch count per episode, keyed "SxE".
    func counts(_ app: Application, _ user: User, _ show: Title) async throws -> [String: Int] {
        let episodes = try await Episode.query(on: app.db).filter(\.$title.$id == show.requireID()).all()
        let watches = try await Watch.query(on: app.db).filter(\.$user.$id == user.requireID()).all()
        var result: [String: Int] = [:]
        for episode in episodes {
            result["\(episode.season)x\(episode.number)"] = watches.filter { $0.$episode.id == episode.id }.count
        }
        return result
    }

    @Test func seasonRewatchAddsOneRoundWhenAllWatched() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 3], unaired: ["1x3"])
            let userID = try user.requireID(), titleID = try show.requireID()
            _ = try await ws(app).markSeason(userID: userID, titleID: titleID, season: 1, service: nil)
            let added = try await ws(app).markSeason(userID: userID, titleID: titleID, season: 1, service: .netflix, rewatch: true)
            #expect(added == 2)
            #expect(try await counts(app, user, show) == ["1x1": 2, "1x2": 2, "1x3": 0])
        }
    }

    @Test func seasonRewatchCompletesTheCurrentRound() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 3])
            let userID = try user.requireID(), titleID = try show.requireID()
            _ = try await ws(app).markSeason(userID: userID, titleID: titleID, season: 1, service: nil)
            _ = try await ws(app).markEpisode(userID: userID, episodeID: episode(app, show, 1, 1).requireID(), day: nil, service: nil, rewatch: true)
            let added = try await ws(app).markSeason(userID: userID, titleID: titleID, season: 1, service: nil, rewatch: true)
            #expect(added == 2)
            #expect(try await counts(app, user, show) == ["1x1": 2, "1x2": 2, "1x3": 2])
        }
    }

    @Test func seriesRewatchSkipsSpecials() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [0: 1, 1: 2, 2: 1])
            let userID = try user.requireID(), titleID = try show.requireID()
            _ = try await ws(app).markSeries(userID: userID, titleID: titleID, service: nil)
            let added = try await ws(app).markSeries(userID: userID, titleID: titleID, service: nil, rewatch: true)
            #expect(added == 3)
            #expect(try await counts(app, user, show) == ["0x1": 0, "1x1": 2, "1x2": 2, "2x1": 2])
        }
    }

    @Test func buttonsOfferRewatchOnlyWhenEverythingIsWatched() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 2, 2: 1], runtime: 30)
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/tv/1", headers: headers) { res async in
                let body = res.body.string
                #expect(body.contains(">Ganze Staffel gesehen<") && body.contains(">Gesamte Serie gesehen<"))
                #expect(!body.contains("erneut gesehen<") && !body.contains(#"name="rewatch""#))
            }
            _ = try await ws(app).markSeason(userID: user.requireID(), titleID: show.requireID(), season: 1, service: nil)
            try await app.testing().test(.GET, "/tv/1", headers: headers) { res async in
                let body = res.body.string
                #expect(body.contains(">Ganze Staffel erneut gesehen<"))
                #expect(body.contains(">Ganze Staffel gesehen<"))   // season 2 is not watched yet
                #expect(body.contains(">Gesamte Serie gesehen<"))
                #expect(body.contains("Alle Folgen der Staffel noch einmal als gesehen markieren?"))
            }
            _ = try await ws(app).markSeries(userID: user.requireID(), titleID: show.requireID(), service: nil)
            try await app.testing().test(.GET, "/tv/1", headers: headers) { res async in
                let body = res.body.string
                #expect(body.contains(">Gesamte Serie erneut gesehen<"))
                #expect(body.contains("Alle erschienenen Folgen noch einmal als gesehen markieren?"))
            }
        }
    }

    @Test func webSeasonRewatch() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 2], runtime: 30)
            _ = try await ws(app).markSeason(userID: user.requireID(), titleID: show.requireID(), season: 1, service: nil)
            let headers = try await login(app, "pat")
            try await app.testing().test(.POST, "/tv/1/seasons/1/watch", headers: headers.adding(.htmx), beforeRequest: { req in
                try req.content.encode(SeasonWatchForm(service: "", rewatch: "true"), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            #expect(try await counts(app, user, show) == ["1x1": 2, "1x2": 2])
        }
    }

    @Test func apiSeriesRewatch() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 2], runtime: 30)
            _ = try await ws(app).markSeries(userID: user.requireID(), titleID: show.requireID(), service: nil)
            let token = try await apiToken(app, user)
            try await app.testing().test(.POST, "/api/v1/tv/1/watch-all", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(WatchInputBody(rewatch: true), as: .json)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            #expect(try await counts(app, user, show) == ["1x1": 2, "1x2": 2])
        }
    }
}
