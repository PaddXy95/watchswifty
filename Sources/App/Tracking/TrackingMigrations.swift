import Fluent
import SQLKit

struct CreateUserTitle: AsyncMigration {
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

    func revert(on database: any Database) async throws {
        try await database.schema(UserTitle.schema).delete()
    }
}

struct CreateWatch: AsyncMigration {
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

    func revert(on database: any Database) async throws {
        try await database.schema(Watch.schema).delete()
    }
}

struct AddUserTitleComment: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserTitle.schema).field("comment", .string).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserTitle.schema).deleteField("comment").update()
    }
}

struct CreateSeasonNote: AsyncMigration {
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

    func revert(on database: any Database) async throws {
        try await database.schema(SeasonNote.schema).delete()
    }
}

struct AddFollowFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserTitle.schema).field("followed", .bool).update()
        try await database.schema(UserTitle.schema).field("followed_on", .string).update()
        try await database.schema(UserTitle.schema).field("new_seen_until", .string).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserTitle.schema).deleteField("new_seen_until").update()
        try await database.schema(UserTitle.schema).deleteField("followed_on").update()
        try await database.schema(UserTitle.schema).deleteField("followed").update()
    }
}

struct AddFollowedAt: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserTitle.schema).field("followed_at", .datetime).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserTitle.schema).deleteField("followed_at").update()
    }
}

/// Every page reads watches by user (and often by title); without an index each query scanned the watches of all users.
struct AddWatchUserIndex: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("CREATE INDEX IF NOT EXISTS watches_user_title ON watches (user_id, title_id)").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS watches_user_title").run()
    }
}
