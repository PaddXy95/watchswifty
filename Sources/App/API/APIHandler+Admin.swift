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
                                               isAdmin: body.isAdmin ?? false, inviter: admin,
                                               confirmation: .password(body.currentPassword))
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
        try await APIContext.request().userAdmin.resetPassword(id: id, password: body.password, actingUserID: admin.requireID(),
                                                               confirmation: .password(body.currentPassword))
        return .noContent(.init())
    }

    func setUserAdmin(_ input: Operations.setUserAdmin.Input) async throws -> Operations.setUserAdmin.Output {
        let admin = try APIContext.requireAdmin()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        let service = try APIContext.request().userAdmin
        let user = try await service.setAdmin(id: id, isAdmin: body.isAdmin, actingUserID: admin.requireID(),
                                              confirmation: .password(body.currentPassword))
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
        var currentPassword: String?
        if case let .json(body)? = input.body { currentPassword = body.currentPassword }
        let result = try await APIContext.request().userAdmin.createSSOLink(id: id, inviter: admin, confirmation: .password(currentPassword))
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
    // MARK: - SSO settings

    func getOIDCSettings(_ input: Operations.getOIDCSettings.Input) async throws -> Operations.getOIDCSettings.Output {
        _ = try APIContext.requireAdmin()
        let request = try APIContext.request()
        return .ok(.init(body: .json(Self.oidcSettings(try await request.oidcSettings.state(), request: request))))
    }

    func setOIDCSettings(_ input: Operations.setOIDCSettings.Input) async throws -> Operations.setOIDCSettings.Output {
        _ = try APIContext.requireAdmin()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        let request = try APIContext.request()
        let saved = try await request.oidcSettings.save(OIDCSettingsInput(displayName: body.displayName, issuer: body.issuer,
                                                                          clientID: body.clientId, clientSecret: body.clientSecret,
                                                                          baseURL: body.baseUrl))
        var checkError: String?
        if let config = saved.config, case .failure(let failure) = await SystemController.check(request, config) {
            checkError = failure.message
        }
        return .ok(.init(body: .json(Self.oidcSettings(try await request.oidcSettings.state(), request: request, checkError: checkError))))
    }

    func deleteOIDCSettings(_ input: Operations.deleteOIDCSettings.Input) async throws -> Operations.deleteOIDCSettings.Output {
        _ = try APIContext.requireAdmin()
        try await APIContext.request().oidcSettings.delete()
        return .noContent(.init())
    }

    func testOIDCSettings(_ input: Operations.testOIDCSettings.Input) async throws -> Operations.testOIDCSettings.Output {
        _ = try APIContext.requireAdmin()
        let request = try APIContext.request()
        guard let config = request.application.loginSettings.current.oidc else {
            throw APIError.validation(OIDCSettingsService.needsOIDCMessage)
        }
        do {
            let result = try await request.application.oidcProviders.provider(for: config).check()
            return .ok(.init(body: .json(.init(issuer: result.issuer, keyCount: result.keyCount))))
        } catch let error as OIDCError {
            throw APIError(status: .serviceUnavailable, code: "oidcCheckFailed", message: error.adminDescription(name: config.displayName))
        }
    }

    func setPasswordLogin(_ input: Operations.setPasswordLogin.Input) async throws -> Operations.setPasswordLogin.Output {
        let admin = try APIContext.requireAdmin()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        let request = try APIContext.request()
        try await request.oidcSettings.setPasswordLogin(body.enabled, actingUser: admin)
        return .ok(.init(body: .json(Self.oidcSettings(try await request.oidcSettings.state(), request: request))))
    }

    /// Never includes the client secret.
    static func oidcSettings(_ state: OIDCSettingsState, request: Request, checkError: String? = nil) -> Components.Schemas.OIDCSettings {
        let settings = state.settings
        let login = request.application.loginSettings.current
        return .init(configured: settings != nil, unreadable: state == .unreadable, displayName: settings?.displayName,
                     issuer: settings?.issuer, clientId: settings?.clientID, hasClientSecret: settings != nil,
                     baseUrl: settings?.baseURL, redirectUrl: settings?.redirectURL, passwordLogin: login.passwordLogin,
                     passwordLoginForced: login.passwordLoginForced, passwordLoginStored: settings?.passwordLogin,
                     checkError: checkError)
    }

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
