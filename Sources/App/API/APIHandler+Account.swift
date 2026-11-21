import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    /// Handles `GET /api/v1/me/devices`: the user's App API tokens, newest first (`APITokenService.list`).
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with the devices.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, database errors.
    func listDevices(_ input: Operations.listDevices.Input) async throws -> Operations.listDevices.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let devices = try await APITokenService(db: request.db).list(userID: user.requireID())
        return .ok(.init(body: .json(try devices.map(Self.device))))
    }

    /// Handles `DELETE /api/v1/me/devices/{id}`: revokes one of the user's tokens (`APITokenService.revoke`).
    /// - Parameter input: The generated operation input (path `id`).
    /// - Returns: `.noContent`.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.notFound`
    ///   for a malformed, unknown or another user's token.
    func revokeDevice(_ input: Operations.revokeDevice.Input) async throws -> Operations.revokeDevice.Output {
        let user = try APIContext.requireUser()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        try await APITokenService(db: try APIContext.request().db).revoke(id: id, userID: user.requireID())
        return .noContent(.init())
    }

    /// Handles `PUT /api/v1/me/password`: changes the user's password via `AccountService.changePassword`.
    /// - Parameter input: The generated operation input (JSON body with current and new password).
    /// - Returns: `.noContent`.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.validation`
    ///   without a body, errors of `AccountService.changePassword`.
    func changePassword(_ input: Operations.changePassword.Input) async throws -> Operations.changePassword.Output {
        let user = try APIContext.requireUser()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await APIContext.request().account.changePassword(user: user, current: body.currentPassword, new: body.newPassword)
        return .noContent(.init())
    }

    /// Handles `PUT /api/v1/me/email`: sets or clears the user's e-mail address via `AccountService.setEmail`.
    /// - Parameter input: The generated operation input (JSON body with address and current password).
    /// - Returns: `.ok` with the updated `Me` schema.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.validation`
    ///   without a body, errors of `AccountService.setEmail`.
    func setEmail(_ input: Operations.setEmail.Input) async throws -> Operations.setEmail.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await request.account.setEmail(user: user, email: body.email, currentPassword: body.currentPassword)
        return .ok(.init(body: .json(Self.me(user, request: request))))
    }

    /// Handles `PUT /api/v1/me/tmdb-token`: stores the user's TMDB token via `AccountService.saveTMDBToken`.
    /// - Parameter input: The generated operation input (JSON body with the token).
    /// - Returns: `.ok` with the updated `Me` schema.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.validation`
    ///   without a body, errors of `AccountService.saveTMDBToken`.
    func setTMDBToken(_ input: Operations.setTMDBToken.Input) async throws -> Operations.setTMDBToken.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard case let .json(body) = input.body else { throw APIError.validation("Bitte einen Token eingeben.") }
        try await request.account.saveTMDBToken(user: user, token: body.token)
        return .ok(.init(body: .json(Self.me(user, request: request))))
    }

    /// Handles `DELETE /api/v1/me/tmdb-token`: removes the user's TMDB token via `AccountService.removeTMDBToken`.
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with the updated `Me` schema.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, errors of
    ///   `AccountService.removeTMDBToken`.
    func deleteTMDBToken(_ input: Operations.deleteTMDBToken.Input) async throws -> Operations.deleteTMDBToken.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        try await request.account.removeTMDBToken(user: user)
        return .ok(.init(body: .json(Self.me(user, request: request))))
    }

    /// Handles `GET /api/v1/me/followed`: the series the user follows, each with its next episode
    /// (`NewEpisodesService.followedSeries`).
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with the followed series.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, database errors.
    func getFollowed(_ input: Operations.getFollowed.Input) async throws -> Operations.getFollowed.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let followed = try await NewEpisodesService(db: request.db).followedSeries(userID: user.requireID(), today: request.watches.today())
        return .ok(.init(body: .json(followed.map { .init(tmdbId: $0.tmdbID, name: $0.name, nextEpisode: $0.nextEpisode.map(Self.nextEpisode)) })))
    }
}
