import Fluent
import Foundation
import Vapor

struct ImportSummary: Sendable, Equatable {
    let total: Int
    let new: Int
    let known: Int
    let skipped: Int
}

struct ImportService {
    /// Netflix rows one user may keep; far above a real viewing history, but it bounds what the import page and the
    /// matching worker handle per user (security audit F04/F16).
    static let maxStoredRows = 200_000

    let db: any Database
    var maxStoredRows = ImportService.maxStoredRows

    /// Parses an export and stores rows the user does not have yet (idempotent per fingerprint).
    /// Nothing is stored when the file is invalid or the user would keep more than `maxStoredRows` rows.
    func ingest(text: String, filename: String, userID: UUID) async throws -> ImportSummary {
        let parsed = try parseNetflixCSV(text)
        let existing = Set(try await NetflixRow.query(on: db).filter(\.$user.$id == userID)
            .field(\.$fingerprint).all().map(\.fingerprint))
        let fresh = parsed.rows.filter { !existing.contains($0.fingerprint) }
        guard existing.count + fresh.count <= maxStoredRows else { throw NetflixCSVError.tooManyRows(limit: maxStoredRows) }
        let summary = ImportSummary(total: parsed.rows.count + parsed.skippedBlank, new: fresh.count,
                                    known: parsed.rows.count - fresh.count, skipped: parsed.skippedBlank)
        try await db.transaction { db in
            let record = NetflixImport(userID: userID, filename: filename, summary: summary)
            try await record.save(on: db)
            let importID = try record.requireID()
            var start = 0
            while start < fresh.count {
                let chunk = fresh[start..<min(start + 500, fresh.count)].map { NetflixRow(userID: userID, importID: importID, row: $0) }
                try await chunk.create(on: db)
                start += 500
            }
        }
        return summary
    }
}
