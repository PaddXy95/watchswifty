@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct ImportSummaryBody: Codable { let new: Int; let known: Int; let skipped: Int }
struct MappingBody: Codable {
    struct TitleRef: Codable { let tmdbId: Int; let name: String }
    let id: UUID; let netflixName: String; let kind: String; let status: String; let title: TitleRef?
}
struct NetflixImportBody: Codable {
    struct Progress: Codable { let running: Bool; let pendingRows: Int; let waitingForReview: Int; let lastError: String? }
    struct Review: Codable { let id: UUID; let netflixName: String; let rowCount: Int; let candidates: [SearchResultBody] }
    struct Unmatched: Codable { let id: UUID; let rawTitle: String; let day: String; let canAssign: Bool }
    let progress: Progress; let review: [Review]; let unmatched: [Unmatched]; let unmatchedTotal: Int; let mappings: [MappingBody]
}
struct SearchResultBody: Codable { let kind: String; let tmdbId: Int; let name: String }
struct DecisionBody: Content { var kind: String; var tmdbId: Int }
struct AssignBody: Content { var episodeId: UUID }
struct EpisodeOptionBody: Codable { let episodeId: UUID; let code: String; let name: String }

@Suite("APINetflixImport")
struct APINetflixImportTests {
    func imported(tmdb: FakeTMDBClient = ImportPageTests.fake(), _ body: (Application, User, String) async throws -> Void) async throws {
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            _ = try await app.matchingWorker.processAll()
            try await body(app, user, try await apiToken(app, user))
        }
    }

    func state(_ app: Application, _ token: String) async throws -> NetflixImportBody? {
        var state: NetflixImportBody?
        try await app.testing().test(.GET, "/api/v1/imports/netflix", headers: .bearer(token)) { res async in
            state = try? res.content.decode(NetflixImportBody.self)
        }
        return state
    }

    func upload(_ app: Application, _ token: String, _ text: String) async throws -> (HTTPStatus, ImportSummaryBody?, APIErrorBody?) {
        var result: (HTTPStatus, ImportSummaryBody?, APIErrorBody?) = (.internalServerError, nil, nil)
        try await app.testing().test(.POST, "/api/v1/imports/netflix", headers: .bearer(token), beforeRequest: { req in
            try req.content.encode(UploadForm(file: File(data: ByteBuffer(string: text), filename: "NetflixViewingHistory.csv")), as: .formData)
        }, afterResponse: { res async in
            result = (res.status, try? res.content.decode(ImportSummaryBody.self), try? res.content.decode(APIErrorBody.self))
        })
        return result
    }

    @Test func uploadFixtureViaAPI() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let (status, summary, error) = try await upload(app, token, try fixtureText())
            #expect(status == .ok, "\(error?.message ?? "")")
            let rows = try await NetflixRow.query(on: app.db).filter(\.$user.$id == user.requireID()).count()
            #expect(summary?.new == rows)
            #expect(try await upload(app, token, try fixtureText()).1?.known == rows)
        }
    }

    @Test func netflixUploadLimit() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let big = "Title,Date\n" + String(repeating: "x", count: 10 * 1024 * 1024)
            let (status, _, error) = try await upload(app, token, big)
            #expect(status == .payloadTooLarge)
            #expect(error?.code == "payloadTooLarge")
        }
    }

    @Test func wrongFileIs422() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            let (status, _, error) = try await upload(app, token, "Profile Name,Start Time\nPat,x\n")
            #expect(status == .unprocessableEntity)
            #expect(error?.message == ImportController.notNetflixMessage)
        }
    }

    @Test func reviewAcceptAndChange() async throws {
        try await imported { app, _, token in
            let current = try #require(try await state(app, token))
            let rick = try #require(current.review.first { $0.netflixName == "Rick and Morty" })
            #expect(rick.candidates.map(\.tmdbId) == [60625, 60626])
            try await app.testing().test(.POST, "/api/v1/imports/netflix/mappings/\(rick.id)/accept", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(DecisionBody(kind: "tv", tmdbId: 60625), as: .json)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode(MappingBody.self).status == "confirmed")
            })
            let mentalist = try #require(current.mappings.first { $0.netflixName == "The Mentalist" })
            try await app.testing().test(.POST, "/api/v1/imports/netflix/mappings/\(mentalist.id)/change", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(DecisionBody(kind: "tv", tmdbId: 1002), as: .json)
            }, afterResponse: { res async throws in
                #expect(try res.content.decode(MappingBody.self).title?.name == "Mentalist (Neu)")
            })
            try await app.testing().test(.GET, "/api/v1/imports/netflix/mappings/\(rick.id)/search?q=Rick%20and%20Morty", headers: .bearer(token)) { res async in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func rowAssignAndIgnore() async throws {
        let tmdb = ImportPageTests.fake()
        tmdb.addSeries(TMDBSeries(id: 1001, name: "The Mentalist", originalName: "The Mentalist", year: 2008, posterPath: nil,
                                  status: "Ended", seasonNumbers: [1, 4]),
                       episodes: [1: ["Pilot"], 4: ["Scharlachrote Briefe", "Die Aura des Todes"]], airDate: "2011-01-01")
        try await imported(tmdb: tmdb) { app, _, token in
            let current = try #require(try await state(app, token))
            let row = try #require(current.unmatched.first { $0.rawTitle.contains("Shakespeare") })
            #expect(row.canAssign)
            var options: [EpisodeOptionBody] = []
            try await app.testing().test(.GET, "/api/v1/imports/netflix/rows/\(row.id)/options", headers: .bearer(token)) { res async in
                options = (try? res.content.decode([EpisodeOptionBody].self)) ?? []
            }
            let target = try #require(options.first { $0.name == "Scharlachrote Briefe" })
            #expect(target.code == "S04E01")
            try await app.testing().test(.POST, "/api/v1/imports/netflix/rows/\(row.id)/assign", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(AssignBody(episodeId: target.episodeId), as: .json)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            #expect(try await NetflixRow.find(row.id, on: app.db)?.rowStatus == .matched)
            let rowID = row.id
            let others = current.unmatched.map(\.id).filter { $0 != rowID }
            if let other = others.first {
                try await app.testing().test(.POST, "/api/v1/imports/netflix/rows/\(other)/ignore", headers: .bearer(token)) { res async in
                    #expect(res.status == .noContent)
                }
            }
        }
    }

    @Test func foreignMapping404() async throws {
        try await imported { app, _, _ in
            let stranger = try await createUser(app, "fremd")
            let token = try await apiToken(app, stranger)
            let mapping = try #require(try await NetflixMapping.query(on: app.db).first())
            try await app.testing().test(.POST, "/api/v1/imports/netflix/mappings/\(try mapping.requireID())/ignore", headers: .bearer(token)) { res async in
                #expect(res.status == .notFound)
            }
        }
    }
}
