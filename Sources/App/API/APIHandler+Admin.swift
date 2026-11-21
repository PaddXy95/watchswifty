import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    /// Handles `GET /api/v1/admin/users`: all accounts (`UserAdminService.list`).
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with the user summaries.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, database errors.
    func listUsers(_ input: Operations.listUsers.Input) async throws -> Operations.listUsers.Output {
        _ = try APIContext.requireAdmin()
        let users = try await APIContext.request().userAdmin.list()
        return .ok(.init(body: .json(users.map(Self.userSummary))))
    }

    /// Handles `POST /api/v1/admin/users`: creates an account via `UserAdminService.create`; granting admin rights is
    /// confirmed with the acting admin's current password.
    /// - Parameter input: The generated operation input (JSON body).
    /// - Returns: `.created` with the new user's summary and the error of a failed invitation mail.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, `APIError.validation` without a body, errors of `UserAdminService.create`.
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

    /// Handles `POST /api/v1/admin/users/{id}/invite`: sends a new invitation link (`UserAdminService.resendInvite`).
    /// - Parameter input: The generated operation input (path `id`).
    /// - Returns: `.ok` with the user's summary.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, `APIError.notFound` for a malformed or unknown ID, errors of `UserAdminService.resendInvite`.
    func resendInvite(_ input: Operations.resendInvite.Input) async throws -> Operations.resendInvite.Output {
        let admin = try APIContext.requireAdmin()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        let service = try APIContext.request().userAdmin
        let user = try await service.resendInvite(id: id, inviter: admin)
        return .ok(.init(body: .json(Self.userSummary(try await service.row(for: user)))))
    }

    /// Handles `PUT /api/v1/admin/users/{id}/password`: sets a user's password (`UserAdminService.resetPassword`).
    /// - Parameter input: The generated operation input (path `id`, JSON body with the new and the admin's current
    ///   password).
    /// - Returns: `.noContent`.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, `APIError.notFound` for a malformed ID, `APIError.validation` without a body, errors of
    ///   `UserAdminService.resetPassword`.
    func resetUserPassword(_ input: Operations.resetUserPassword.Input) async throws -> Operations.resetUserPassword.Output {
        let admin = try APIContext.requireAdmin()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await APIContext.request().userAdmin.resetPassword(id: id, password: body.password, actingUserID: admin.requireID(),
                                                               confirmation: .password(body.currentPassword))
        return .noContent(.init())
    }

    /// Handles `PUT /api/v1/admin/users/{id}/admin`: grants or revokes admin rights (`UserAdminService.setAdmin`).
    /// - Parameter input: The generated operation input (path `id`, JSON body with `isAdmin` and the admin's current
    ///   password).
    /// - Returns: `.ok` with the user's summary.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, `APIError.notFound` for a malformed ID, `APIError.validation` without a body, errors of
    ///   `UserAdminService.setAdmin`.
    func setUserAdmin(_ input: Operations.setUserAdmin.Input) async throws -> Operations.setUserAdmin.Output {
        let admin = try APIContext.requireAdmin()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        let service = try APIContext.request().userAdmin
        let user = try await service.setAdmin(id: id, isAdmin: body.isAdmin, actingUserID: admin.requireID(),
                                              confirmation: .password(body.currentPassword))
        return .ok(.init(body: .json(Self.userSummary(try await service.row(for: user)))))
    }

    /// Handles `DELETE /api/v1/admin/users/{id}`: deletes an account (`UserAdminService.delete`).
    /// - Parameter input: The generated operation input (path `id`).
    /// - Returns: `.noContent`.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, `APIError.notFound` for a malformed ID, errors of `UserAdminService.delete`.
    func deleteUser(_ input: Operations.deleteUser.Input) async throws -> Operations.deleteUser.Output {
        let admin = try APIContext.requireAdmin()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        try await APIContext.request().userAdmin.delete(id: id, actingUserID: admin.requireID())
        return .noContent(.init())
    }

    /// The address only as a mask; never the full address of another user.
    /// - Parameter row: The admin list row of the user.
    /// - Returns: The `UserSummary` schema.
    static func userSummary(_ row: AdminUserRow) -> Components.Schemas.UserSummary {
        let user = row.user
        var expires: Date?
        if case .pending(let date) = row.invite { expires = date }
        return .init(id: user.id?.uuidString ?? "", username: user.username, isAdmin: user.isAdmin,
                     hasTMDBToken: !(user.tmdbToken ?? "").isEmpty, createdAt: user.createdAt, emailHint: row.emailHint,
                     invitePending: expires != nil, ssoLinked: row.ssoLinked, inviteExpiresAt: expires)
    }

    /// Handles `POST /api/v1/admin/users/{id}/sso-link`: creates a „Verknüpfungslink“ (linking link) for the provider
    /// (`UserAdminService.createSSOLink`), mailed or returned to show once.
    /// - Parameter input: The generated operation input (path `id`, optional body with the admin's current password).
    /// - Returns: `.ok` with whether it was mailed, the link otherwise and any mail error.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, `APIError.notFound` for a malformed ID, errors of `UserAdminService.createSSOLink`.
    func createSSOLink(_ input: Operations.createSSOLink.Input) async throws -> Operations.createSSOLink.Output {
        let admin = try APIContext.requireAdmin()
        guard let id = UUID(uuidString: input.path.id) else { throw APIError.notFound }
        var currentPassword: String?
        if case let .json(body)? = input.body { currentPassword = body.currentPassword }
        let result = try await APIContext.request().userAdmin.createSSOLink(id: id, inviter: admin, confirmation: .password(currentPassword))
        return .ok(.init(body: .json(.init(mailed: result.mailed, emailHint: result.emailHint, url: result.url,
                                           mailError: result.mailError))))
    }

    /// Handles `GET /api/v1/admin/system`: version and update-check state.
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with the system state.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, database errors.
    func getSystem(_ input: Operations.getSystem.Input) async throws -> Operations.getSystem.Output {
        _ = try APIContext.requireAdmin()
        return .ok(.init(body: .json(try await Self.system(APIContext.request()))))
    }

    /// Handles `PUT /api/v1/admin/system/update-check`: switches the GitHub update check on or off (`UpdateService`).
    ///
    /// Enabling checks GitHub once right away (as the web page does).
    /// - Parameter input: The generated operation input (JSON body with `enabled`).
    /// - Returns: `.ok` with the system state.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, `APIError.validation` without a body, errors of `UpdateService`.
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

    /// Handles `POST /api/v1/admin/system/check-now`: checks GitHub for a newer release now (`UpdateService.checkNow`).
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with the system state.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, errors of `UpdateService.checkNow`.
    func checkUpdatesNow(_ input: Operations.checkUpdatesNow.Input) async throws -> Operations.checkUpdatesNow.Output {
        _ = try APIContext.requireAdmin()
        let request = try APIContext.request()
        try await request.application.updates.checkNow()
        return .ok(.init(body: .json(try await Self.system(request))))
    }

    /// Builds the `System` schema: this build's version and the update-check state.
    /// - Parameter request: The current request.
    /// - Returns: The schema value.
    /// - Throws: Database errors.
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

    /// Handles `GET /api/v1/admin/oidc`: the OIDC (SSO) setup and the password-login switch (`OIDCSettingsService`).
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with the settings, without the client secret.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, database errors.
    func getOIDCSettings(_ input: Operations.getOIDCSettings.Input) async throws -> Operations.getOIDCSettings.Output {
        _ = try APIContext.requireAdmin()
        let request = try APIContext.request()
        return .ok(.init(body: .json(Self.oidcSettings(try await request.oidcSettings.state(), request: request))))
    }

    /// Handles `PUT /api/v1/admin/oidc`: saves the OIDC setup (`OIDCSettingsService.save`) and checks the provider; a
    /// failed check is returned as `checkError`, not thrown.
    /// - Parameter input: The generated operation input (JSON body).
    /// - Returns: `.ok` with the saved settings.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, `APIError.validation` without a body, errors of `OIDCSettingsService.save`.
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

    /// Handles `DELETE /api/v1/admin/oidc`: removes the OIDC setup (`OIDCSettingsService.delete`).
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.noContent`.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, errors of `OIDCSettingsService.delete`.
    func deleteOIDCSettings(_ input: Operations.deleteOIDCSettings.Input) async throws -> Operations.deleteOIDCSettings.Output {
        _ = try APIContext.requireAdmin()
        try await APIContext.request().oidcSettings.delete()
        return .noContent(.init())
    }

    /// Handles `POST /api/v1/admin/oidc/test`: checks the configured provider (discovery and signing keys).
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with the issuer and the number of keys.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, `APIError.validation` without an OIDC setup, `APIError` 503 `oidcCheckFailed` when the check
    ///   fails.
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

    /// Handles `PUT /api/v1/admin/oidc/password-login`: switches the password login on or off
    /// (`OIDCSettingsService.setPasswordLogin`).
    /// - Parameter input: The generated operation input (JSON body with `enabled`).
    /// - Returns: `.ok` with the settings.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, `APIError.validation` without a body, errors of `OIDCSettingsService.setPasswordLogin`.
    func setPasswordLogin(_ input: Operations.setPasswordLogin.Input) async throws -> Operations.setPasswordLogin.Output {
        let admin = try APIContext.requireAdmin()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        let request = try APIContext.request()
        try await request.oidcSettings.setPasswordLogin(body.enabled, actingUser: admin)
        return .ok(.init(body: .json(Self.oidcSettings(try await request.oidcSettings.state(), request: request))))
    }

    /// Never includes the client secret.
    /// - Parameters:
    ///   - state: The stored OIDC setup.
    ///   - request: The current request (login settings).
    ///   - checkError: The message of a failed provider check after saving.
    /// - Returns: The `OIDCSettings` schema.
    static func oidcSettings(_ state: OIDCSettingsState, request: Request, checkError: String? = nil) -> Components.Schemas.OIDCSettings {
        let settings = state.settings
        let login = request.application.loginSettings.current
        return .init(configured: settings != nil, unreadable: state == .unreadable, displayName: settings?.displayName,
                     issuer: settings?.issuer, clientId: settings?.clientID, hasClientSecret: settings != nil,
                     baseUrl: settings?.baseURL, redirectUrl: settings?.redirectURL, passwordLogin: login.passwordLogin,
                     passwordLoginForced: login.passwordLoginForced, passwordLoginStored: settings?.passwordLogin,
                     checkError: checkError)
    }

    /// Handles `GET /api/v1/admin/mail`: the SMTP settings (`MailSettingsService`).
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with the settings, without the password.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, database errors.
    func getMailSettings(_ input: Operations.getMailSettings.Input) async throws -> Operations.getMailSettings.Output {
        _ = try APIContext.requireAdmin()
        return .ok(.init(body: .json(Self.mailSettings(try await APIContext.request().mailSettings.state()))))
    }

    /// Handles `PUT /api/v1/admin/mail`: saves the SMTP settings (`MailSettingsService.save`).
    /// - Parameter input: The generated operation input (JSON body).
    /// - Returns: `.ok` with the saved settings.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, `APIError.validation` without a body, errors of `MailSettingsService.save`.
    func setMailSettings(_ input: Operations.setMailSettings.Input) async throws -> Operations.setMailSettings.Output {
        _ = try APIContext.requireAdmin()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        let service = try APIContext.request().mailSettings
        try await service.save(MailSettingsInput(
            host: body.host, port: body.port.map(String.init), encryption: body.encryption.rawValue, username: body.username,
            password: body.password, fromAddress: body.fromAddress, fromName: body.fromName, caFile: body.caFile, baseURL: body.baseUrl))
        return .ok(.init(body: .json(Self.mailSettings(try await service.state()))))
    }

    /// Handles `DELETE /api/v1/admin/mail`: removes the SMTP settings (`MailSettingsService.delete`).
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.noContent`.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, errors of `MailSettingsService.delete`.
    func deleteMailSettings(_ input: Operations.deleteMailSettings.Input) async throws -> Operations.deleteMailSettings.Output {
        _ = try APIContext.requireAdmin()
        try await APIContext.request().mailSettings.delete()
        return .noContent(.init())
    }

    /// Handles `POST /api/v1/admin/mail/test`: sends a test mail (`MailService.sendTest`).
    /// - Parameter input: The generated operation input (JSON body with the recipient).
    /// - Returns: `.noContent`.
    /// - Throws: `APIError.unauthorized` / `APIError.tokenExpired` without a valid bearer token, `APIError.forbidden`
    ///   for non-admins, `APIError.validation` without a body, `MailError` when mail is not set up or sending fails
    ///   (mapped by `APIError.from`).
    func sendTestMail(_ input: Operations.sendTestMail.Input) async throws -> Operations.sendTestMail.Output {
        _ = try APIContext.requireAdmin()
        guard case let .json(body) = input.body else { throw APIError.validation("Ungültige Anfrage.") }
        try await APIContext.request().mail.sendTest(to: body.to)
        return .noContent(.init())
    }

    /// Never includes the password itself.
    /// - Parameter state: The stored SMTP settings.
    /// - Returns: The `MailSettings` schema.
    static func mailSettings(_ state: MailSettingsState) -> Components.Schemas.MailSettings {
        let settings = state.settings
        return .init(configured: settings != nil, unreadable: state == .unreadable, host: settings?.host, port: settings?.port,
                     encryption: settings.flatMap { Components.Schemas.MailEncryption(rawValue: $0.encryption.rawValue) },
                     username: settings?.username, hasPassword: settings?.password != nil, fromAddress: settings?.fromAddress,
                     fromName: settings?.fromName, caFile: settings?.caFile, baseUrl: settings?.baseURL)
    }
}
