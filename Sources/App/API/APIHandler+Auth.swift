import Vapor
import WatchSwiftyAPI

extension APIHandler {
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
