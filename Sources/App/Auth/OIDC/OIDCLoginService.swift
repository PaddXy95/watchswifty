import Fluent
import Foundation
import Vapor

/// Account logic of the OIDC login, shared by web, API and commands (spec „Konto bestimmen“ ff.).
struct OIDCLoginService {
    let db: any Database
    let cipher: TokenCipher
    let oidc: OIDCConfig
    let passwordLogin: Bool
    let lock: AsyncMutex

    /// The account linked with this identity (issuer compared without a trailing slash).
    func account(for identity: OIDCIdentity) async throws -> User? {
        let candidates = try await User.query(on: db).filter(\.$oidcSubject == identity.subject).all()
        return candidates.first { user in
            user.oidcIssuer.map(OIDCConfig.trimmed) == OIDCConfig.trimmed(identity.issuer)
        }
    }

    /// Creates the confirmed account (no password, linked, address from the provider). Returns the existing account
    /// when the identity got linked meanwhile (double submit). The very first user becomes admin.
    func createAccount(_ identity: OIDCIdentity, username raw: String) async throws -> User {
        let username = User.normalize(raw)
        if let error = AccountValidation.usernameError(username) { throw APIError.validation(error) }
        return try await lock.withLock {
            if let existing = try await account(for: identity) { return existing }
            if try await User.query(on: db).filter(\.$username == username).first() != nil {
                throw APIError.validation(AccountValidation.duplicateMessage)
            }
            let isFirst = try await User.query(on: db).count() == 0
            let user = User(username: username, passwordHash: User.noPasswordHash, isAdmin: isFirst)
            user.oidcIssuer = identity.issuer
            user.oidcSubject = identity.subject
            if let address = identity.email.flatMap(EmailAddress.normalize) { user.email = try cipher.seal(address) }
            try await user.save(on: db)
            return user
        }
    }

    /// Linked accounts without password take the provider's address on every sign-in (missing or invalid: unchanged).
    func syncEmail(_ user: User, from identity: OIDCIdentity) async throws {
        guard user.emailFromProvider(oidc), let address = identity.email.flatMap(EmailAddress.normalize),
              user.emailState(cipher).address != address else { return }
        user.email = try cipher.seal(address)
        try await user.save(on: db)
    }

    /// Prefill for „Benutzername“: `preferred_username` (without `@`), the part before `@` of it or of the address,
    /// then the name – each lowercased, reduced to the allowed characters and cut to 32; nil when nothing fits.
    static func suggestUsername(_ identity: OIDCIdentity) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
        var candidates: [String] = []
        if let preferred = identity.preferredUsername {
            if preferred.contains("@") {
                candidates.append(String(preferred.prefix { $0 != "@" }))
            } else {
                candidates.append(preferred)
            }
        }
        if let email = identity.email { candidates.append(String(email.prefix { $0 != "@" })) }
        if let name = identity.name { candidates.append(name) }
        for candidate in candidates {
            let cleaned = String(String(User.normalize(candidate).filter { allowed.contains($0) }).prefix(32))
            if AccountValidation.usernameError(cleaned) == nil { return cleaned }
        }
        return nil
    }
}

extension Request {
    /// Only valid while OIDC is configured.
    var oidcLogin: OIDCLoginService {
        get throws {
            guard let oidc = application.appConfig.oidc else { throw Abort(.notFound) }
            return OIDCLoginService(db: db, cipher: application.tokenCipher, oidc: oidc,
                                    passwordLogin: application.appConfig.passwordLogin, lock: application.oidcIdentityLock)
        }
    }
}
