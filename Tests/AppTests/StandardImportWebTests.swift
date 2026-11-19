@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("StandardImportWeb")
struct StandardImportWebTests {
    func upload(_ app: Application, _ headers: HTTPHeaders, _ data: Data, check: @escaping @Sendable (TestingHTTPResponse) async throws -> Void) async throws {
        try await app.testing().test(.POST, "/import/standard", headers: headers, beforeRequest: { req in
            try req.content.encode(UploadForm(file: File(data: ByteBuffer(bytes: Array(data)), filename: "export.csv")), as: .formData)
        }, afterResponse: check)
    }

    func entries(_ app: Application, _ user: User) async throws -> [ImportEntry] {
        try await ImportEntryService(db: app.db).entries(userID: user.requireID())
    }

    @Test func importPageLinksToStandardImport() async throws {
        try await withTestApp { app in
            _ = try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/import", headers: headers) { res async in
                #expect(res.body.string.contains(#"href="/import/standard""#))
                #expect(!res.body.string.contains("/import/films"))
            }
        }
    }

    @Test func pageShowsFormatHelp() async throws {
        try await withTestApp { app in
            _ = try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/import/standard", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Aus anderen Trackern importieren"))
                #expect(res.body.string.contains(#"href="/import/watchswifty-import-example.csv""#))
                #expect(res.body.string.contains("docs/import.md#other-trackers-standard-csv"))
            }
        }
    }

    @Test func exampleFileIsServedAndValid() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Public/import/watchswifty-import-example.csv")
        let file = try parseStandardImport(try String(contentsOf: url, encoding: .utf8))
        #expect(file.skippedRows == 0)
        #expect(Set(file.rows.map(\.type)) == [.movie, .episode, .series])
    }

    @Test func uploadAndReviewFlow() async throws {
        let tmdb = StandardImportTests.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            let csv = "type,title,season,episode\nmovie,Dune,,\nepisode,Severance,1,1\npodcast,X,,\n"
            try await upload(app, headers, Data(csv.utf8)) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("2 Titel übernommen"))
                #expect(res.body.string.contains("1 Zeile übersprungen"))
            }
            _ = try await app.importWorker.processAll()
            try await app.testing().test(.GET, "/import/standard", headers: headers) { res async in
                let body = res.body.string
                #expect(body.contains(">Übernehmen</button>"))
                #expect(body.contains("Film"))
                #expect(body.contains("Serie"))
                #expect(body.contains(#"href="/tv/95396""#))
            }
            let list = try await entries(app, user)
            let dune = try list[0].requireID()
            try await app.testing().test(.POST, "/import/standard/\(dune)/search", headers: headers, beforeRequest: { req in
                try req.content.encode(["q": "Dune"], as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            #expect(try await ImportEntry.find(dune, on: app.db)?.entryStatus == .review)
            try await app.testing().test(.POST, "/import/standard/\(dune)/accept", headers: headers, beforeRequest: { req in
                try req.content.encode(["tmdbID": 438631], as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains(#"href="/movie/438631""#))
            })
            #expect(try await ImportEntry.find(dune, on: app.db)?.entryStatus == .imported)
            try await app.testing().test(.POST, "/import/standard/\(try list[1].requireID())/skip", headers: headers) { res async in
                #expect(res.status == .ok)
            }
            #expect(try await ImportEntry.find(list[1].requireID(), on: app.db)?.entryStatus == .skipped)
        }
    }

    @Test func uploadErrors() async throws {
        try await withTestApp { app in
            _ = try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await upload(app, headers, Data("Filmname\nDune\n".utf8)) { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("Kein Standard-Import erkannt"))
            }
            try await upload(app, headers, Data("type,title\n".utf8)) { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("Die Datei enthält keine Titel."))
            }
        }
    }

    @Test func uploadWindows1252() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            let data = try #require("type;title\nmovie;Amélie\n".data(using: .windowsCP1252))
            try await upload(app, headers, data) { res async in
                #expect(res.status == .ok)
            }
            #expect(try await entries(app, user).map(\.title) == ["Amélie"])
        }
    }

    @Test func uploadFourMegabytes() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            let big = "type,title,comment\nmovie,Dune," + String(repeating: "x", count: 4 * 1024 * 1024) + "\n"
            try await upload(app, headers, Data(big.utf8)) { res async in
                #expect(res.status == .ok)
            }
            #expect(try await entries(app, user).count == 1)
            let tooBig = "type,title\n" + String(repeating: "x", count: 5 * 1024 * 1024)
            try await upload(app, headers, Data(tooBig.utf8)) { res async in
                #expect(res.status == .payloadTooLarge)
            }
        }
    }

    @Test func cardShowsMissingEpisodes() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            let entry = ImportEntry(userID: try user.requireID(), position: 0, draft: ImportDraft(
                kind: .tv, title: "Severance", year: nil, tmdbHint: nil, imdbID: nil,
                watches: [ImportWatch(season: 1, episode: 9, day: nil, service: nil)], rating: nil, comment: nil))
            entry.status = ImportEntryStatus.imported.rawValue
            entry.tmdbID = 95396
            entry.missingEpisodes = 2
            try await entry.save(on: app.db)
            try await app.testing().test(.GET, "/import/standard", headers: headers) { res async in
                #expect(res.body.string.contains("2 Episoden nicht gefunden"))
                #expect(res.body.string.contains("Serie öffnen"))
            }
        }
    }

    @Test func entriesArePrivate() async throws {
        try await withTestApp { app in
            let owner = try await createUser(app, "pat")
            _ = try await createUser(app, "other")
            try await ImportEntryService(db: app.db).replace(userID: owner.requireID(), drafts: [ImportDraft(
                kind: .movie, title: "Dune", year: nil, tmdbHint: nil, imdbID: nil, watches: [], rating: nil, comment: nil)])
            let id = try await entries(app, owner)[0].requireID()
            let headers = try await login(app, "other")
            try await app.testing().test(.POST, "/import/standard/\(id)/skip", headers: headers) { res async in
                #expect(res.status == .notFound)
            }
        }
    }
}
