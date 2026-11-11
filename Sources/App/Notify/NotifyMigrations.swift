import Fluent

/// `app_settings`: time of the daily pass, its last start, the KNot webhook address.
struct AddNotificationSettings: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AppSettings.schema).field("daily_run_time", .string).update()
        try await database.schema(AppSettings.schema).field("daily_run_at", .datetime).update()
        try await database.schema(AppSettings.schema).field("webhook_url", .string).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(AppSettings.schema).deleteField("webhook_url").update()
        try await database.schema(AppSettings.schema).deleteField("daily_run_at").update()
        try await database.schema(AppSettings.schema).deleteField("daily_run_time").update()
    }
}

/// `users`: notification toggles, preferred channel, sealed KNot key.
struct AddNotificationPrefs: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema).field("notify_channel", .string).update()
        try await database.schema(User.schema).field("notify_announced", .bool).update()
        try await database.schema(User.schema).field("notify_soon", .bool).update()
        try await database.schema(User.schema).field("notify_today", .bool).update()
        try await database.schema(User.schema).field("notify_announced_since", .datetime).update()
        try await database.schema(User.schema).field("webhook_key", .string).update()
    }

    func revert(on database: any Database) async throws {
        for field in ["webhook_key", "notify_announced_since", "notify_today", "notify_soon", "notify_announced", "notify_channel"] {
            try await database.schema(User.schema).deleteField(.key(.init(stringLiteral: field))).update()
        }
    }
}
