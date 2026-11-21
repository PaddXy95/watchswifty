import Fluent
import SQLKit

/// Creates the `user_titles` table (one library entry per user and title, with rating and hidden flag).
struct CreateUserTitle: AsyncMigration {
    /// Creates the table with a unique (user, title) constraint; rows are deleted with their user or title.
    func prepare(on database: any Database) async throws {
        try await database.schema(UserTitle.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("title_id", .uuid, .required, .references(Title.schema, .id, onDelete: .cascade))
            .field("rating", .int)
            .field("hidden", .bool, .required)
            .unique(on: "user_id", "title_id")
            .create()
    }

    /// Drops the `user_titles` table.
    func revert(on database: any Database) async throws {
        try await database.schema(UserTitle.schema).delete()
    }
}

/// Creates the `watches` table (one row per viewing of an episode or movie).
struct CreateWatch: AsyncMigration {
    /// Creates the table; rows are deleted with their user, title or episode.
    func prepare(on database: any Database) async throws {
        try await database.schema(Watch.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("title_id", .uuid, .required, .references(Title.schema, .id, onDelete: .cascade))
            .field("episode_id", .uuid, .references(Episode.schema, .id, onDelete: .cascade))
            .field("watched_on", .string)
            .field("service", .string)
            .field("origin", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    /// Drops the `watches` table.
    func revert(on database: any Database) async throws {
        try await database.schema(Watch.schema).delete()
    }
}

/// Adds the private title comment (`user_titles.comment`).
struct AddUserTitleComment: AsyncMigration {
    /// Adds the `comment` column.
    func prepare(on database: any Database) async throws {
        try await database.schema(UserTitle.schema).field("comment", .string).update()
    }

    /// Removes the `comment` column.
    func revert(on database: any Database) async throws {
        try await database.schema(UserTitle.schema).deleteField("comment").update()
    }
}

/// Creates the `season_notes` table (one private comment per user, series and season).
struct CreateSeasonNote: AsyncMigration {
    /// Creates the table with a unique (user, title, season) constraint; rows are deleted with their user or title.
    func prepare(on database: any Database) async throws {
        try await database.schema(SeasonNote.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("title_id", .uuid, .required, .references(Title.schema, .id, onDelete: .cascade))
            .field("season_number", .int, .required)
            .field("comment", .string, .required)
            .unique(on: "user_id", "title_id", "season_number")
            .create()
    }

    /// Drops the `season_notes` table.
    func revert(on database: any Database) async throws {
        try await database.schema(SeasonNote.schema).delete()
    }
}

/// Adds the „Beobachten“ (follow) fields `followed`, `followed_on` and `new_seen_until` to `user_titles`.
struct AddFollowFields: AsyncMigration {
    /// Adds the three columns.
    func prepare(on database: any Database) async throws {
        try await database.schema(UserTitle.schema).field("followed", .bool).update()
        try await database.schema(UserTitle.schema).field("followed_on", .string).update()
        try await database.schema(UserTitle.schema).field("new_seen_until", .string).update()
    }

    /// Removes the three columns.
    func revert(on database: any Database) async throws {
        try await database.schema(UserTitle.schema).deleteField("new_seen_until").update()
        try await database.schema(UserTitle.schema).deleteField("followed_on").update()
        try await database.schema(UserTitle.schema).deleteField("followed").update()
    }
}

/// Adds the exact follow time `user_titles.followed_at`.
struct AddFollowedAt: AsyncMigration {
    /// Adds the `followed_at` column.
    func prepare(on database: any Database) async throws {
        try await database.schema(UserTitle.schema).field("followed_at", .datetime).update()
    }

    /// Removes the `followed_at` column.
    func revert(on database: any Database) async throws {
        try await database.schema(UserTitle.schema).deleteField("followed_at").update()
    }
}

/// Every page reads watches by user (and often by title); without an index each query scanned the watches of all users.
struct AddWatchUserIndex: AsyncMigration {
    /// Creates the `watches_user_title` index on (`user_id`, `title_id`); does nothing on non-SQL databases.
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("CREATE INDEX IF NOT EXISTS watches_user_title ON watches (user_id, title_id)").run()
    }

    /// Drops the `watches_user_title` index; does nothing on non-SQL databases.
    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS watches_user_title").run()
    }
}
