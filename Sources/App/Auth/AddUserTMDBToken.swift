import Fluent

/// Adds `users.tmdb_token` (the user's own TMDB read access token, sealed with `TokenCipher`).
struct AddUserTMDBToken: AsyncMigration {
    /// Adds the column.
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema).field("tmdb_token", .string).update()
    }

    /// Removes the column.
    func revert(on database: any Database) async throws {
        try await database.schema(User.schema).deleteField("tmdb_token").update()
    }
}
