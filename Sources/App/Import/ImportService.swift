import Fluent
import Foundation
import Vapor

/// Row counts of one Netflix upload, shown after the upload and stored in `NetflixImport`.
struct ImportSummary: Sendable, Equatable {
    /// All non-empty data lines of the file, including skipped ones.
    let total: Int
    /// Rows stored now because the user did not have them yet.
    let new: Int
    /// Rows already stored from an earlier upload (same fingerprint).
    let known: Int
    /// Rows without a usable title (empty or starting with a colon).
    let skipped: Int
}

/// Stores uploaded Netflix exports as `NetflixRow`s for the `MatchingWorker`.
struct ImportService {
    /// Netflix rows one user may keep; far above a real viewing history, but it bounds what the import page and the
    /// matching worker handle per user (security audit F04/F16).
    static let maxStoredRows = 200_000

    let db: any Database
    var maxStoredRows = ImportService.maxStoredRows

    /// Parses an export and stores rows the user does not have yet (idempotent per fingerprint).
    /// Nothing is stored when the file is invalid or the user would keep more than `maxStoredRows` rows.
    ///
    /// - Parameters:
    ///   - text: The file content, decoded as UTF-8.
    ///   - filename: The uploaded file's name, kept in the `NetflixImport` record.
    ///   - userID: The uploading user.
    /// - Returns: The row counts of this upload.
    /// - Throws: `NetflixCSVError.notNetflixHistory` or `.invalidDate` for an invalid file, `.tooManyRows` above the limit,
    ///   or a database error.
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
