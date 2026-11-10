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
        let admin = try APIContext.requireAdmin()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        let service = try APIContext.request().userAdmin
        let created = try await service.create(username: body.username, password: body.password, email: body.email,
                                               isAdmin: body.isAdmin ?? false, inviter: admin)
        let summary = Self.userSummary(try await service.row(for: created.user))
        return .created(.init(body: .json(.init(value1: summary, value2: .init(inviteMailError: created.inviteMailError)))))
    }

    func resendInvite(_ input: Operations.resendInvite.Input) async throws -> Operations.resendInvite.Output {
        let admin = try APIContext.requireAdmin()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        let service = try APIContext.request().userAdmin
        let user = try await service.resendInvite(id: id, inviter: admin)
        return .ok(.init(body: .json(Self.userSummary(try await service.row(for: user)))))
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
        let service = try APIContext.request().userAdmin
        let user = try await service.setAdmin(id: id, isAdmin: body.isAdmin, actingUserID: admin.requireID())
        return .ok(.init(body: .json(Self.userSummary(try await service.row(for: user)))))
    }

    func deleteUser(_ input: Operations.deleteUser.Input) async throws -> Operations.deleteUser.Output {
        let admin = try APIContext.requireAdmin()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        try await APIContext.request().userAdmin.delete(id: id, actingUserID: admin.requireID())
        return .noContent(.init())
    }

    /// The address only as a mask; never the full address of another user.
    static func userSummary(_ row: AdminUserRow) -> Components.Schemas.UserSummary {
        let user = row.user
        var expires: Date?
        if case .pending(let date) = row.invite { expires = date }
        return .init(id: user.id?.uuidString ?? "", username: user.username, isAdmin: user.isAdmin,
                     hasTMDBToken: !(user.tmdbToken ?? "").isEmpty, createdAt: user.createdAt, emailHint: row.emailHint,
                     invitePending: expires != nil, ssoLinked: row.ssoLinked, inviteExpiresAt: expires)
    }

    func createSSOLink(_ input: Operations.createSSOLink.Input) async throws -> Operations.createSSOLink.Output {
        let admin = try APIContext.requireAdmin()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        let result = try await APIContext.request().userAdmin.createSSOLink(id: id, inviter: admin)
        return .ok(.init(body: .json(.init(mailed: result.mailed, emailHint: result.emailHint, url: result.url,
                                           mailError: result.mailError))))
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

extension APIHandler {
    func getMailSettings(_ input: Operations.getMailSettings.Input) async throws -> Operations.getMailSettings.Output {
        _ = try APIContext.requireAdmin()
        return .ok(.init(body: .json(Self.mailSettings(try await APIContext.request().mailSettings.state()))))
    }

    func setMailSettings(_ input: Operations.setMailSettings.Input) async throws -> Operations.setMailSettings.Output {
        _ = try APIContext.requireAdmin()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        let service = try APIContext.request().mailSettings
        try await service.save(MailSettingsInput(
            host: body.host, port: body.port.map(String.init), encryption: body.encryption.rawValue, username: body.username,
            password: body.password, fromAddress: body.fromAddress, fromName: body.fromName, caFile: body.caFile, baseURL: body.baseUrl))
        return .ok(.init(body: .json(Self.mailSettings(try await service.state()))))
    }

    func deleteMailSettings(_ input: Operations.deleteMailSettings.Input) async throws -> Operations.deleteMailSettings.Output {
        _ = try APIContext.requireAdmin()
        try await APIContext.request().mailSettings.delete()
        return .noContent(.init())
    }

    func sendTestMail(_ input: Operations.sendTestMail.Input) async throws -> Operations.sendTestMail.Output {
        _ = try APIContext.requireAdmin()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await APIContext.request().mail.sendTest(to: body.to)
        return .noContent(.init())
    }

    /// Never includes the password itself.
    static func mailSettings(_ state: MailSettingsState) -> Components.Schemas.MailSettings {
        let settings = state.settings
        return .init(configured: settings != nil, unreadable: state == .unreadable, host: settings?.host, port: settings?.port,
                     encryption: settings.flatMap { Components.Schemas.MailEncryption(rawValue: $0.encryption.rawValue) },
                     username: settings?.username, hasPassword: settings?.password != nil, fromAddress: settings?.fromAddress,
                     fromName: settings?.fromName, caFile: settings?.caFile, baseUrl: settings?.baseURL)
    }
}
