@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct HistoryPageBody: Codable {
    struct Item: Codable {
        struct Ep: Codable { let season: Int; let number: Int; let name: String }
        let id: UUID; let kind: String; let tmdbId: Int; let title: String; let episode: Ep?; let day: String?; let service: String?; let origin: String
    }
    let items: [Item]; let total: Int; let page: Int; let perPage: Int
}
struct EditWatchBody: Content { var day: String?; var service: String? }

@Suite("APIHistory")
struct APIHistoryTests {
    func page(_ app: Application, _ token: String, _ query: String) async throws -> HistoryPageBody? {
        var body: HistoryPageBody?
        try await app.testing().test(.GET, "/api/v1/history\(query)", headers: .bearer(token)) { res async in
            body = try? res.content.decode(HistoryPageBody.self)
        }
        return body
    }

    @Test func historyNewestFirstWithPaging() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let show = try await seedSeries(app, tmdbID: 1, name: "Dark", seasons: [1: 3])
            let movie = try await seedMovie(app, tmdbID: 603, name: "Matrix")
            let ws = WatchService(db: app.db)
            for n in 1...3 {
                _ = try await ws.markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, n).requireID(), day: "2026-11-0\(n)", service: .netflix)
            }
            _ = try await ws.markMovie(userID: user.requireID(), titleID: movie.requireID(), day: "2026-11-05", service: .cinema)
            let first = try #require(try await page(app, token, "?perPage=2"))
            #expect(first.total == 4)
            #expect(first.items.map(\.title) == ["Matrix", "Dark"])
            #expect(first.items.first?.kind == "movie")
            #expect(first.items[1].episode?.number == 3)
            #expect(first.items[1].service == "netflix")
            let second = try #require(try await page(app, token, "?perPage=2&page=2"))
            #expect(second.items.map { $0.episode?.number } == [2, 1])
        }
    }

    @Test func historyPagingIsClamped() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let body = try #require(try await page(app, token, "?perPage=100000&page=0"))
            #expect(body.perPage == 200)
            #expect(body.page == 1)
            #expect(try await page(app, token, "?perPage=0")?.perPage == 1)
        }
    }

    @Test func editWatchDateAndService() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1])
            let watch = try await WatchService(db: app.db).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 1, 1).requireID(),
                                                                      day: "2026-11-01", service: .netflix)
            try await app.testing().test(.PUT, "/api/v1/watches/\(try watch.requireID())", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(EditWatchBody(day: "2026-10-31", service: "disney_plus"), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let item = try res.content.decode(HistoryPageBody.Item.self)
                #expect(item.day == "2026-10-31")
                #expect(item.service == "disney_plus")
            })
            try await app.testing().test(.PUT, "/api/v1/watches/\(try watch.requireID())", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(EditWatchBody(day: "2027-01-01"), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .unprocessableEntity)
                #expect(try res.content.decode(APIErrorBody.self).message == "Datum liegt in der Zukunft.")
            })
        }
    }

    @Test func deleteWatchDiscardsNetflixRow() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            let show = try await seedSeries(app, tmdbID: 1, seasons: [4: 2])
            let watch = try await WatchService(db: app.db).markEpisode(userID: user.requireID(), episodeID: episode(app, show, 4, 1).requireID(),
                                                                      day: "2026-11-07", service: .netflix)
            let row = try #require(try await NetflixRow.query(on: app.db).filter(\.$user.$id == user.requireID()).first())
            row.$watch.id = try watch.requireID()
            row.status = RowStatus.matched.rawValue
            try await row.save(on: app.db)
            try await app.testing().test(.DELETE, "/api/v1/watches/\(try watch.requireID())", headers: .bearer(token)) { res async in
                #expect(res.status == .noContent)
            }
            #expect(try await Watch.find(watch.requireID(), on: app.db) == nil)
            #expect(try await NetflixRow.find(row.requireID(), on: app.db)?.rowStatus == .discarded)
        }
    }

    @Test func foreignWatch404() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let other = try await createUser(app, "other")
            let token = try await apiToken(app, pat)
            let show = try await seedSeries(app, tmdbID: 1, seasons: [1: 1])
            let watch = try await WatchService(db: app.db).markEpisode(userID: other.requireID(), episodeID: episode(app, show, 1, 1).requireID(),
                                                                      day: "2026-11-01", service: nil)
            try await app.testing().test(.DELETE, "/api/v1/watches/\(try watch.requireID())", headers: .bearer(token)) { res async in
                #expect(res.status == .notFound)
            }
            #expect(try await page(app, token, "")?.total == 0)
        }
    }
}
