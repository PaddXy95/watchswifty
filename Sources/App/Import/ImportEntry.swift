import Fluent
import Foundation

/// State of a standard import entry (`import_entries.status`).
///
/// - `pending`: waiting for the `ImportWorker` (an `error` means the last attempt failed).
/// - `imported`: recorded for `tmdbID`.
/// - `review`: unclear; the user picks from the candidates.
enum ImportEntryStatus: String, Codable, Sendable {
    case pending, imported, review
    /// TMDB found nothing; the user can search with their own words.
    case notFound = "not_found"
    /// The user skipped the entry.
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

    /// Creates an empty model for Fluent.
    init() {}

    /// Creates a pending entry from a parsed title.
    /// - Parameters:
    ///   - userID: The owner.
    ///   - position: The title's order in the file.
    ///   - draft: The grouped title with its viewings.
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

    /// The typed `status`; unknown values read as `pending`.
    var entryStatus: ImportEntryStatus { ImportEntryStatus(rawValue: status) ?? .pending }
    /// The typed `kind`; unknown values read as `.movie`.
    var titleKind: TitleKind { TitleKind(rawValue: kind) ?? .movie }

    /// The decoded viewings (empty when undecodable).
    var watchList: [ImportWatch] {
        (try? JSONDecoder().decode([ImportWatch].self, from: Data(watches.utf8))) ?? []
    }

    /// The decoded review candidates (empty when none or undecodable).
    var candidateList: [TMDBSearchResult] {
        guard let candidates else { return [] }
        return (try? JSONDecoder().decode([TMDBSearchResult].self, from: Data(candidates.utf8))) ?? []
    }

    /// Stores the review candidates (an empty list clears them).
    /// - Parameter results: The candidates to store.
    func setCandidates(_ results: [TMDBSearchResult]) {
        candidates = results.isEmpty ? nil : Self.encode(results)
    }

    /// JSON-encodes a value as a UTF-8 string.
    /// - Parameter value: The value to encode.
    /// - Returns: The JSON text, or nil when encoding fails.
    private static func encode<T: Encodable>(_ value: T) -> String? {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// Creates the `import_entries` table of the standard import.
struct CreateImportEntry: AsyncMigration {
    /// Creates the table.
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

    /// Drops the table.
    func revert(on database: any Database) async throws {
        try await database.schema(ImportEntry.schema).delete()
    }
}

/// Result of a standard import upload.
struct ImportUploadSummary: Sendable, Equatable {
    /// Titles (entries) created.
    let titles: Int
    /// Lines skipped for an unknown type, a missing title or missing season/episode.
    let skippedRows: Int
}

/// The user's standard import list: upload, retry, skip, lookup.
struct ImportEntryService {
    /// Titles one upload may hold; far above a real history, but it bounds what the page and the worker handle per
    /// user (like `ImportService.maxStoredRows` for Netflix).
    static let maxTitles = 20_000

    let db: any Database
    var maxTitles = ImportEntryService.maxTitles

    /// Error for a file without a recognizable header.
    static let noHeaderMessage =
        "Kein Standard-Import erkannt – erwartet wird eine CSV mit einer Kopfzeile, die „type“ und „title“ enthält."
    /// Error for a file without any usable title.
    static let emptyMessage = "Die Datei enthält keine Titel."

    /// Error for a file with more titles than allowed.
    /// - Parameter limit: The maximum number of titles.
    /// - Returns: The German message.
    static func tooManyTitlesMessage(limit: Int) -> String {
        "Die Datei enthält mehr als \(limit.formatted(.number.locale(Locale(identifier: "de_DE")))) Titel – bitte in mehrere Dateien aufteilen."
    }

    /// A new upload replaces the user's earlier entries (watches already recorded stay).
    ///
    /// - Parameters:
    ///   - userID: The owner.
    ///   - drafts: The new titles, in file order.
    /// - Throws: A database error (the replacement is one transaction).
    func replace(userID: UUID, drafts: [ImportDraft]) async throws {
        try await db.transaction { db in
            try await ImportEntry.query(on: db).filter(\.$user.$id == userID).delete()
            for (index, draft) in drafts.enumerated() {
                try await ImportEntry(userID: userID, position: index, draft: draft).save(on: db)
            }
        }
    }

    /// Parses an uploaded file and replaces the user's earlier entries.
    ///
    /// - Parameters:
    ///   - userID: The uploading user.
    ///   - text: The decoded file content.
    /// - Returns: How many titles were taken over and how many lines were skipped.
    /// - Throws: `APIError.validation` with `noHeaderMessage`, `emptyMessage` or `tooManyTitlesMessage(limit:)`, or a
    ///   database error.
    func upload(userID: UUID, text: String) async throws -> ImportUploadSummary {
        let file: StandardImportFile
        do {
            file = try parseStandardImport(text)
        } catch {
            throw APIError.validation(Self.noHeaderMessage)
        }
        let drafts = groupStandardImport(file.rows)
        guard !drafts.isEmpty else { throw APIError.validation(Self.emptyMessage) }
        guard drafts.count <= maxTitles else { throw APIError.validation(Self.tooManyTitlesMessage(limit: maxTitles)) }
        try await replace(userID: userID, drafts: drafts)
        return ImportUploadSummary(titles: drafts.count, skippedRows: file.skippedRows)
    }

    /// Clears the errors of entries still waiting for TMDB so the worker tries them again.
    ///
    /// - Parameter userID: The owner of the entries.
    /// - Throws: A database error.
    func retry(userID: UUID) async throws {
        for entry in try await entries(userID: userID) where entry.entryStatus == .pending && entry.error != nil {
            entry.error = nil
            try await entry.save(on: db)
        }
    }

    /// Marks one of the user's entries as skipped.
    /// - Parameters:
    ///   - userID: The logged-in user.
    ///   - id: The entry.
    /// - Returns: The updated entry.
    /// - Throws: `TrackingError.notFound` for a foreign or unknown entry.
    func skip(userID: UUID, id: UUID) async throws -> ImportEntry {
        let entry = try await ownEntry(userID: userID, id: id)
        entry.status = ImportEntryStatus.skipped.rawValue
        try await entry.save(on: db)
        return entry
    }

    /// The user's entries in file order.
    /// - Parameter userID: The owner.
    /// - Returns: All entries of the user's current upload.
    /// - Throws: A database error.
    func entries(userID: UUID) async throws -> [ImportEntry] {
        try await ImportEntry.query(on: db).filter(\.$user.$id == userID).sort(\.$position).all()
    }

    /// Loads an entry through its owner.
    /// - Parameters:
    ///   - userID: The logged-in user.
    ///   - id: The entry.
    /// - Returns: The user's entry.
    /// - Throws: `TrackingError.notFound` when it does not exist or belongs to someone else.
    func ownEntry(userID: UUID, id: UUID) async throws -> ImportEntry {
        guard let entry = try await ImportEntry.find(id, on: db), entry.$user.id == userID else { throw TrackingError.notFound }
        return entry
    }
}
