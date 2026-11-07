import Fluent
import Foundation

enum RowStatus: String, Codable, Sendable {
    case pending, matched, unmatched, ignored, discarded
}

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

    init() {}

    init(userID: UUID, filename: String, summary: ImportSummary) {
        self.$user.id = userID
        self.filename = filename
        self.totalRows = summary.total
        self.newRows = summary.new
        self.knownRows = summary.known
        self.skippedRows = summary.skipped
    }
}
