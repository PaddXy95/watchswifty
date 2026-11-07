import Fluent
import Foundation

enum FilmListStatus: String, Codable, Sendable {
    case pending, imported, review
    case notFound = "not_found"
    case skipped
}

/// One film of an uploaded personal film list, waiting for (or done with) its TMDB match.
final class FilmListEntry: Model, @unchecked Sendable {
    static let schema = "film_list_entries"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "position") var position: Int
    @Field(key: "title") var title: String
    @OptionalField(key: "year") var year: Int?
    /// JSON `[FilmWatch]`.
    @Field(key: "watches") var watches: String
    @OptionalField(key: "rating") var rating: Int?
    @OptionalField(key: "comment") var comment: String?
    @Field(key: "status") var status: String
    @OptionalField(key: "tmdb_id") var tmdbID: Int?
    /// JSON `[TMDBSearchResult]` for review.
    @OptionalField(key: "candidates") var candidates: String?
    @OptionalField(key: "error") var error: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userID: UUID, position: Int, draft: FilmListDraft) {
        self.$user.id = userID
        self.position = position
        self.title = draft.title
        self.year = draft.year
        self.watches = Self.encode(draft.watches) ?? "[]"
        self.rating = draft.rating
        self.comment = draft.comment
        self.status = FilmListStatus.pending.rawValue
    }

    var filmStatus: FilmListStatus { FilmListStatus(rawValue: status) ?? .pending }

    var watchList: [FilmWatch] {
        (try? JSONDecoder().decode([FilmWatch].self, from: Data(watches.utf8))) ?? []
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

struct CreateFilmListEntry: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(FilmListEntry.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("position", .int, .required)
            .field("title", .string, .required)
            .field("year", .int)
            .field("watches", .string, .required)
            .field("rating", .int)
            .field("comment", .string)
            .field("status", .string, .required)
            .field("tmdb_id", .int)
            .field("candidates", .string)
            .field("error", .string)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(FilmListEntry.schema).delete()
    }
}

struct FilmListService {
    let db: any Database

    /// A new upload replaces the user's earlier list (watches already recorded stay).
    func replace(userID: UUID, drafts: [FilmListDraft]) async throws {
        try await db.transaction { db in
            try await FilmListEntry.query(on: db).filter(\.$user.$id == userID).delete()
            for (index, draft) in drafts.enumerated() {
                try await FilmListEntry(userID: userID, position: index, draft: draft).save(on: db)
            }
        }
    }

    func entries(userID: UUID) async throws -> [FilmListEntry] {
        try await FilmListEntry.query(on: db).filter(\.$user.$id == userID).sort(\.$position).all()
    }

    func ownEntry(userID: UUID, id: UUID) async throws -> FilmListEntry {
        guard let entry = try await FilmListEntry.find(id, on: db), entry.$user.id == userID else { throw TrackingError.notFound }
        return entry
    }
}
