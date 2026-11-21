import Fluent
import SQLKit

/// Creates the `watch_later` table of „Später ansehen“ (watch later) entries, unique per user and title.
struct CreateWatchLater: AsyncMigration {
    /// Creates the `watch_later` table.
    func prepare(on database: any Database) async throws {
        try await database.schema(WatchLaterEntry.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("title_id", .uuid, .required, .references(Title.schema, .id, onDelete: .cascade))
            .field("added_at", .datetime, .required)
            .field("added_on", .string, .required)
            .field("baselined", .bool, .required)
            .unique(on: "user_id", "title_id")
            .create()
    }

    /// Drops the `watch_later` table.
    func revert(on database: any Database) async throws {
        try await database.schema(WatchLaterEntry.schema).delete()
    }
}

/// Creates `title_availability` (fetch state per title) and `title_providers` (offers per title and country, indexed by
/// title and region).
struct CreateTitleAvailability: AsyncMigration {
    /// Creates both tables and, on SQL databases, the `title_providers_title_region` index.
    func prepare(on database: any Database) async throws {
        try await database.schema(TitleAvailability.schema)
            .id()
            .field("title_id", .uuid, .required, .references(Title.schema, .id, onDelete: .cascade))
            .field("fetched_at", .datetime, .required)
            .field("regions", .string, .required)
            .field("tmdb_link", .string)
            .unique(on: "title_id")
            .create()
        try await database.schema(TitleProvider.schema)
            .id()
            .field("title_id", .uuid, .required, .references(Title.schema, .id, onDelete: .cascade))
            .field("region", .string, .required)
            .field("provider_id", .int, .required)
            .field("provider_name", .string, .required)
            .field("logo_path", .string)
            .field("kind", .string, .required)
            .field("display_priority", .int, .required)
            .create()
        if let sql = database as? any SQLDatabase {
            try await sql.raw("CREATE INDEX IF NOT EXISTS title_providers_title_region ON title_providers (title_id, region)").run()
        }
    }

    /// Drops `title_providers` and `title_availability`.
    func revert(on database: any Database) async throws {
        try await database.schema(TitleProvider.schema).delete()
        try await database.schema(TitleAvailability.schema).delete()
    }
}

/// Creates `user_streaming_services` and adds the `watch_region` and `notify_available` columns to `users`.
struct CreateStreamingServices: AsyncMigration {
    /// Creates the table and adds the user columns.
    func prepare(on database: any Database) async throws {
        try await database.schema(UserStreamingService.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("provider_id", .int, .required)
            .unique(on: "user_id", "provider_id")
            .create()
        try await database.schema(User.schema).field("watch_region", .string).update()
        try await database.schema(User.schema).field("notify_available", .bool).update()
    }

    /// Removes the user columns and drops `user_streaming_services`.
    func revert(on database: any Database) async throws {
        try await database.schema(User.schema).deleteField("notify_available").update()
        try await database.schema(User.schema).deleteField("watch_region").update()
        try await database.schema(UserStreamingService.schema).delete()
    }
}

/// Creates the `availability_notices` table of known offers, unique per user, title and provider.
struct CreateAvailabilityNotice: AsyncMigration {
    /// Creates the `availability_notices` table.
    func prepare(on database: any Database) async throws {
        try await database.schema(AvailabilityNotice.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, .id, onDelete: .cascade))
            .field("title_id", .uuid, .required, .references(Title.schema, .id, onDelete: .cascade))
            .field("provider_id", .int, .required)
            .field("noticed_at", .datetime, .required)
            .field("state", .string, .required)
            .unique(on: "user_id", "title_id", "provider_id")
            .create()
    }

    /// Drops the `availability_notices` table.
    func revert(on database: any Database) async throws {
        try await database.schema(AvailabilityNotice.schema).delete()
    }
}
