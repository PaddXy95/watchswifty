import Fluent

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
