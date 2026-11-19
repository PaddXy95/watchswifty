import Fluent
import Vapor

struct AdminUsersController {
    struct CreateInput: Content { var username: String; var password: String?; var email: String?; var isAdmin: Bool? }
    struct PasswordInput: Content { var password: String }
    struct AdminInput: Content { var isAdmin: Bool? }

    func register(on protected: any RoutesBuilder) {
        let admin = protected.grouped(RequireAdminMiddleware()).grouped("admin", "users")
        admin.get(use: list)
        admin.post(use: create)
        admin.post("confirm", use: confirm)
        admin.post("confirm-sso", use: confirmSSO)
        admin.post(":userID", "password", use: resetPassword)
        admin.post(":userID", "invite", use: resendInvite)
        admin.post(":userID", "sso-link", use: createSSOLink)
        admin.post(":userID", "admin", use: setAdmin)
        admin.delete(":userID", use: delete)
    }

    func list(req: Request) async throws -> HTMLResponse {
        try await page(req, status: .ok)
    }

    func create(req: Request) async throws -> Response {
        let input = try req.content.decode(CreateInput.self)
        let created: (user: User, inviteMailError: String?)
        do {
            created = try await req.userAdmin.create(username: input.username, password: input.password, email: input.email,
                                                     isAdmin: input.isAdmin ?? false, inviter: try req.currentUser,
                                                     confirmation: Self.confirmation(req))
        } catch let error as APIError {
            return try await page(req, status: error.status, error: error.message).encodeResponse(for: req)
        }
        guard !created.user.hasPassword else { return req.redirect(to: "/admin/users", redirectType: .normal) }
        if let mailError = created.inviteMailError {
            return try await page(req, status: .serviceUnavailable,   // not 502: Cloudflare would hide this page
                                  error: "Konto angelegt, aber die Einladung konnte nicht gesendet werden: \(mailError)").encodeResponse(for: req)
        }
        return try await page(req, status: .ok, notice: Self.sentNotice(created.user, req)).encodeResponse(for: req)
    }

    func resendInvite(req: Request) async throws -> HTMLResponse {
        let user: User
        do {
            user = try await req.userAdmin.resendInvite(id: try targetID(req), inviter: try req.currentUser)
        } catch let error as APIError where error.status != .notFound {
            return try await page(req, status: error.status, error: error.message)
        } catch let error as MailError {
            let apiError = APIError.from(error)
            return try await page(req, status: apiError.status, error: apiError.message)
        }
        return try await page(req, status: .ok, notice: Self.sentNotice(user, req))
    }

    func createSSOLink(req: Request) async throws -> HTMLResponse {
        let result: SSOLinkResult
        let id = try targetID(req)
        do {
            result = try await req.userAdmin.createSSOLink(id: id, inviter: try req.currentUser, confirmation: Self.confirmation(req))
        } catch let error as APIError where error.status != .notFound {
            return try await page(req, status: error.status, error: error.message)
        }
        if result.mailed {
            return try await page(req, status: .ok, notice: "Verknüpfungslink an \(result.emailHint ?? "") gesendet.")
        }
        let username = try await User.find(id, on: req.db)?.username ?? ""
        return try await page(req, status: .ok, error: result.mailError.map { "Die Mail ging nicht raus: \($0)" },
                              ssoLink: AdminSSOLink(username: username, url: result.url ?? ""))
    }

    private static func sentNotice(_ user: User, _ req: Request) -> String {
        let hint = user.emailState(req.application.tokenCipher).address.map(EmailAddress.mask) ?? ""
        return "Einladung an \(hint) gesendet."
    }

    func resetPassword(req: Request) async throws -> Response {
        guard req.application.loginSettings.current.passwordLogin else { throw Abort(.notFound) }
        let input = try req.content.decode(PasswordInput.self)
        do {
            try await req.userAdmin.resetPassword(id: try targetID(req), password: input.password, actingUserID: try req.userID,
                                                  confirmation: Self.confirmation(req))
        } catch let error as APIError where error.status != .notFound {
            return try await page(req, status: error.status, error: error.message).encodeResponse(for: req)
        }
        return req.redirect(to: "/admin/users", redirectType: .normal)
    }

    func setAdmin(req: Request) async throws -> Response {
        let makeAdmin = try req.content.decode(AdminInput.self).isAdmin ?? false
        do {
            try await req.userAdmin.setAdmin(id: try targetID(req), isAdmin: makeAdmin, actingUserID: try req.userID,
                                             confirmation: Self.confirmation(req))
        } catch let error as APIError where error.status != .notFound {
            return try await page(req, status: error.status, error: error.message).encodeResponse(for: req)
        }
        return req.redirect(to: "/admin/users", redirectType: .normal)
    }

    // MARK: Confirmation (security audit F10)

    /// Confirmed with the password here, or through the provider, within the last five minutes.
    static func confirmation(_ req: Request) -> AdminConfirmation {
        let now = Date.now
        return .recent(OIDCController.isFresh(verifiedAt: req.session.data[AdminConfirmation.sessionKey], now: now)
            || OIDCController.isFresh(verifiedAt: req.session.data[OIDCController.verifiedAtKey], now: now))
    }

    /// Accounts that sign in through the provider confirm there instead of with a password.
    private static func confirmsWithSSO(_ req: Request) throws -> Bool {
        let login = req.application.loginSettings.current
        return try req.currentUser.isSSOAccount(login.oidc, passwordLogin: login.passwordLogin)
    }

    func confirm(req: Request) async throws -> Response {
        let user = try req.currentUser
        guard try !Self.confirmsWithSSO(req), user.hasPassword else { throw Abort(.notFound) }
        let input = try req.content.decode(PasswordInput.self)
        guard try await req.password.async.verify(input.password, created: user.passwordHash) else {
            return try await page(req, status: .forbidden, error: AccountValidation.wrongCurrentPasswordMessage).encodeResponse(for: req)
        }
        req.session.data[AdminConfirmation.sessionKey] = String(Date.now.timeIntervalSince1970)
        return req.redirect(to: "/admin/users", redirectType: .normal)
    }

    /// „Über … bestätigen“: a fresh sign-in at the provider, which returns to this page.
    func confirmSSO(req: Request) async throws -> Response {
        guard try Self.confirmsWithSSO(req) else { throw Abort(.notFound) }
        req.session.data[OIDCController.intentKey] = OIDCIntent.reauth.rawValue
        req.session.data[OIDCController.returnToKey] = "/admin/users"
        return req.redirect(to: "/auth/oidc/start", redirectType: .normal)
    }

    func delete(req: Request) async throws -> HTMLResponse {
        do {
            try await req.userAdmin.delete(id: try targetID(req), actingUserID: try req.userID)
        } catch let error as APIError where error.status != .notFound {
            return try await page(req, status: error.status, error: error.message)
        }
        return try await page(req, status: .ok, notice: "Konto gelöscht.")
    }

    private func targetID(_ req: Request) throws -> UUID {
        guard let id = req.parameters.get("userID", as: UUID.self) else { throw Abort(.notFound) }
        return id
    }

    private func page(_ req: Request, status: HTTPStatus, error: String? = nil, notice: String? = nil,
                      ssoLink: AdminSSOLink? = nil) async throws -> HTMLResponse {
        let users = try await req.userAdmin.list()
        let mailConfigured = try await req.mailSettings.state().settings != nil
        let config = req.application.loginSettings.current
        var readiness: OIDCReadiness?
        if let oidc = config.oidc { readiness = try await OIDCLoginService.readiness(db: req.db, oidc: oidc) }
        var confirm: AdminConfirmBox?
        if case .recent(false) = Self.confirmation(req) {
            confirm = try Self.confirmsWithSSO(req) ? .sso(config.oidc?.displayName ?? "SSO") : .password
        }
        return HTMLResponse(status: status, AdminUsersPage(nav: try req.nav(.admin), users: users, mailConfigured: mailConfigured,
                                                           currentUserID: try req.userID, error: error, notice: notice,
                                                           ssoName: config.oidc?.displayName, ssoLink: ssoLink, readiness: readiness,
                                                           passwordLogin: config.passwordLogin, confirm: confirm))
    }
}
