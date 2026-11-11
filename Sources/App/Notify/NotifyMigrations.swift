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
