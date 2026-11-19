@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct ImportEntryBody: Codable {
    let id: UUID; let kind: String; let title: String; let year: Int?; let watchCount: Int; let rating: Int?; let status: String
    let tmdbId: Int?; let candidates: [SearchResultBody]; let missingEpisodes: Int; let addedWatches: Int; let error: String?
}
struct ImportListBody: Codable {
    struct Counts: Codable { let imported: Int; let review: Int; let notFound: Int; let skipped: Int; let pending: Int }
    let counts: Counts; let error: String?; let entries: [ImportEntryBody]
}
struct ImportUploadBody: Codable { let titles: Int; let skippedRows: Int }
struct ImportSearchBody: Content { var q: String }
struct ImportAcceptBody: Content { var tmdbId: Int }

@Suite("APIStandardImport")
struct APIStandardImportTests {
    static let csv = "type,title,season,episode\nmovie,Dune,,\nepisode,Severance,1,1\nepisode,Severance,4,1\npodcast,X,,\n"

    func upload(_ app: Application, _ token: String, _ text: String) async throws -> (HTTPStatus, String) {
        var result: (HTTPStatus, String) = (.internalServerError, "")
        try await app.testing().test(.POST, "/api/v1/imports/standard", headers: .bearer(token), beforeRequest: { req in
            try req.content.encode(UploadForm(file: File(data: ByteBuffer(string: text), filename: "export.csv")), as: .formData)
        }, afterResponse: { res async in
            result = (res.status, res.body.string)
        })
        return result
    }

    func list(_ app: Application, _ token: String) async throws -> ImportListBody? {
        var body: ImportListBody?
        try await app.testing().test(.GET, "/api/v1/imports/standard", headers: .bearer(token)) { res async in
            body = try? res.content.decode(ImportListBody.self)
        }
        return body
    }

    @Test func apiUploadAndResolve() async throws {
        try await withTestApp(tmdb: StandardImportTests.fake()) { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let (status, body) = try await upload(app, token, Self.csv)
            #expect(status == .ok)
            let summary = try JSONDecoder().decode(ImportUploadBody.self, from: Data(body.utf8))
            #expect(summary.titles == 2)
            #expect(summary.skippedRows == 1)
            #expect(try await list(app, token)?.counts.pending == 2)
            _ = try await app.importWorker.processAll()
            let after = try #require(try await list(app, token))
            #expect(after.counts.imported == 1)
            #expect(after.counts.review == 1)
            let dune = try #require(after.entries.first { $0.title == "Dune" })
            #expect(dune.kind == "movie")
            #expect(dune.candidates.map(\.tmdbId) == [438631, 841])
            let severance = try #require(after.entries.first { $0.title == "Severance" })
            #expect(severance.kind == "tv")
            #expect(severance.watchCount == 2)
            #expect(severance.missingEpisodes == 1)
            #expect(severance.addedWatches == 1)
            #expect(severance.tmdbId == 95396)
        }
    }

    @Test func apiUploadLimit() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let (status, body) = try await upload(app, token, "type,title\n" + String(repeating: "x", count: 5 * 1024 * 1024))
            #expect(status == .payloadTooLarge)
            #expect(body.contains("payloadTooLarge"))
            let (okStatus, _) = try await upload(app, token, "type,title,comment\nmovie,Dune," + String(repeating: "x", count: 4 * 1024 * 1024) + "\n")
            #expect(okStatus == .ok)
        }
    }

    @Test func apiUploadErrors() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let (status, body) = try await upload(app, token, "Filmname\nDune\n")
            #expect(status == .unprocessableEntity)
            #expect(body.contains("Kein Standard-Import erkannt"))
        }
    }

    @Test func apiAcceptSearchSkip() async throws {
        try await withTestApp(tmdb: StandardImportTests.fake()) { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            _ = try await upload(app, token, "type,title\nmovie,Dune\nmovie,Nichts\nmovie,Heat\n")
            _ = try await app.importWorker.processAll()
            let entries = try #require(try await list(app, token)?.entries)
            let review = try #require(entries.first { $0.status == "review" })
            try await app.testing().test(.POST, "/api/v1/imports/standard/\(review.id)/accept", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(ImportAcceptBody(tmdbId: 438631), as: .json)
            }, afterResponse: { res async throws in
                let entry = try res.content.decode(ImportEntryBody.self)
                #expect(entry.status == "imported")
                #expect(entry.tmdbId == 438631)
            })
            let missing = try #require(entries.first { $0.title == "Nichts" })
            try await app.testing().test(.POST, "/api/v1/imports/standard/\(missing.id)/search", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(ImportSearchBody(q: "Dune"), as: .json)
            }, afterResponse: { res async throws in
                let entry = try res.content.decode(ImportEntryBody.self)
                #expect(entry.status == "review")
                #expect(entry.candidates.map(\.tmdbId) == [438631, 841])
            })
            let other = try #require(entries.first { $0.title == "Heat" })
            try await app.testing().test(.POST, "/api/v1/imports/standard/\(other.id)/skip", headers: .bearer(token)) { res async throws in
                #expect(try res.content.decode(ImportEntryBody.self).status == "skipped")
            }
            try await app.testing().test(.POST, "/api/v1/imports/standard/retry", headers: .bearer(token)) { res async in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func apiForeignEntry404() async throws {
        try await withTestApp(tmdb: StandardImportTests.fake()) { app in
            let owner = try await createUser(app, "pat")
            _ = try await ImportEntryService(db: app.db).upload(userID: owner.requireID(), text: "type,title\nmovie,Dune\n")
            let entry = try #require(try await ImportEntry.query(on: app.db).first())
            let stranger = try await createUser(app, "fremd")
            let token = try await apiToken(app, stranger)
            try await app.testing().test(.POST, "/api/v1/imports/standard/\(try entry.requireID())/skip", headers: .bearer(token)) { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test func oldFilmEndpointsAreGone() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            try await app.testing().test(.GET, "/api/v1/imports/films", headers: .bearer(token)) { res async in
                #expect(res.status == .notFound)
            }
        }
    }
}
