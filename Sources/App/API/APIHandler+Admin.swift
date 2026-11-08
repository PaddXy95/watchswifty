import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    func listUsers(_ input: Operations.listUsers.Input) async throws -> Operations.listUsers.Output {
        _ = try APIContext.requireAdmin()
        let users = try await APIContext.request().userAdmin.list()
        return .ok(.init(body: .json(users.map(Self.userSummary))))
    }

    func createUser(_ input: Operations.createUser.Input) async throws -> Operations.createUser.Output {
        _ = try APIContext.requireAdmin()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        let user = try await APIContext.request().userAdmin.create(username: body.username, password: body.password, isAdmin: body.isAdmin ?? false)
        return .created(.init(body: .json(Self.userSummary(user))))
    }

    func resetUserPassword(_ input: Operations.resetUserPassword.Input) async throws -> Operations.resetUserPassword.Output {
        let admin = try APIContext.requireAdmin()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await APIContext.request().userAdmin.resetPassword(id: id, password: body.password, actingUserID: admin.requireID())
        return .noContent(.init())
    }

    func setUserAdmin(_ input: Operations.setUserAdmin.Input) async throws -> Operations.setUserAdmin.Output {
        let admin = try APIContext.requireAdmin()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        let user = try await APIContext.request().userAdmin.setAdmin(id: id, isAdmin: body.isAdmin, actingUserID: admin.requireID())
        return .ok(.init(body: .json(Self.userSummary(user))))
    }

    func deleteUser(_ input: Operations.deleteUser.Input) async throws -> Operations.deleteUser.Output {
        let admin = try APIContext.requireAdmin()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        try await APIContext.request().userAdmin.delete(id: id, actingUserID: admin.requireID())
        return .noContent(.init())
    }

    static func userSummary(_ user: User) -> Components.Schemas.UserSummary {
        .init(id: user.id?.uuidString ?? "", username: user.username, isAdmin: user.isAdmin,
              hasTMDBToken: !(user.tmdbToken ?? "").isEmpty, createdAt: user.createdAt)
    }

    func getSystem(_ input: Operations.getSystem.Input) async throws -> Operations.getSystem.Output {
        _ = try APIContext.requireAdmin()
        return .ok(.init(body: .json(try await Self.system(APIContext.request()))))
    }

    /// Enabling checks GitHub once right away (as the web page does).
    func setUpdateCheck(_ input: Operations.setUpdateCheck.Input) async throws -> Operations.setUpdateCheck.Output {
        _ = try APIContext.requireAdmin()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        let request = try APIContext.request()
        let updates = request.application.updates
        let wasEnabled = try await updates.settings().updateCheck
        try await updates.setEnabled(body.enabled)
        if body.enabled && !wasEnabled { try await updates.checkNow() }
        return .ok(.init(body: .json(try await Self.system(request))))
    }

    func checkUpdatesNow(_ input: Operations.checkUpdatesNow.Input) async throws -> Operations.checkUpdatesNow.Output {
        _ = try APIContext.requireAdmin()
        let request = try APIContext.request()
        try await request.application.updates.checkNow()
        return .ok(.init(body: .json(try await Self.system(request))))
    }

    static func system(_ request: Request) async throws -> Components.Schemas.System {
        let version = request.application.appConfig.appVersion
        let settings = try await request.application.updates.settings()
        return .init(version: .init(version: version.version, commit: version.commit),
                     updateCheck: .init(enabled: settings.updateCheck, checkedAt: settings.checkedAt, latestVersion: settings.latestVersion,
                                        latestUrl: settings.latestURL, error: settings.checkError,
                                        updateAvailable: settings.latestVersion.flatMap { isNewerVersion($0, than: version.version) }))
    }
}
