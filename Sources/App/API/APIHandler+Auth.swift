import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    /// Handles `POST /api/v1/auth/token`: exchanges a one-time code of the app login (PKCE) for a device token.
    ///
    /// Needs no bearer token. The code is redeemed from `AuthCodeStore`, the token is issued as `.device` by
    /// `APITokenService`, and after the response `DeviceNoticeService` sends the „Neues Gerät verbunden“ (new device
    /// connected) notice.
    /// - Parameter input: The generated operation input (JSON body with code, verifier and redirect URI).
    /// - Returns: `.ok` with the token, its expiry, the device and the user.
    /// - Throws: `APIError.invalidGrant` for a missing body, an invalid, expired or used code, a wrong verifier or
    ///   redirect URI, or a deleted user; database errors.
    func createToken(_ input: Operations.createToken.Input) async throws -> Operations.createToken.Output {
        guard case let .json(body) = input.body else { throw APIError.invalidGrant }
        let request = try APIContext.request()
        let grant = try await request.application.authCodes.redeem(code: body.code, verifier: body.codeVerifier,
                                                                   redirectURI: body.redirectUri)
        guard let user = try await User.find(grant.userID, on: request.db) else { throw APIError.invalidGrant }
        let issued = try await APITokenService(db: request.db).issue(userID: grant.userID, name: grant.deviceName, kind: .device)
        let notice = request.deviceNotice
        request.application.backgroundTasks.run { await notice.handle(userID: grant.userID, deviceName: grant.deviceName) }
        return .ok(.init(body: .json(.init(token: issued.token, expiresAt: issued.record.expiresAt, device: try Self.device(issued.record),
                                           user: .init(username: user.username, isAdmin: user.isAdmin)))))
    }

    /// Handles `DELETE /api/v1/auth/token`: deletes the presented bearer token (app logout) via `APITokenService`.
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.noContent`.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, database errors.
    func revokeCurrentToken(_ input: Operations.revokeCurrentToken.Input) async throws -> Operations.revokeCurrentToken.Output {
        _ = try APIContext.requireUser()
        let request = try APIContext.request()
        if let bearer = request.headers.bearerAuthorization?.token {
            try await APITokenService(db: request.db).revoke(bearer: bearer)
        }
        return .noContent(.init())
    }

    /// Maps a token record to the `Device` schema.
    /// - Parameter record: The stored token.
    /// - Returns: The schema value.
    /// - Throws: Fluent's `idRequired` error for an unsaved record.
    static func device(_ record: APIToken) throws -> Components.Schemas.Device {
        .init(id: try record.requireID().uuidString, name: record.name,
              kind: record.tokenKind == .manual ? .manual : .device,
              createdAt: record.createdAt, expiresAt: record.expiresAt, lastUsedAt: record.lastUsedAt)
    }

    /// Handles `GET /api/v1/me`: the signed-in user's account summary.
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with the `Me` schema.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token.
    func getMe(_ input: Operations.getMe.Input) async throws -> Operations.getMe.Output {
        .ok(.init(body: .json(try Self.me(APIContext.requireUser(), request: APIContext.request()))))
    }

    /// Builds the `Me` schema: account flags, SSO link and password-login state, e-mail address and the TMDB token
    /// state.
    ///
    /// The token itself never leaves the server: a readable token shows only its last four characters, one that cannot
    /// be decrypted is reported as `unreadable`.
    /// - Parameters:
    ///   - user: The signed-in user.
    ///   - request: The current request (cipher and login settings).
    /// - Returns: The schema value.
    static func me(_ user: User, request: Request) -> Components.Schemas.Me {
        let stored = user.tmdbToken ?? ""
        let plain = request.application.tokenCipher.open(stored)
        let token: Components.Schemas.TMDBTokenState
        if let plain {
            token = .init(state: .stored, suffix: "…" + String(plain.suffix(4)))
        } else {
            token = .init(state: stored.isEmpty ? Components.Schemas.TMDBTokenState.statePayload.none : .unreadable)
        }
        let config = request.application.loginSettings.current
        return .init(username: user.username, isAdmin: user.isAdmin, hasPassword: user.hasPassword,
                     ssoLinked: user.isLinked(config.oidc), passwordLogin: config.passwordLogin, tmdbToken: token,
                     email: user.emailState(request.application.tokenCipher).address)
    }
}
