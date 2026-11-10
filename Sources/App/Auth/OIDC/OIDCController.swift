import Fluent
import Foundation
import Vapor

/// `/auth/oidc/*`: start, callback and the confirmation of new accounts (spec „Ablauf“). 404 while OIDC is not set up.
struct OIDCController {
    func register(on app: Application) {
        let sessioned = app.grouped(User.sessionAuthenticator()).grouped("auth", "oidc")
        sessioned.get("start", use: start)
        sessioned.get("callback", use: callback)
        sessioned.get("new-account", use: newAccountPage)
        sessioned.post("new-account", use: createAccount)
        sessioned.get("cancel", use: cancel)
    }

    struct NewAccountInput: Content { var username: String }

    static let expiredMessage = "Anmeldung abgelaufen – bitte erneut versuchen."
    static let invalidLinkMessage = "Der Verknüpfungslink ist ungültig oder abgelaufen – bitte den Admin um einen neuen bitten."
    /// Session key for intents only a signed-in user can start (`link`, `reauth`); never taken from the URL.
    static let intentKey = "oidc.intent"
    /// Session key: when the provider last confirmed the signed-in account (seconds since 1970).
    static let verifiedAtKey = "oidc.verifiedAt"
    static let reauthWindow: TimeInterval = 300

    /// The provider confirmed the account within the last five minutes.
    static func isFresh(verifiedAt: String?, now: Date) -> Bool {
        guard let value = verifiedAt.flatMap(Double.init) else { return false }
        let age = now.timeIntervalSince1970 - value
        return age <= reauthWindow && age >= -60
    }

    // MARK: - Start

    func start(req: Request) async throws -> Response {
        let (oidc, provider) = try configured(req)
        guard isCanonical(req, oidc) else {
            return req.redirect(to: oidc.canonicalOrigin + req.url.string, redirectType: .normal)
        }
        let returnTo = (try? req.query.get(String.self, at: "returnTo")).flatMap { isSafeReturnTo($0) ? $0 : nil }
        let verifier = Self.randomToken()
        var intent = OIDCIntent.login
        if req.auth.has(User.self), req.hasSession, let raw = req.session.data[Self.intentKey] {
            req.session.data[Self.intentKey] = nil
            if let stored = OIDCIntent(rawValue: raw), stored == .link || stored == .reauth { intent = stored }
        }
        var linkToken: String?
        if let token = try? req.query.get(String.self, at: "link") {
            guard try await OIDCLinkTokenService(db: req.db).check(token) != nil else {
                return try await page(req, status: .badRequest, error: Self.invalidLinkMessage)
            }
            intent = .linkToken
            linkToken = token
        }
        var inviteToken: String?
        if let token = try? req.query.get(String.self, at: "invite") {
            if let problem = try await Self.inviteProblem(req, token) {
                return try await page(req, status: .badRequest, error: problem.message)
            }
            intent = .invite
            inviteToken = token
        }
        let flow = OIDCFlowCookie(state: Self.randomToken(), nonce: Self.randomToken(), verifier: verifier, startedAt: .now,
                                  intent: intent, returnTo: returnTo, linkToken: linkToken, inviteToken: inviteToken)
        let url: URL
        do {
            url = try await provider.authorizationURL(state: flow.state, nonce: flow.nonce, codeChallenge: pkceChallenge(verifier))
        } catch let error as OIDCError {
            return try await failure(req, error, returnTo: returnTo)
        }
        let response = req.redirect(to: url.absoluteString, redirectType: .normal)
        response.cookies[OIDCFlowCookie.name] = try flow.cookie(req.application.tokenCipher, secure: oidc.redirectURL.scheme == "https")
        return response
    }

    // MARK: - Callback

    func callback(req: Request) async throws -> Response {
        let (oidc, provider) = try configured(req)
        let cipher = req.application.tokenCipher
        guard let flow = OIDCFlowCookie.open(req.cookies[OIDCFlowCookie.name]?.string, cipher: cipher, now: .now),
              let state = try? req.query.get(String.self, at: "state"), state == flow.state,
              await req.application.oidcUsedStates.consume(flow.state) else {
            return try await page(req, status: .badRequest, error: Self.expiredMessage)
        }
        if let error = try? req.query.get(String.self, at: "error") {
            req.logger.notice("OIDC: Provider meldet \(error.prefix(40))")
            return try await failure(req, error == "access_denied" ? .denied : .failed(logReason: "Provider-Fehler"),
                                     returnTo: flow.returnTo)
        }
        guard let code = try? req.query.get(String.self, at: "code"), !code.isEmpty else {
            return try await page(req, status: .badRequest, error: Self.expiredMessage)
        }
        let identity: OIDCIdentity
        do {
            identity = try await provider.exchange(code: code, codeVerifier: flow.verifier, nonce: flow.nonce)
        } catch let error as OIDCError {
            return try await failure(req, error, returnTo: flow.returnTo)
        }
        let service = try req.oidcLogin
        if flow.intent == .linkToken, let token = flow.linkToken {
            let tokens = OIDCLinkTokenService(db: req.db)
            guard let record = try await tokens.check(token), let user = try await User.find(record.$user.id, on: req.db) else {
                return try await page(req, status: .badRequest, error: Self.invalidLinkMessage)
            }
            do {
                try await service.link(user, to: identity)
            } catch let error as APIError where error.status == .unprocessableEntity {
                return try await page(req, status: .unprocessableEntity, error: error.message)
            }
            _ = try await tokens.consume(token)
            return signIn(req, user, redirect: "/account?sso=linked")
        }
        if flow.intent == .invite, let token = flow.inviteToken {
            if let problem = try await Self.inviteProblem(req, token) {
                return try await page(req, status: .badRequest, error: problem.message)
            }
            let passwordTokens = PasswordTokenService(db: req.db)
            guard case .success(let record) = try await passwordTokens.check(token),
                  let user = try await User.find(record.$user.id, on: req.db) else {
                return try await page(req, status: .badRequest, error: PasswordLinkProblem.invalid.message)
            }
            do {
                try await service.link(user, to: identity)
            } catch let error as APIError where error.status == .unprocessableEntity {
                return try await page(req, status: .unprocessableEntity, error: error.message)
            }
            try await passwordTokens.deleteAll(userID: user.requireID())
            try await service.syncEmail(user, from: identity)
            return signIn(req, user, redirect: "/account?welcome=1")
        }
        if flow.intent == .reauth, let user = req.auth.get(User.self) {
            guard let owner = try await service.account(for: identity), owner.id == user.id else {
                return try await page(req, status: .forbidden, error: "Bei \(oidc.displayName) ist ein anderes Konto angemeldet.")
            }
            try await service.syncEmail(user, from: identity)
            req.session.data[Self.verifiedAtKey] = String(Date.now.timeIntervalSince1970)
            let response = req.redirect(to: flow.returnTo ?? "/", redirectType: .normal)
            response.cookies[OIDCFlowCookie.name] = OIDCFlowCookie.expired
            return response
        }
        if flow.intent == .link, let user = req.auth.get(User.self) {
            let response: Response
            do {
                try await service.link(user, to: identity)
                response = req.redirect(to: "/account?sso=linked", redirectType: .normal)
            } catch let error as APIError where error.status == .unprocessableEntity {
                response = req.redirect(to: "/account?sso=taken", redirectType: .normal)
            }
            response.cookies[OIDCFlowCookie.name] = OIDCFlowCookie.expired
            return response
        }
        if let user = try await service.account(for: identity) {
            try await service.syncEmail(user, from: identity)
            return signIn(req, user, redirect: flow.returnTo ?? "/")
        }
        var parked = flow
        parked.pending = identity
        parked.pendingAt = .now
        let response = req.redirect(to: "/auth/oidc/new-account", redirectType: .normal)
        response.cookies[OIDCFlowCookie.name] = try parked.cookie(cipher, secure: oidc.redirectURL.scheme == "https")
        return response
    }

    // MARK: - New account

    /// The parked identity, if the cookie is still valid.
    private func parked(_ req: Request) -> (OIDCFlowCookie, OIDCIdentity)? {
        guard let flow = OIDCFlowCookie.open(req.cookies[OIDCFlowCookie.name]?.string, cipher: req.application.tokenCipher, now: .now),
              let identity = flow.pending else { return nil }
        return (flow, identity)
    }

    func newAccountPage(req: Request) async throws -> Response {
        let (oidc, _) = try configured(req)
        guard let (_, identity) = parked(req) else { return try await page(req, status: .badRequest, error: Self.expiredMessage) }
        var username = OIDCLoginService.suggestUsername(identity) ?? ""
        var taken: String?
        if !username.isEmpty, try await User.query(on: req.db).filter(\.$username == username).first() != nil {
            taken = username
            username = ""
        }
        return try await HTMLResponse(NewAccountPage(ssoName: oidc.displayName, passwordLogin: req.application.loginSettings.current.passwordLogin,
                                                     username: username, takenSuggestion: taken)).encodeResponse(for: req)
    }

    func createAccount(req: Request) async throws -> Response {
        let (oidc, _) = try configured(req)
        guard let (flow, identity) = parked(req) else { return try await page(req, status: .badRequest, error: Self.expiredMessage) }
        let input = try req.content.decode(NewAccountInput.self)
        let user: User
        do {
            user = try await req.oidcLogin.createAccount(identity, username: input.username)
        } catch let error as APIError {
            return try await HTMLResponse(status: error.status,
                                          NewAccountPage(ssoName: oidc.displayName, passwordLogin: req.application.loginSettings.current.passwordLogin,
                                                         username: input.username, error: error.message)).encodeResponse(for: req)
        }
        return signIn(req, user, redirect: flow.returnTo ?? "/account?welcome=1")
    }

    func cancel(req: Request) async throws -> Response {
        let response = req.redirect(to: "/login", redirectType: .normal)
        response.cookies[OIDCFlowCookie.name] = OIDCFlowCookie.expired
        return response
    }

    // MARK: - Helpers

    /// Why an invitation token cannot be used through the provider (only invitations, not reset links).
    static func inviteProblem(_ req: Request, _ token: String) async throws -> PasswordLinkProblem? {
        switch try await PasswordTokenService(db: req.db).check(token) {
        case .success(let record): return record.tokenPurpose == .invite ? nil : .invalid
        case .failure(let problem): return problem
        }
    }

    private func configured(_ req: Request) throws -> (OIDCConfig, any OIDCProvider) {
        guard let oidc = req.application.loginSettings.current.oidc else { throw Abort(.notFound) }
        return (oidc, req.application.oidcProviders.provider(for: oidc))
    }

    /// Signs in like the password login and ends the flow cookie.
    func signIn(_ req: Request, _ user: User, redirect: String) -> Response {
        req.auth.login(user)
        req.session.authenticate(user)
        let response = req.redirect(to: redirect, redirectType: .normal)
        response.cookies[OIDCFlowCookie.name] = OIDCFlowCookie.expired
        return response
    }

    private func failure(_ req: Request, _ error: OIDCError, returnTo: String?) async throws -> Response {
        req.logger.warning("OIDC-Anmeldung fehlgeschlagen: \(error.logDescription)")
        let name = req.application.loginSettings.current.oidc?.displayName ?? "SSO"
        return try await page(req, status: Self.status(for: error), error: error.message(name: name), returnTo: returnTo)
    }

    /// The login page with an error; the flow cookie is cleared.
    func page(_ req: Request, status: HTTPStatus, error: String, returnTo: String? = nil) async throws -> Response {
        let response = try await AuthController.loginResponse(req, status: status, error: error, returnTo: returnTo)
        response.cookies[OIDCFlowCookie.name] = OIDCFlowCookie.expired
        return response
    }

    static func status(for error: OIDCError) -> HTTPStatus {
        switch error {
        case .unreachable, .misconfigured, .symmetricSigning: .serviceUnavailable
        case .denied: .forbidden
        case .failed, .unknownKey: .badRequest
        }
    }

    /// 32 random bytes, Base64URL (43 characters).
    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }
}

/// True when the request reached WatchSwifty under the canonical address of the OIDC flows.
func isCanonical(_ req: Request, _ oidc: OIDCConfig) -> Bool {
    OriginCheckMiddleware.requestMatches(origin: oidc.canonicalOrigin, req)
}
