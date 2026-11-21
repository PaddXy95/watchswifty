@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("AccountStreaming")
struct AccountStreamingTests {
    struct StreamingForm: Content {
        var region: String
        var providers: [Int]
    }

    static func fake() -> FakeTMDBClient {
        let tmdb = FakeTMDBClient()
        tmdb.setRegions([TMDBRegion(code: "DE", name: "Deutschland"), TMDBRegion(code: "AT", name: "Österreich")])
        tmdb.setProviders(kind: .movie, region: "DE", [TMDBProviderInfo(providerID: 8, name: "Netflix", logoPath: "/n.jpg", displayPriority: 2),
                                                       TMDBProviderInfo(providerID: 337, name: "Disney Plus", logoPath: "/d.jpg", displayPriority: 1)])
        tmdb.setProviders(kind: .tv, region: "DE", [TMDBProviderInfo(providerID: 8, name: "Netflix", logoPath: "/n.jpg", displayPriority: 2),
                                                    TMDBProviderInfo(providerID: 30, name: "WOW", logoPath: nil, displayPriority: 5)])
        return tmdb
    }

    func user(_ app: Application, token: Bool = true) async throws -> (User, HTTPHeaders) {
        let user = try await createUser(app, "pat", tmdbToken: token ? try app.tokenCipher.seal("tok") : nil)
        return (user, try await login(app, "pat"))
    }

    func account(_ app: Application, _ headers: HTTPHeaders) async throws -> String {
        var body = ""
        try await app.testing().test(.GET, "/account?open=streaming", headers: headers) { res async in body = res.body.string }
        return body
    }

    @Test func accountShowsServicesWithLogos() async throws {
        try await withTestApp(tmdb: Self.fake()) { app in
            let (pat, headers) = try await user(app)
            try await UserStreamingService(userID: pat.requireID(), providerID: 8).save(on: app.db)
            let body = try await account(app, headers)
            #expect(body.contains("Streamingdienste"))
            #expect(body.contains("https://image.tmdb.org/t/p/w92/n.jpg"))
            #expect(body.contains(#"value="8" checked"#))
            #expect(body.contains(#"<option value="DE" selected>Deutschland</option>"#))
            // Disney Plus (priority 1) before Netflix (2) before WOW (5); Netflix listed once.
            let disney = try #require(body.range(of: "Disney Plus")), netflix = try #require(body.range(of: ">Netflix<")),
                wow = try #require(body.range(of: ">WOW<"))
            #expect(disney.lowerBound < netflix.lowerBound && netflix.lowerBound < wow.lowerBound)
            #expect(body.components(separatedBy: ">Netflix<").count == 2)
        }
    }

    @Test func saveStreamingPersists() async throws {
        let tmdb = Self.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let (pat, headers) = try await user(app)
            let movie = try await seedMovie(app, tmdbID: 603)
            try await WatchLaterEntry(userID: pat.requireID(), titleID: movie.requireID(), addedAt: .now, addedOn: "2026-11-07",
                                      baselined: true).save(on: app.db)
            try await app.testing().test(.POST, "/account/streaming", headers: headers, beforeRequest: { req in
                try req.content.encode(StreamingForm(region: "AT", providers: [8, 337]), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Streamingdienste gespeichert."))
            })
            await app.backgroundTasks.drain()
            let settings = try await StreamingSettingsService(db: app.db).settings(user: try #require(try await User.find(pat.requireID(), on: app.db)))
            #expect(settings == StreamingSettings(region: "AT", providerIDs: [8, 337]))
            #expect(tmdb.calls.contains("watch_providers:movie:603"))   // new country: list fetched in the background
        }
    }

    @Test func invalidRegionShowsError() async throws {
        try await withTestApp(tmdb: Self.fake()) { app in
            let (_, headers) = try await user(app)
            try await app.testing().test(.POST, "/account/streaming", headers: headers, beforeRequest: { req in
                try req.content.encode(StreamingForm(region: "xx", providers: []), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("Unbekanntes Land."))
            })
        }
    }

    @Test func noTokenShowsHint() async throws {
        try await withTestApp(tmdb: Self.fake()) { app in
            let (_, headers) = try await user(app, token: false)
            #expect(try await account(app, headers).contains("Für die Auswahl der Dienste wird ein TMDB-Token benötigt"))
        }
    }

    @Test func providersFragmentForRegion() async throws {
        try await withTestApp(tmdb: Self.fake()) { app in
            let (_, headers) = try await user(app)
            try await app.testing().test(.GET, "/account/streaming/providers?region=DE", headers: headers.adding(.htmx)) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Netflix"))
                #expect(!res.body.string.contains("<html"))
            }
        }
    }

    @Test func notificationsFormHasAvailabilitySwitch() async throws {
        struct Form: Content { var available: String?; var channel: String }
        try await withTestApp(tmdb: Self.fake()) { app in
            let (pat, headers) = try await user(app)
            try await NotificationSettingsService(db: app.db).save(dailyRunTime: "07:00", webhookURL: nil)
            let body = try await account(app, headers)
            #expect(body.contains("Wenn ein Titel aus „Später ansehen“ bei einem meiner Dienste verfügbar wird"))
            try await app.testing().test(.POST, "/account/notifications", headers: headers, beforeRequest: { req in
                try req.content.encode(Form(available: "on", channel: "mail"), as: .urlEncodedForm)
            })
            #expect(try await User.find(pat.requireID(), on: app.db)?.notifyAvailable == true)
        }
    }
}
