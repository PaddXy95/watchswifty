import Fluent
import SQLKit

/// Creates the `titles` table, the shared TMDB cache of series and movies (unique per kind and TMDB id).
struct CreateTitle: AsyncMigration {
    /// Creates the `titles` table.
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

    /// Drops the `titles` table.
    func revert(on database: any Database) async throws {
        try await database.schema(Title.schema).delete()
    }
}

/// Creates the `episodes` table, the shared TMDB cache of series episodes (unique per title, season and number;
/// deleted with their title).
struct CreateEpisode: AsyncMigration {
    /// Creates the `episodes` table.
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

    /// Drops the `episodes` table.
    func revert(on database: any Database) async throws {
        try await database.schema(Episode.schema).delete()
    }
}

/// Overview and IMDb id for detail pages (UI round 1, tasks 10–11).
struct AddTitleDetails: AsyncMigration {
    /// Adds the `overview` and `imdb_id` columns to `titles`.
    func prepare(on database: any Database) async throws {
        try await database.schema(Title.schema).field("overview", .string).update()
        try await database.schema(Title.schema).field("imdb_id", .string).update()
    }

    /// Removes the `imdb_id` and `overview` columns from `titles`.
    func revert(on database: any Database) async throws {
        try await database.schema(Title.schema).deleteField("imdb_id").update()
        try await database.schema(Title.schema).deleteField("overview").update()
    }
}

/// Runtimes for the statistics (UI round, task 21).
struct AddRuntimes: AsyncMigration {
    /// Adds the `runtime` column to `titles` and `episodes`.
    func prepare(on database: any Database) async throws {
        try await database.schema(Title.schema).field("runtime", .int).update()
        try await database.schema(Episode.schema).field("runtime", .int).update()
    }

    /// Removes the `runtime` column from `episodes` and `titles`.
    func revert(on database: any Database) async throws {
        try await database.schema(Episode.schema).deleteField("runtime").update()
        try await database.schema(Title.schema).deleteField("runtime").update()
    }
}

/// Adds the TMDB overview of an episode.
struct AddEpisodeOverview: AsyncMigration {
    /// Adds the `overview` column to `episodes`.
    func prepare(on database: any Database) async throws {
        try await database.schema(Episode.schema).field("overview", .string).update()
    }

    /// Removes the `overview` column from `episodes`.
    func revert(on database: any Database) async throws {
        try await database.schema(Episode.schema).deleteField("overview").update()
    }
}

/// First/last time a refresh returned an episode; existing rows count as seen at their title's last refresh.
struct AddEpisodeSeenTimes: AsyncMigration {
    /// Adds `first_seen_at` and `last_seen_at` to `episodes` and, on SQL databases, sets `last_seen_at` of existing rows to
    /// their title's `refreshed_at`.
    func prepare(on database: any Database) async throws {
        try await database.schema(Episode.schema).field("first_seen_at", .datetime).update()
        try await database.schema(Episode.schema).field("last_seen_at", .datetime).update()
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("UPDATE episodes SET last_seen_at = (SELECT refreshed_at FROM titles WHERE titles.id = episodes.title_id)").run()
    }

    /// Removes the `last_seen_at` and `first_seen_at` columns from `episodes`.
    func revert(on database: any Database) async throws {
        try await database.schema(Episode.schema).deleteField("last_seen_at").update()
        try await database.schema(Episode.schema).deleteField("first_seen_at").update()
    }
}

/// Genres of a title (spec `2026-11-13-feedback-round-design.md` §7); nil until the next refresh.
struct AddTitleGenres: AsyncMigration {
    /// Adds the `genres` column to `titles`.
    func prepare(on database: any Database) async throws {
        try await database.schema(Title.schema).field("genres", .string).update()
    }

    /// Removes the `genres` column from `titles`.
    func revert(on database: any Database) async throws {
        try await database.schema(Title.schema).deleteField("genres").update()
    }
}
