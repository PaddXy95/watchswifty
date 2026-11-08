import Foundation
import Fluent

struct CreateNetflixImport: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(NetflixImport.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("uploaded_at", .datetime)
            .field("filename", .string, .required)
            .field("total_rows", .int, .required)
            .field("new_rows", .int, .required)
            .field("known_rows", .int, .required)
            .field("skipped_rows", .int, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(NetflixImport.schema).delete()
    }
}

/// Age of the stored candidate lists (TMDB terms, UI round task 30); existing lists count from now.
struct AddMappingCandidatesAt: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(NetflixMapping.schema).field("candidates_at", .datetime).update()
        try await NetflixMapping.query(on: database).filter(\.$candidates != nil).set(\.$candidatesAt, to: Date()).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(NetflixMapping.schema).deleteField("candidates_at").update()
    }
}

struct CreateNetflixMapping: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(NetflixMapping.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("netflix_name", .string, .required)
            .field("kind", .string, .required)
            .field("title_id", .uuid, .references(Title.schema, .id, onDelete: .setNull))
            .field("status", .string, .required)
            .field("candidates", .string)
            .unique(on: "user_id", "netflix_name", "kind")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(NetflixMapping.schema).delete()
    }
}

struct CreateNetflixRow: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(NetflixRow.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("import_id", .uuid, .required, .references(NetflixImport.schema, .id, onDelete: .cascade))
            .field("raw_title", .string, .required)
            .field("watched_on", .string, .required)
            .field("fingerprint", .string, .required)
            .field("parsed_kind", .string, .required)
            .field("show_name", .string)
            .field("season_number", .int)
            .field("episode_title", .string)
            .field("status", .string, .required)
            .field("mapping_id", .uuid, .references(NetflixMapping.schema, .id, onDelete: .setNull))
            .field("watch_id", .uuid, .references(Watch.schema, .id, onDelete: .setNull))
            .unique(on: "user_id", "fingerprint")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(NetflixRow.schema).delete()
    }
}
