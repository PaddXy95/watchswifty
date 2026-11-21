import Fluent
import Foundation
import Vapor

/// Account changes shared by the Konto page and the API; failures are `APIError.validation` with the web texts.
struct AccountService {
    let db: any Database
    let hasher: AsyncPasswordHasher
    /// Builds a TMDB client for a token (used to validate a new token).
    let tmdbProvider: TMDBProvider
    /// Cipher sealing the TMDB token and e-mail address at rest.
    let cipher: TokenCipher
    /// Netflix matching worker, woken after a new TMDB token is stored.
    let worker: MatchingWorker
    /// The configured OIDC provider, nil when SSO is not set up.
    var oidc: OIDCConfig? = nil
    /// Whether password login is enabled.
    var passwordLogin = true
    /// Reload from TMDB: a new token clears its last result, removing the token stops it.
    var libraryRefresh: LibraryRefreshWorker? = nil

    /// Changes the user's own password after checking the current one; open reset and invitation links end.
    /// - Parameters:
    ///   - user: The logged-in user.
    ///   - current: The current password.
    ///   - new: The new password (validated with `AccountValidation`).
    /// - Throws: `APIError.passwordLoginDisabled` when password login is off, `APIError.noPassword` for accounts without
    ///   password, `APIError.validation` for a wrong current or weak new password.
    func changePassword(user: User, current: String, new: String) async throws {
        guard passwordLogin else { throw APIError.passwordLoginDisabled() }
        guard user.hasPassword else { throw APIError.noPassword }
        guard try await hasher.verify(current, created: user.passwordHash) else {
            throw APIError.validation(AccountValidation.wrongCurrentPasswordMessage)
        }
        if let error = AccountValidation.passwordError(new) { throw APIError.validation(error) }
        user.passwordHash = try await hasher.hash(new)
        try await user.save(on: db)
        // Like every other way of setting a password: open reset and invitation links end.
        try await PasswordTokenService(db: db).deleteAll(userID: user.requireID())
    }

    /// Sets (or with an empty value removes) the user's own address. Needs the current password, so a hijacked session
    /// cannot redirect „Passwort vergessen“ to another inbox; open reset links end.
    /// The address is sealed with `TokenCipher`.
    /// - Parameters:
    ///   - user: The logged-in user.
    ///   - raw: The new address as entered; empty or whitespace removes it.
    ///   - currentPassword: The user's current password.
    /// - Throws: `APIError.emailFromProvider` when the provider supplies the address, `APIError.noPassword` for accounts
    ///   without password, `APIError.validation` for a wrong password or an invalid address.
    func setEmail(user: User, email raw: String, currentPassword: String) async throws {
        if user.emailFromProvider(oidc), let oidc { throw APIError.emailFromProvider(name: oidc.displayName) }
        guard user.hasPassword else { throw APIError.noPassword }
        guard try await hasher.verify(currentPassword, created: user.passwordHash) else {
            throw APIError.validation(AccountValidation.wrongCurrentPasswordMessage)
        }
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            user.email = nil
        } else {
            guard let address = EmailAddress.normalize(raw) else { throw APIError.validation(EmailAddress.invalidMessage) }
            user.email = try cipher.seal(address)
        }
        try await user.save(on: db)
        try await PasswordTokenService(db: db).deleteReset(userID: user.requireID())
    }

    /// Stores the user's TMDB token (encrypted) after TMDB accepted it, then lets the Netflix matching continue.
    /// Also clears the user's last library reload result.
    /// - Parameters:
    ///   - user: The logged-in user.
    ///   - rawToken: The token as entered (trimmed here).
    /// - Throws: `APIError.validation` when the token is empty, rejected by TMDB, or TMDB is unreachable.
    func saveTMDBToken(user: User, token rawToken: String) async throws {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw APIError.validation("Bitte einen Token eingeben.") }
        do {
            try await tmdbProvider.make(token).validate()
        } catch TMDBError.unauthorized {
            throw APIError.validation("TMDB hat den Token abgelehnt.")
        } catch {
            throw APIError.validation("TMDB nicht erreichbar – Token nicht gespeichert.")
        }
        user.tmdbToken = try cipher.seal(token)
        try await user.save(on: db)
        await libraryRefresh?.forget(userID: try user.requireID())
        await worker.kick()
    }

    /// Removes the user's TMDB token and cancels a running library reload.
    /// - Parameter user: The logged-in user.
    /// - Throws: Database errors.
    func removeTMDBToken(user: User) async throws {
        await libraryRefresh?.cancel(userID: try user.requireID())
        user.tmdbToken = nil
        try await user.save(on: db)
    }
}

extension Request {
    /// An account service for this request, using the current login settings.
    var account: AccountService {
        AccountService(db: db, hasher: password.async, tmdbProvider: application.tmdbProvider, cipher: application.tokenCipher,
                       worker: application.matchingWorker, oidc: application.loginSettings.current.oidc,
                       passwordLogin: application.loginSettings.current.passwordLogin, libraryRefresh: application.libraryRefresh)
    }
}
