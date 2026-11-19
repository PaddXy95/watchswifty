@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

/// The shared matching worker must not send statements whose bind count grows with stored data: above SQLite's
/// limit the whole pass fails for every user (security audit F04/F15).
@Suite("MatchingScale")
struct MatchingScaleTests {
    static let many = 1_200
    static let bindLimit = 1_000

    func mappings(_ app: Application, user: User, prefix: String, status: MappingStatus, titleID: UUID? = nil) async throws {
        let userID = try user.requireID()
        let created = (0..<Self.many).map { index in
            let mapping = NetflixMapping(userID: userID, netflixName: "\(prefix) \(index)", kind: .movie)
            mapping.status = status.rawValue
            mapping.$title.id = titleID
            return mapping
        }
        try await created.create(on: app.db)
    }

    @Test func workerStatementsStayBoundedWithManyNamesAndMappings() async throws {
        try await withTestApp { app in
            let mallory = try await createUser(app, "mallory", tmdbToken: nil)
            let ben = try await createUser(app, "ben")
            let movie = try await seedMovie(app, tmdbID: 77, name: "Film")
            let csv = "Title,Date\n" + (0..<Self.many).map { "Show \($0): Folge,1/1/20" }.joined(separator: "\n")
            _ = try await ImportService(db: app.db).ingest(text: csv, filename: "a.csv", userID: mallory.requireID())
            try await mappings(app, user: ben, prefix: "Ignoriert", status: .ignored)
            try await mappings(app, user: ben, prefix: "Bestätigt", status: .confirmed, titleID: movie.requireID())
            try await mappings(app, user: ben, prefix: "Prüfen", status: .review)

            let recorder = SQLBindRecorder()
            let worker = MatchingWorker(db: recorder.database(app), provider: TMDBProvider { _ in FakeTMDBClient() }, logger: app.logger,
                                        cipher: app.tokenCipher, enabled: false)
            _ = try await worker.processAll()

            #expect(recorder.saw("\"show_name\" IN"))
            let largest = try #require(recorder.largest)
            #expect(largest.binds <= Self.bindLimit, "\(largest.binds) binds: \(largest.sql.prefix(200))")
        }
    }

    /// `many` unmatched rows of one confirmed movie mapping.
    func unmatchedRows(_ app: Application, _ user: User, _ movie: Title) async throws {
        let userID = try user.requireID()
        let csv = "Title,Date\n" + Array(repeating: "Film,1/1/20", count: Self.many).joined(separator: "\n")
        _ = try await ImportService(db: app.db).ingest(text: csv, filename: "a.csv", userID: userID)
        let mapping = NetflixMapping(userID: userID, netflixName: "Film", kind: .movie)
        mapping.status = MappingStatus.confirmed.rawValue
        mapping.$title.id = try movie.requireID()
        try await mapping.save(on: app.db)
        try await NetflixRow.query(on: app.db).filter(\.$user.$id == userID)
            .set(\.$mapping.$id, to: mapping.requireID()).set(\.$status, to: RowStatus.unmatched.rawValue).update()
    }

    @Test func requeueStaysBoundedForManyUnmatchedRows() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let movie = try await seedMovie(app, tmdbID: 77, name: "Film")
            try await unmatchedRows(app, user, movie)

            let recorder = SQLBindRecorder()
            let requeued = try await requeueUnmatchedRows(titleID: movie.requireID(), on: recorder.database(app))

            #expect(requeued == Self.many)
            #expect(recorder.saw("UPDATE \"netflix_rows\""))
            #expect(try await NetflixRow.query(on: app.db).filter(\.$status == RowStatus.pending.rawValue).count() == Self.many)
            let largest = try #require(recorder.largest)
            #expect(largest.binds <= Self.bindLimit, "\(largest.binds) binds: \(largest.sql.prefix(200))")
        }
    }

    @Test func titleUsersStaysBoundedForLongFilmLists() async throws {
        try await withTestApp { app in
            let userID = try await createUser(app, "pat").requireID()
            let movie = try await seedMovie(app, tmdbID: 1, name: "Film")
            let entries = (1...Self.many).map { index in
                let entry = FilmListEntry(userID: userID, position: index,
                                          draft: FilmListDraft(title: "Film \(index)", year: nil, watches: [], rating: nil, comment: nil))
                entry.tmdbID = index
                return entry
            }
            try await entries.create(on: app.db)

            let recorder = SQLBindRecorder()
            let users = try await titleUsers(on: recorder.database(app))

            #expect(users[try movie.requireID()] == [userID])
            #expect(recorder.saw("\"tmdb_id\" IN"))
            let largest = try #require(recorder.largest)
            #expect(largest.binds <= Self.bindLimit, "\(largest.binds) binds: \(largest.sql.prefix(200))")
        }
    }
}
