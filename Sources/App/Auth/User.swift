import Fluent
import Foundation
import Vapor

final class User: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id) var id: UUID?
    @Field(key: "username") var username: String
    @Field(key: "password_hash") var passwordHash: String
    @Field(key: "is_admin") var isAdmin: Bool
    /// The user's own TMDB read access token (secret; never rendered or logged).
    @OptionalField(key: "tmdb_token") var tmdbToken: String?
    /// The user's own e-mail address, sealed with the server key (admins only ever see a mask).
    @OptionalField(key: "email") var email: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(id: UUID? = nil, username: String, passwordHash: String, isAdmin: Bool) {
        self.id = id
        self.username = username
        self.passwordHash = passwordHash
        self.isAdmin = isAdmin
    }

    /// Stored for accounts without a password (pending invitation); never matches any password.
    static let noPasswordHash = "!"

    var hasPassword: Bool { passwordHash != Self.noPasswordHash }

    /// Usernames are stored trimmed and lowercased; login is case-insensitive.
    static func normalize(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

extension User: ModelSessionAuthenticatable {}

enum EmailState: Equatable, Sendable {
    case none
    /// Stored, but the server key cannot decrypt it (TOKEN_KEY changed).
    case unreadable
    case address(String)

    var address: String? {
        if case .address(let address) = self { return address }
        return nil
    }
}

extension User {
    func emailState(_ cipher: TokenCipher) -> EmailState {
        guard let stored = email, !stored.isEmpty else { return .none }
        return cipher.open(stored).map(EmailState.address) ?? .unreadable
    }
}

struct AddUserEmail: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema).field("email", .string).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema).deleteField("email").update()
    }
}

extension Request {
    var currentUser: User {
        get throws { try auth.require(User.self) }
    }

    var userID: UUID {
        get throws { try currentUser.requireID() }
    }
}

extension Request {
    func nav(_ item: NavItem) throws -> NavContext {
        let user = try currentUser
        return NavContext(username: user.username, isAdmin: user.isAdmin, active: item,
                          updateVersion: user.isAdmin ? application.updateStatus.newerVersion : nil)
    }
}
