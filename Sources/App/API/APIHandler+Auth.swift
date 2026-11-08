import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    func createToken(_ input: Operations.createToken.Input) async throws -> Operations.createToken.Output {
        guard case let .json(body) = input.body else { throw APIError.invalidGrant }
        let request = try APIContext.request()
        let grant = try await request.application.authCodes.redeem(code: body.code, verifier: body.codeVerifier,
                                                                   redirectURI: body.redirectUri)
        guard let user = try await User.find(grant.userID, on: request.db) else { throw APIError.invalidGrant }
        let issued = try await APITokenService(db: request.db).issue(userID: grant.userID, name: grant.deviceName, kind: .device)
        return .ok(.init(body: .json(.init(token: issued.token, expiresAt: issued.record.expiresAt, device: try Self.device(issued.record),
                                           user: .init(username: user.username, isAdmin: user.isAdmin)))))
    }

    func revokeCurrentToken(_ input: Operations.revokeCurrentToken.Input) async throws -> Operations.revokeCurrentToken.Output {
        _ = try APIContext.requireUser()
        let request = try APIContext.request()
        if let bearer = request.headers.bearerAuthorization?.token {
            try await APITokenService(db: request.db).revoke(bearer: bearer)
        }
        return .noContent(.init())
    }

    static func device(_ record: APIToken) throws -> Components.Schemas.Device {
        .init(id: try record.requireID().uuidString, name: record.name,
              kind: record.tokenKind == .manual ? .manual : .device,
              createdAt: record.createdAt, expiresAt: record.expiresAt, lastUsedAt: record.lastUsedAt)
    }

    func getMe(_ input: Operations.getMe.Input) async throws -> Operations.getMe.Output {
        .ok(.init(body: .json(try Self.me(APIContext.requireUser(), request: APIContext.request()))))
    }

    static func me(_ user: User, request: Request) -> Components.Schemas.Me {
        let stored = user.tmdbToken ?? ""
        let plain = request.application.tokenCipher.open(stored)
        let token: Components.Schemas.TMDBTokenState
        if let plain {
            token = .init(state: .stored, suffix: "…" + String(plain.suffix(4)))
        } else {
            token = .init(state: stored.isEmpty ? Components.Schemas.TMDBTokenState.statePayload.none : .unreadable)
        }
        return .init(username: user.username, isAdmin: user.isAdmin, hasPassword: true, tmdbToken: token)
    }
}
