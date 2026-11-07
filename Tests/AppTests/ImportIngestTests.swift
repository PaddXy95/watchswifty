@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct UploadForm: Content { var file: File }

@Suite("ImportIngest")
struct ImportIngestTests {
    func rows(_ app: Application, _ user: User) async throws -> [NetflixRow] {
        try await NetflixRow.query(on: app.db).filter(\.$user.$id == user.requireID()).all()
    }

    @Test func ingestFixture() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let summary = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            #expect(summary == ImportSummary(total: 21, new: 19, known: 0, skipped: 2))
            let stored = try await rows(app, user)
            #expect(stored.count == 19)
            #expect(stored.allSatisfy { $0.rowStatus == .pending })
            let ds9 = try #require(stored.first { $0.rawTitle.contains("Extreme Maßnahmen") })
            #expect(ds9.showName == "Star Trek: Deep Space Nine")
            #expect(ds9.seasonNumber == 7)
            #expect(ds9.episodeTitle == "Extreme Maßnahmen (7)")
            #expect(ds9.parsedKind == "episode")
            #expect(ds9.watchedOn == "2025-03-02")
            let movie = try #require(stored.first { $0.rawTitle == "Das fünfte Element" })
            #expect(movie.parsedKind == "movie")
            #expect(try await NetflixImport.query(on: app.db).count() == 1)
        }
    }

    @Test func reimportIsIdempotent() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let service = ImportService(db: app.db)
            _ = try await service.ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            let second = try await service.ingest(text: try fixtureText(), filename: "b.csv", userID: user.requireID())
            #expect(second == ImportSummary(total: 21, new: 0, known: 19, skipped: 2))
            #expect(try await rows(app, user).count == 19)
        }
    }

    @Test func fingerprintsArePerUser() async throws {
        try await withTestApp { app in
            let alice = try await createUser(app, "alice")
            let bob = try await createUser(app, "bobby")
            let service = ImportService(db: app.db)
            _ = try await service.ingest(text: try fixtureText(), filename: "a.csv", userID: alice.requireID())
            let summary = try await service.ingest(text: try fixtureText(), filename: "a.csv", userID: bob.requireID())
            #expect(summary.new == 19)
        }
    }

    @Test func wrongFileStoresNothing() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            await #expect(throws: NetflixCSVError.notNetflixHistory) {
                _ = try await ImportService(db: app.db).ingest(text: "Profile Name,Start Time\nPat,2026\n", filename: "x.csv", userID: user.requireID())
            }
            #expect(try await NetflixRow.query(on: app.db).count() == 0)
            #expect(try await NetflixImport.query(on: app.db).count() == 0)
        }
    }

    @Test func uploadViaHTTP() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.POST, "/import", headers: headers, beforeRequest: { req in
                try req.content.encode(UploadForm(file: File(data: ByteBuffer(string: try fixtureText()), filename: "NetflixViewingHistory.csv")), as: .formData)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("19 neu, 0 bereits bekannt, 2 übersprungen (leerer Titel)"))
            })
        }
    }

    @Test func uploadWrongFile422() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.POST, "/import", headers: headers, beforeRequest: { req in
                try req.content.encode(UploadForm(file: File(data: ByteBuffer(string: "Profile Name,Start Time\nPat,x\n"), filename: "ViewingActivity.csv")), as: .formData)
            }, afterResponse: { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("Das ist keine Netflix-Wiedergabeaktivität"))
            })
            try await app.testing().test(.POST, "/import", headers: headers, beforeRequest: { req in
                try req.content.encode(UploadForm(file: File(data: ByteBuffer(string: "Title,Date\n\"A\",\"2026-11-07\"\n"), filename: "a.csv")), as: .formData)
            }, afterResponse: { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("Zeile 2: ungültiges Datum „2026-11-07“."))
            })
        }
    }

    @Test func importPageRenders() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/import", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("multipart/form-data"))
            }
        }
    }

    @Test func deletingImportedWatchDiscardsRow() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let service = ImportService(db: app.db)
            _ = try await service.ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            let show = try await seedSeries(app, tmdbID: 1, seasons: [4: 2])
            let ws = WatchService(db: app.db)
            let watch = try await ws.markEpisode(userID: user.requireID(), episodeID: episode(app, show, 4, 1).requireID(), day: "2026-11-07", service: .netflix)
            let row = try #require(try await rows(app, user).first { $0.rawTitle == "The Mentalist: Staffel 4: Die Aura des Todes" })
            row.$watch.id = try watch.requireID()
            row.status = RowStatus.matched.rawValue
            try await row.save(on: app.db)

            try await ws.deleteWatch(userID: user.requireID(), watchID: watch.requireID())
            let reloaded = try #require(try await NetflixRow.find(row.requireID(), on: app.db))
            #expect(reloaded.rowStatus == .discarded)

            _ = try await service.ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            let again = try #require(try await NetflixRow.find(row.requireID(), on: app.db))
            #expect(again.rowStatus == .discarded)
            #expect(try await rows(app, user).count == 19)
        }
    }

    @Test func unmarkEpisodeDiscardsLinkedRows() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            let show = try await seedSeries(app, tmdbID: 1, seasons: [4: 2])
            let ws = WatchService(db: app.db)
            let e1 = try await episode(app, show, 4, 1)
            let watch = try await ws.markEpisode(userID: user.requireID(), episodeID: e1.requireID(), day: "2026-11-07", service: .netflix)
            let row = try #require(try await rows(app, user).first)
            row.$watch.id = try watch.requireID()
            row.status = RowStatus.matched.rawValue
            try await row.save(on: app.db)
            try await ws.unmarkEpisode(userID: user.requireID(), episodeID: e1.requireID())
            #expect(try await NetflixRow.find(row.requireID(), on: app.db)?.rowStatus == .discarded)
        }
    }
}
