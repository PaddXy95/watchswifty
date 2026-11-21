import Fluent
import Foundation

/// What happened to one stored Netflix row (`netflix_rows.status`).
///
/// - `pending`: waiting for the `MatchingWorker` (or for a decision on its name under „Zu prüfen“ (to review)).
/// - `matched`: recorded as a watch (`NetflixRow.watch`).
/// - `unmatched`: the name is mapped, but no episode fit; listed under „Nicht zugeordnet“ (unmatched) for manual
///   assignment.
/// - `ignored`: the user ignored the row or its name.
/// - `discarded`: the watch created from it was deleted by the user, so a re-import must not bring it back.
enum RowStatus: String, Codable, Sendable {
    case pending, matched, unmatched, ignored, discarded
}

/// State of a Netflix name's mapping to a TMDB title (`netflix_mappings.status`).
///
/// - `pending`: not resolved via TMDB yet.
/// - `auto`: the worker found exactly one matching title.
/// - `confirmed`: the user picked or changed the title.
/// - `review`: no clear match; shown under „Zu prüfen“ (to review) with candidates.
/// - `ignored`: the user ignored the name; its rows are ignored too.
enum MappingStatus: String, Codable, Sendable {
    case pending, auto, confirmed, review, ignored
}

/// One uploaded Netflix export.
final class NetflixImport: Model, @unchecked Sendable {
    static let schema = "netflix_imports"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Timestamp(key: "uploaded_at", on: .create) var uploadedAt: Date?
    @Field(key: "filename") var filename: String
    @Field(key: "total_rows") var totalRows: Int
    @Field(key: "new_rows") var newRows: Int
    @Field(key: "known_rows") var knownRows: Int
    @Field(key: "skipped_rows") var skippedRows: Int

    /// Creates an empty model for Fluent.
    init() {}

    /// Creates the record of one upload with its row counts.
    /// - Parameters:
    ///   - userID: The uploading user.
    ///   - filename: The uploaded file's name.
    ///   - summary: The row counts computed by `ImportService.ingest`.
    init(userID: UUID, filename: String, summary: ImportSummary) {
        self.$user.id = userID
        self.filename = filename
        self.totalRows = summary.total
        self.newRows = summary.new
        self.knownRows = summary.known
        self.skippedRows = summary.skipped
    }
}
