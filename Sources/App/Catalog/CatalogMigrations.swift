import Fluent

struct CreateTitle: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Title.schema)
            .id()
            .field("tmdb_id", .int, .required)
            .field("kind", .string, .required)
            .field("name", .string, .required)
            .field("original_name", .string)
            .field("year", .int)
            .field("poster_path", .string)
            .field("tmdb_status", .string)
            .field("refreshed_at", .datetime)
            .unique(on: "kind", "tmdb_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Title.schema).delete()
    }
}

struct CreateEpisode: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Episode.schema)
            .id()
            .field("title_id", .uuid, .required, .references(Title.schema, .id, onDelete: .cascade))
            .field("season_number", .int, .required)
            .field("episode_number", .int, .required)
            .field("name", .string, .required)
            .field("air_date", .string)
            .field("tmdb_episode_id", .int, .required)
            .unique(on: "title_id", "season_number", "episode_number")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Episode.schema).delete()
    }
}

/// Overview and IMDb id for detail pages (UI round 1, tasks 10–11).
struct AddTitleDetails: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Title.schema).field("overview", .string).update()
        try await database.schema(Title.schema).field("imdb_id", .string).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Title.schema).deleteField("imdb_id").update()
        try await database.schema(Title.schema).deleteField("overview").update()
    }
}

struct AddEpisodeOverview: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Episode.schema).field("overview", .string).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Episode.schema).deleteField("overview").update()
    }
}
