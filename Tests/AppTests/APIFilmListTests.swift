@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct FilmEntryBody: Codable {
    let id: UUID; let title: String; let year: Int?; let watchCount: Int; let rating: Int?; let status: String
    let tmdbId: Int?; let candidates: [SearchResultBody]; let error: String?
}
struct FilmListBody: Codable {
    struct Counts: Codable { let imported: Int; let review: Int; let notFound: Int; let skipped: Int; let pending: Int }
    let counts: Counts; let error: String?; let entries: [FilmEntryBody]
}
struct FilmSearchBody: Content { var q: String }
struct FilmAcceptBody: Content { var tmdbId: Int }

@Suite("APIFilmList")
struct APIFilmListTests {
    func upload(_ app: Application, _ token: String, _ text: String) async throws -> (HTTPStatus, String) {
        var result: (HTTPStatus, String) = (.internalServerError, "")
        try await app.testing().test(.POST, "/api/v1/imports/films", headers: .bearer(token), beforeRequest: { req in
            try req.content.encode(UploadForm(file: File(data: ByteBuffer(string: text), filename: "Filme.csv")), as: .formData)
        }, afterResponse: { res async in
            result = (res.status, res.body.string)
        })
        return result
    }

    func list(_ app: Application, _ token: String) async throws -> FilmListBody? {
        var body: FilmListBody?
        try await app.testing().test(.GET, "/api/v1/imports/films", headers: .bearer(token)) { res async in
            body = try? res.content.decode(FilmListBody.self)
        }
        return body
    }

    @Test func filmListUploadAndResolve() async throws {
        try await withTestApp(tmdb: FilmListImportTests.fake()) { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let (status, body) = try await upload(app, token, filmListSample)
            #expect(status == .ok)
            #expect(body.contains(#""films" : 4"#) || body.contains(#""films":4"#))
            #expect(try await list(app, token)?.counts.pending == 4)
            _ = try await app.filmListWorker.processAll()
            let after = try #require(try await list(app, token))
            #expect(after.counts.imported == 1)
            #expect(after.counts.review == 1)
            #expect(after.counts.notFound == 2)
            #expect(after.entries.first { $0.title == "Inselrätsel" }?.candidates.map(\.tmdbId) == [604, 605])
            #expect(after.entries.first { $0.title == "Inselrätsel" }?.watchCount == 2)
        }
    }

    @Test func filmListUploadLimit() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let (status, body) = try await upload(app, token, filmListSample + String(repeating: "x", count: 2 * 1024 * 1024))
            #expect(status == .payloadTooLarge)
            #expect(body.contains("payloadTooLarge"))
            let (wrongStatus, wrongBody) = try await upload(app, token, "Title,Date\nX,1/1/24\n")
            #expect(wrongStatus == .unprocessableEntity)
            #expect(wrongBody.contains("Filmname"))
        }
    }

    @Test func acceptSearchSkip() async throws {
        try await withTestApp(tmdb: FilmListImportTests.fake()) { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            _ = try await upload(app, token, filmListSample)
            _ = try await app.filmListWorker.processAll()
            let entries = try #require(try await list(app, token)?.entries)
            let review = try #require(entries.first { $0.status == "review" })
            try await app.testing().test(.POST, "/api/v1/imports/films/\(review.id)/accept", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(FilmAcceptBody(tmdbId: 604), as: .json)
            }, afterResponse: { res async throws in
                #expect(try res.content.decode(FilmEntryBody.self).status == "imported")
            })
            let missing = try #require(entries.first { $0.title == "Nachtfahrt" })
            try await app.testing().test(.POST, "/api/v1/imports/films/\(missing.id)/search", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(FilmSearchBody(q: "Insel"), as: .json)
            }, afterResponse: { res async throws in
                let entry = try res.content.decode(FilmEntryBody.self)
                #expect(entry.status == "review")
                #expect(entry.candidates.map(\.tmdbId) == [604])
            })
            let other = try #require(entries.first { $0.title == "Ohne Datum" })
            try await app.testing().test(.POST, "/api/v1/imports/films/\(other.id)/skip", headers: .bearer(token)) { res async throws in
                #expect(try res.content.decode(FilmEntryBody.self).status == "skipped")
            }
            try await app.testing().test(.POST, "/api/v1/imports/films/retry", headers: .bearer(token)) { res async in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func foreignEntry404() async throws {
        try await withTestApp(tmdb: FilmListImportTests.fake()) { app in
            let owner = try await createUser(app, "pat")
            try await FilmListService(db: app.db).replace(userID: owner.requireID(), drafts: groupFilmList(try parseFilmList(filmListSample)))
            let entry = try #require(try await FilmListEntry.query(on: app.db).first())
            let stranger = try await createUser(app, "fremd")
            let token = try await apiToken(app, stranger)
            try await app.testing().test(.POST, "/api/v1/imports/films/\(try entry.requireID())/skip", headers: .bearer(token)) { res async in
                #expect(res.status == .notFound)
            }
        }
    }
}
