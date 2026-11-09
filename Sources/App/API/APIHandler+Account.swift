import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    func listDevices(_ input: Operations.listDevices.Input) async throws -> Operations.listDevices.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let devices = try await APITokenService(db: request.db).list(userID: user.requireID())
        return .ok(.init(body: .json(try devices.map(Self.device))))
    }

    func revokeDevice(_ input: Operations.revokeDevice.Input) async throws -> Operations.revokeDevice.Output {
        let user = try APIContext.requireUser()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        try await APITokenService(db: try APIContext.request().db).revoke(id: id, userID: user.requireID())
        return .noContent(.init())
    }

    func changePassword(_ input: Operations.changePassword.Input) async throws -> Operations.changePassword.Output {
        let user = try APIContext.requireUser()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await APIContext.request().account.changePassword(user: user, current: body.currentPassword, new: body.newPassword)
        return .noContent(.init())
    }

    func setEmail(_ input: Operations.setEmail.Input) async throws -> Operations.setEmail.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await request.account.setEmail(user: user, email: body.email, currentPassword: body.currentPassword)
        return .ok(.init(body: .json(Self.me(user, request: request))))
    }

    func setTMDBToken(_ input: Operations.setTMDBToken.Input) async throws -> Operations.setTMDBToken.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        guard case let .json(body) = input.body else { throw APIError.validation("Bitte einen Token eingeben.") }
        try await request.account.saveTMDBToken(user: user, token: body.token)
        return .ok(.init(body: .json(Self.me(user, request: request))))
    }

    func deleteTMDBToken(_ input: Operations.deleteTMDBToken.Input) async throws -> Operations.deleteTMDBToken.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        try await request.account.removeTMDBToken(user: user)
        return .ok(.init(body: .json(Self.me(user, request: request))))
    }

    func getFollowed(_ input: Operations.getFollowed.Input) async throws -> Operations.getFollowed.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let followed = try await NewEpisodesService(db: request.db).followedSeries(userID: user.requireID(), today: request.watches.today())
        return .ok(.init(body: .json(followed.map { .init(tmdbId: $0.tmdbID, name: $0.name, nextEpisode: $0.nextEpisode.map(Self.nextEpisode)) })))
    }
}
