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
