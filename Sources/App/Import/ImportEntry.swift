import Fluent
import Foundation

enum ImportEntryStatus: String, Codable, Sendable {
    case pending, imported, review
    case notFound = "not_found"
    case skipped
}

/// One title of an uploaded standard import file, waiting for (or done with) its TMDB match
/// (spec `2026-11-19-standard-import-design.md` §5).
final class ImportEntry: Model, @unchecked Sendable {
    static let schema = "import_entries"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "position") var position: Int
    /// `TitleKind` raw value.
    @Field(key: "kind") var kind: String
    @Field(key: "title") var title: String
    @OptionalField(key: "year") var year: Int?
    /// `tmdb_id` from the file.
    @OptionalField(key: "tmdb_hint") var tmdbHint: Int?
    @OptionalField(key: "imdb_id") var imdbID: String?
    /// JSON `[ImportWatch]`.
    @Field(key: "watches") var watches: String
    @OptionalField(key: "rating") var rating: Int?
    @OptionalField(key: "comment") var comment: String?
    @Field(key: "status") var status: String
    /// The matched TMDB id.
    @OptionalField(key: "tmdb_id") var tmdbID: Int?
    /// JSON `[TMDBSearchResult]` for review.
    @OptionalField(key: "candidates") var candidates: String?
    @Field(key: "missing_episodes") var missingEpisodes: Int
    @Field(key: "added_watches") var addedWatches: Int
    @OptionalField(key: "error") var error: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userID: UUID, position: Int, draft: ImportDraft) {
        self.$user.id = userID
        self.position = position
        self.kind = draft.kind.rawValue
        self.title = draft.title
        self.year = draft.year
        self.tmdbHint = draft.tmdbHint
        self.imdbID = draft.imdbID
        self.watches = Self.encode(draft.watches) ?? "[]"
        self.rating = draft.rating
        self.comment = draft.comment
        self.status = ImportEntryStatus.pending.rawValue
        self.missingEpisodes = 0
        self.addedWatches = 0
    }

    var entryStatus: ImportEntryStatus { ImportEntryStatus(rawValue: status) ?? .pending }
    var titleKind: TitleKind { TitleKind(rawValue: kind) ?? .movie }

    var watchList: [ImportWatch] {
        (try? JSONDecoder().decode([ImportWatch].self, from: Data(watches.utf8))) ?? []
    }

    var candidateList: [TMDBSearchResult] {
        guard let candidates else { return [] }
        return (try? JSONDecoder().decode([TMDBSearchResult].self, from: Data(candidates.utf8))) ?? []
    }

    func setCandidates(_ results: [TMDBSearchResult]) {
        candidates = results.isEmpty ? nil : Self.encode(results)
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

struct CreateImportEntry: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ImportEntry.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("position", .int, .required)
            .field("kind", .string, .required)
            .field("title", .string, .required)
            .field("year", .int)
            .field("tmdb_hint", .int)
            .field("imdb_id", .string)
            .field("watches", .string, .required)
            .field("rating", .int)
            .field("comment", .string)
            .field("status", .string, .required)
            .field("tmdb_id", .int)
            .field("candidates", .string)
            .field("missing_episodes", .int, .required)
            .field("added_watches", .int, .required)
            .field("error", .string)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ImportEntry.schema).delete()
    }
}

struct ImportUploadSummary: Sendable, Equatable {
    let titles: Int
    let skippedRows: Int
}

/// The user's standard import list: upload, retry, skip, lookup.
struct ImportEntryService {
    let db: any Database

    static let noHeaderMessage =
        "Kein Standard-Import erkannt – erwartet wird eine CSV mit einer Kopfzeile, die „type“ und „title“ enthält."
    static let emptyMessage = "Die Datei enthält keine Titel."

    /// A new upload replaces the user's earlier entries (watches already recorded stay).
    func replace(userID: UUID, drafts: [ImportDraft]) async throws {
        try await db.transaction { db in
            try await ImportEntry.query(on: db).filter(\.$user.$id == userID).delete()
            for (index, draft) in drafts.enumerated() {
                try await ImportEntry(userID: userID, position: index, draft: draft).save(on: db)
            }
        }
    }

    /// Parses an uploaded file and replaces the user's earlier entries.
    func upload(userID: UUID, text: String) async throws -> ImportUploadSummary {
        let file: StandardImportFile
        do {
            file = try parseStandardImport(text)
        } catch {
            throw APIError.validation(Self.noHeaderMessage)
        }
        let drafts = groupStandardImport(file.rows)
        guard !drafts.isEmpty else { throw APIError.validation(Self.emptyMessage) }
        try await replace(userID: userID, drafts: drafts)
        return ImportUploadSummary(titles: drafts.count, skippedRows: file.skippedRows)
    }

    /// Clears the errors of entries still waiting for TMDB so the worker tries them again.
    func retry(userID: UUID) async throws {
        for entry in try await entries(userID: userID) where entry.entryStatus == .pending && entry.error != nil {
            entry.error = nil
            try await entry.save(on: db)
        }
    }

    func skip(userID: UUID, id: UUID) async throws -> ImportEntry {
        let entry = try await ownEntry(userID: userID, id: id)
        entry.status = ImportEntryStatus.skipped.rawValue
        try await entry.save(on: db)
        return entry
    }

    func entries(userID: UUID) async throws -> [ImportEntry] {
        try await ImportEntry.query(on: db).filter(\.$user.$id == userID).sort(\.$position).all()
    }

    func ownEntry(userID: UUID, id: UUID) async throws -> ImportEntry {
        guard let entry = try await ImportEntry.find(id, on: db), entry.$user.id == userID else { throw TrackingError.notFound }
        return entry
    }
}
