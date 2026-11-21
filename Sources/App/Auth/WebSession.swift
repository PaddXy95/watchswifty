import Fluent
import Foundation
import Vapor

/// A web session. Only the SHA-256 of the cookie value is stored, like API and password tokens, so a copy of the
/// database holds no usable session ID; a session unused for 30 days ends (security audit F08/F18).
final class WebSession: Model, @unchecked Sendable {
    static let schema = "web_sessions"
    /// Same as the cookie's lifetime: every use extends a session by this much (docs/accounts.md).
    static let idleLifetime: TimeInterval = 2_592_000

    @ID(key: .id) var id: UUID?
    @Field(key: "key_hash") var keyHash: String
    @Field(key: "data") var data: SessionData
    @Field(key: "last_used_at") var lastUsedAt: Date

    /// Creates an empty model for Fluent.
    init() {}

    /// Creates a session row.
    /// - Parameters:
    ///   - keyHash: The SHA-256 hex digest of the cookie value.
    ///   - data: The session data.
    ///   - lastUsedAt: The time of the last use.
    init(keyHash: String, data: SessionData, lastUsedAt: Date) {
        self.keyHash = keyHash
        self.data = data
        self.lastUsedAt = lastUsedAt
    }

    /// Deletes sessions unused for longer than `idleLifetime`; returns how many.
    /// - Parameters:
    ///   - db: The database.
    ///   - now: The reference time.
    /// - Returns: The number of deleted sessions.
    /// - Throws: Database errors.
    static func deleteIdle(on db: any Database, now: Date = .now) async throws -> Int {
        let cutoff = now.addingTimeInterval(-idleLifetime)
        let count = try await query(on: db).filter(\.$lastUsedAt < cutoff).count()
        if count > 0 { try await query(on: db).filter(\.$lastUsedAt < cutoff).delete() }
        return count
    }
}

/// Creates `web_sessions` and ends the sessions of the stock Fluent driver, whose rows hold raw session IDs
/// (everyone signs in once more).
struct CreateWebSession: AsyncMigration {
    /// Creates the table and deletes all rows of the stock `_fluent_sessions` table.
    func prepare(on database: any Database) async throws {
        try await database.schema(WebSession.schema)
            .id()
            .field("key_hash", .string, .required)
            .field("data", .json, .required)
            .field("last_used_at", .datetime, .required)
            .unique(on: "key_hash")
            .create()
        try await SessionRecord.query(on: database).delete()
    }

    /// Drops the table.
    func revert(on database: any Database) async throws {
        try await database.schema(WebSession.schema).delete()
    }
}

/// Session storage for `SessionsMiddleware`: looks sessions up by the hash of the cookie value, ends idle ones and
/// does not store sessions without data (a request with an unknown cookie leaves no row behind).
struct HashedSessionDriver: AsyncSessionDriver {
    /// Generates a random session ID (32 bytes, Base64) and stores the data under its SHA-256 hash.
    ///
    /// Empty session data is not stored, so the returned ID then refers to no row.
    /// - Parameters:
    ///   - data: The session data.
    ///   - request: The request the session belongs to.
    /// - Returns: The new session ID (the cookie value).
    /// - Throws: Database errors.
    func createSession(_ data: SessionData, for request: Request) async throws -> SessionID {
        var generator = SystemRandomNumberGenerator()
        let id = SessionID(string: Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64EncodedString())
        guard !data.snapshot.isEmpty else { return id }
        try await WebSession(keyHash: APITokenService.hash(id.string), data: data, lastUsedAt: .now).create(on: request.db)
        return id
    }

    /// Loads the session data for a cookie value; a session idle for longer than `WebSession.idleLifetime` is deleted.
    /// - Parameters:
    ///   - sessionID: The session ID from the cookie.
    ///   - request: The current request.
    /// - Returns: The session data, or `nil` for an unknown or idle session.
    /// - Throws: Database errors.
    func readSession(_ sessionID: SessionID, for request: Request) async throws -> SessionData? {
        guard let row = try await WebSession.query(on: request.db)
            .filter(\.$keyHash == APITokenService.hash(sessionID.string)).first() else { return nil }
        guard Date().timeIntervalSince(row.lastUsedAt) <= WebSession.idleLifetime else {
            try await row.delete(on: request.db)
            return nil
        }
        return row.data
    }

    /// Called after every request with a session: stores the data and counts as use.
    /// - Parameters:
    ///   - sessionID: The session ID from the cookie.
    ///   - data: The data to store.
    ///   - request: The current request.
    /// - Returns: The unchanged session ID.
    /// - Throws: Database errors.
    func updateSession(_ sessionID: SessionID, to data: SessionData, for request: Request) async throws -> SessionID {
        try await WebSession.query(on: request.db).filter(\.$keyHash == APITokenService.hash(sessionID.string))
            .set(\.$data, to: data).set(\.$lastUsedAt, to: .now).update()
        return sessionID
    }

    /// Deletes the session row for a cookie value.
    /// - Parameters:
    ///   - sessionID: The session ID from the cookie.
    ///   - request: The current request.
    /// - Throws: Database errors.
    func deleteSession(_ sessionID: SessionID, for request: Request) async throws {
        try await WebSession.query(on: request.db).filter(\.$keyHash == APITokenService.hash(sessionID.string)).delete()
    }
}
