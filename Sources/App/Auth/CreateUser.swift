import Fluent

/// Creates the `users` table (unique username, password hash, admin flag, creation time).
struct CreateUser: AsyncMigration {
    /// Creates the table.
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .id()
            .field("username", .string, .required)
            .field("password_hash", .string, .required)
            .field("is_admin", .bool, .required)
            .field("created_at", .datetime)
            .unique(on: "username")
            .create()
    }

    /// Drops the table.
    func revert(on database: any Database) async throws {
        try await database.schema(User.schema).delete()
    }
}
