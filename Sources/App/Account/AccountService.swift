import Fluent
import Foundation
import Vapor

/// Account changes shared by the Konto page and the API; failures are `APIError.validation` with the web texts.
struct AccountService {
    let db: any Database
    let hasher: AsyncPasswordHasher
    let tmdbProvider: TMDBProvider
    let cipher: TokenCipher
    let worker: MatchingWorker
    var oidc: OIDCConfig? = nil
    var passwordLogin = true
    /// Reload from TMDB: a new token clears its last result, removing the token stops it.
    var libraryRefresh: LibraryRefreshWorker? = nil

    func changePassword(user: User, current: String, new: String) async throws {
        guard passwordLogin else { throw APIError.passwordLoginDisabled() }
        guard user.hasPassword else { throw APIError.noPassword }
        guard try await hasher.verify(current, created: user.passwordHash) else {
            throw APIError.validation(AccountValidation.wrongCurrentPasswordMessage)
        }
        if let error = AccountValidation.passwordError(new) { throw APIError.validation(error) }
        user.passwordHash = try await hasher.hash(new)
        try await user.save(on: db)
    }

    /// Sets (or with an empty value removes) the user's own address. Needs the current password, so a hijacked session
    /// cannot redirect „Passwort vergessen“ to another inbox; open reset links end.
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

    func removeTMDBToken(user: User) async throws {
        await libraryRefresh?.cancel(userID: try user.requireID())
        user.tmdbToken = nil
        try await user.save(on: db)
    }
}

extension Request {
    var account: AccountService {
        AccountService(db: db, hasher: password.async, tmdbProvider: application.tmdbProvider, cipher: application.tokenCipher,
                       worker: application.matchingWorker, oidc: application.loginSettings.current.oidc,
                       passwordLogin: application.loginSettings.current.passwordLogin, libraryRefresh: application.libraryRefresh)
    }
}
