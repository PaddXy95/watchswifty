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
    /// OpenID Connect identity: the provider's issuer (as its discovery states it) and the subject.
    @OptionalField(key: "oidc_issuer") var oidcIssuer: String?
    @OptionalField(key: "oidc_subject") var oidcSubject: String?
    /// Preferred way for notifications (`NotifyChannel`); nil = mail.
    @OptionalField(key: "notify_channel") var notifyChannel: String?
    /// Notices for followed series: newly announced episode, 1–3 days before, on the air date (nil = off).
    @OptionalField(key: "notify_announced") var notifyAnnounced: Bool?
    @OptionalField(key: "notify_soon") var notifySoon: Bool?
    @OptionalField(key: "notify_today") var notifyToday: Bool?
    /// When „neu angekündigt“ was last switched on: only episodes first seen later count.
    @OptionalField(key: "notify_announced_since") var notifyAnnouncedSince: Date?
    /// The user's KNot API key, sealed with the server key (never rendered or logged).
    @OptionalField(key: "webhook_key") var webhookKey: String?
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

extension User {
    /// Linked with the configured provider; a link to another (old) issuer does not count, nor does any link while
    /// OIDC is not configured.
    func isLinked(_ oidc: OIDCConfig?) -> Bool {
        guard let oidc, let subject = oidcSubject, !subject.isEmpty else { return false }
        return oidc.matchesIssuer(oidcIssuer)
    }

    /// Linked and without a usable password login: such accounts go through the provider when connecting an app.
    func isSSOAccount(_ oidc: OIDCConfig?, passwordLogin: Bool) -> Bool {
        isLinked(oidc) && !(hasPassword && passwordLogin)
    }

    /// Linked accounts without password take their address from the provider (they never get reset mails).
    func emailFromProvider(_ oidc: OIDCConfig?) -> Bool {
        isLinked(oidc) && !hasPassword
    }
}

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
