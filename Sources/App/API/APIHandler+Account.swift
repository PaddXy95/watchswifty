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
}
