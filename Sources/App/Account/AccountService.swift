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

    func changePassword(user: User, current: String, new: String) async throws {
        guard try await hasher.verify(current, created: user.passwordHash) else {
            throw APIError.validation(AccountValidation.wrongCurrentPasswordMessage)
        }
        if let error = AccountValidation.passwordError(new) { throw APIError.validation(error) }
        user.passwordHash = try await hasher.hash(new)
        try await user.save(on: db)
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
        await worker.kick()
    }

    func removeTMDBToken(user: User) async throws {
        user.tmdbToken = nil
        try await user.save(on: db)
    }
}

extension Request {
    var account: AccountService {
        AccountService(db: db, hasher: password.async, tmdbProvider: application.tmdbProvider, cipher: application.tokenCipher,
                       worker: application.matchingWorker)
    }
}
