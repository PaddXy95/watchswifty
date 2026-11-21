import Fluent

/// History of the removed personal film list import (replaced by the standard import, spec
/// `2026-11-19-standard-import-design.md`): the table was created by `CreateFilmListEntry` and is dropped again by
/// `DropFilmListEntries`. Names are written out because the model is gone.
private let filmListSchema = "film_list_entries"

/// Creates the `film_list_entries` table as it was.
/// - Parameter database: The database.
/// - Throws: A database error.
private func createFilmListTable(on database: any Database) async throws {
    try await database.schema(filmListSchema)
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

/// Historical migration that created the film list table of the removed film list import.
struct CreateFilmListEntry: AsyncMigration {
    /// Creates the table.
    func prepare(on database: any Database) async throws {
        try await createFilmListTable(on: database)
    }

    /// Drops the table.
    func revert(on database: any Database) async throws {
        try await database.schema(filmListSchema).delete()
    }
}

/// Drops the film list table of the removed film list import.
struct DropFilmListEntries: AsyncMigration {
    /// Drops the table.
    func prepare(on database: any Database) async throws {
        try await database.schema(filmListSchema).delete()
    }

    /// Recreates the table.
    func revert(on database: any Database) async throws {
        try await createFilmListTable(on: database)
    }
}
