import Fluent

/// History of the removed personal film list import (replaced by the standard import, spec
/// `2026-11-19-standard-import-design.md`): the table was created by `CreateFilmListEntry` and is dropped again by
/// `DropFilmListEntries`. Names are written out because the model is gone.
private let filmListSchema = "film_list_entries"

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

struct CreateFilmListEntry: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await createFilmListTable(on: database)
    }

    func revert(on database: any Database) async throws {
        try await database.schema(filmListSchema).delete()
    }
}

struct DropFilmListEntries: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(filmListSchema).delete()
    }

    func revert(on database: any Database) async throws {
        try await createFilmListTable(on: database)
    }
}
