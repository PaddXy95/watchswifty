@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

/// Stored Netflix rows are capped per user, and the status the import page polls is counted in the database
/// instead of loading every row (security audit F16).
@Suite("ImportLimits")
struct ImportLimitsTests {
    func assign(_ app: Application, rawTitle: String, to mapping: NetflixMapping) async throws {
        try await NetflixRow.query(on: app.db).filter(\.$rawTitle == rawTitle).set(\.$mapping.$id, to: mapping.requireID()).update()
    }

    @Test func progressCountsInTheDatabase() async throws {
        try await withTestApp { app in
            let userID = try await createUser(app, "pat", tmdbToken: nil).requireID()
            let lines = ["Prüfen,1/1/20", "Prüfen,1/2/20", "Offen,1/3/20", "Offen,1/4/20", "Offen,1/5/20", "Neu,1/6/20"]
            _ = try await ImportService(db: app.db).ingest(text: "Title,Date\n" + lines.joined(separator: "\n"), filename: "a.csv",
                                                           userID: userID)
            let review = NetflixMapping(userID: userID, netflixName: "Prüfen", kind: .movie)
            review.status = MappingStatus.review.rawValue
            try await review.save(on: app.db)
            let open = NetflixMapping(userID: userID, netflixName: "Offen", kind: .movie)
            try await open.save(on: app.db)
            try await assign(app, rawTitle: "Prüfen", to: review)
            try await assign(app, rawTitle: "Offen", to: open)

            let recorder = SQLBindRecorder()
            let progress = try await ImportStateService(db: recorder.database(app), worker: app.matchingWorker).progress(userID: userID)

            #expect(progress.pendingRows == 4)
            #expect(progress.waitingForReview == 2)
            #expect(!recorder.sqls.isEmpty)
            #expect(recorder.sqls.allSatisfy { $0.contains("COUNT(") }, "\(recorder.sqls)")
        }
    }

    @Test func storedRowsAreCappedPerUser() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat").requireID()
            let ben = try await createUser(app, "ben").requireID()
            let service = ImportService(db: app.db, maxStoredRows: 3)
            _ = try await service.ingest(text: "Title,Date\nA,1/1/20\nB,1/2/20", filename: "a.csv", userID: pat)

            await #expect(throws: NetflixCSVError.tooManyRows(limit: 3)) {
                try await service.ingest(text: "Title,Date\nC,1/3/20\nD,1/4/20", filename: "b.csv", userID: pat)
            }
            #expect(try await NetflixRow.query(on: app.db).filter(\.$user.$id == pat).count() == 2)
            #expect(try await NetflixImport.query(on: app.db).count() == 1)

            // Known rows do not count twice, and every user has their own allowance.
            let summary = try await service.ingest(text: "Title,Date\nA,1/1/20\nB,1/2/20\nC,1/3/20", filename: "c.csv", userID: pat)
            #expect(summary.new == 1)
            _ = try await service.ingest(text: "Title,Date\nA,1/1/20\nB,1/2/20\nC,1/3/20", filename: "a.csv", userID: ben)
            #expect(try await NetflixRow.query(on: app.db).count() == 6)
        }
    }

    @Test func rowCapMessageIsGerman() {
        #expect(NetflixCSVError.tooManyRows(limit: 200_000).germanMessage
            == "Pro Konto werden höchstens 200.000 Netflix-Zeilen gespeichert – dieser Import würde die Grenze überschreiten.")
    }
}
