import Fluent
import Foundation
import Vapor

/// `/auth/oidc/*`: start, callback and the confirmation of new accounts (spec „Ablauf“). 404 while OIDC is not set up.
struct OIDCController {
    /// Registers the `/auth/oidc/*` routes behind the session authenticator.
    /// - Parameter app: The application.
    func register(on app: Application) {
        let sessioned = app.grouped(User.sessionAuthenticator()).grouped("auth", "oidc")
        sessioned.get("start", use: start)
        sessioned.get("callback", use: callback)
        sessioned.get("new-account", use: newAccountPage)
        sessioned.post("new-account", use: createAccount)
        sessioned.get("link", use: linkConfirmPage)
        sessioned.post("link", use: confirmLink)
        sessioned.get("cancel", use: cancel)
    }

    /// Form field of `POST /auth/oidc/new-account`.
    struct NewAccountInput: Content { var username: String }

    static let expiredMessage = "Anmeldung abgelaufen – bitte erneut versuchen."
    static let invalidLinkMessage = "Der Verknüpfungslink ist ungültig oder abgelaufen – bitte den Admin um einen neuen bitten."
    static let otherAccountMessage = "In diesem Browser ist ein anderes Konto angemeldet – bitte erst abmelden und den Link dann erneut öffnen."
    /// Session key for intents only a signed-in user can start (`link`, `reauth`); never taken from the URL.
    static let intentKey = "oidc.intent"
    /// Session key: state of the `link`/`reauth` flow this session started (binds the flow cookie to the session).
    static let flowStateKey = "oidc.flowState"
    /// Session key: where a server-started re-check returns to (set by the server, never from the URL).
    static let returnToKey = "oidc.returnTo"
    /// Session key: when the provider last confirmed the signed-in account (seconds since 1970).
    static let verifiedAtKey = "oidc.verifiedAt"
    /// How long a confirmation by the provider counts as fresh (five minutes).
    static let reauthWindow: TimeInterval = 300

    /// The provider confirmed the account within the last five minutes.
    /// - Parameters:
    ///   - verifiedAt: The `verifiedAtKey` session value, if any.
    ///   - now: The reference time; up to a minute in the future is tolerated.
    /// - Returns: `true` while the confirmation is at most `reauthWindow` old.
    static func isFresh(verifiedAt: String?, now: Date) -> Bool {
        guard let value = verifiedAt.flatMap(Double.init) else { return false }
        let age = now.timeIntervalSince1970 - value
        return age <= reauthWindow && age >= -60
    }

    // MARK: - Start

    /// `GET /auth/oidc/start`: starts a sign-in at the provider and redirects the browser to its authorization endpoint.
    ///
    /// Requests to another address are first redirected to the canonical origin. The intent comes from the session for
    /// `link`/`reauth` (never from the URL), from a valid `link` token or `invite` token in the query, else it is `login`.
    /// For `link`/`reauth` the flow is bound to the signed-in user and the session. State, nonce and PKCE verifier go
    /// into the sealed flow cookie.
    /// - Parameter req: The request, optionally with `returnTo`, `link` or `invite` query parameters.
    /// - Returns: The redirect to the provider, or the login page with an error.
    /// - Throws: `Abort(.notFound)` while OIDC is not configured; database or encryption errors.
    func start(req: Request) async throws -> Response {
        let (oidc, provider) = try configured(req)
        if let redirect = canonicalRedirect(req, oidc) { return redirect }
        var returnTo = (try? req.query.get(String.self, at: "returnTo")).flatMap { isSafeReturnTo($0) ? $0 : nil }
        let verifier = Self.randomToken()
        var intent = OIDCIntent.login
        if req.auth.has(User.self), req.hasSession, let raw = req.session.data[Self.intentKey] {
            req.session.data[Self.intentKey] = nil
            if let stored = OIDCIntent(rawValue: raw), stored == .link || stored == .reauth { intent = stored }
            if let serverReturnTo = req.session.data[Self.returnToKey] {
                req.session.data[Self.returnToKey] = nil
                if intent == .reauth { returnTo = serverReturnTo }
            }
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
        var flow = OIDCFlowCookie(state: Self.randomToken(), nonce: Self.randomToken(), verifier: verifier, startedAt: .now,
                                  intent: intent, returnTo: returnTo, linkToken: linkToken, inviteToken: inviteToken)
        if intent == .link || intent == .reauth {
            // The sealed cookie alone could be planted in another browser: remember who started the flow, here and there.
            flow.userID = try req.auth.get(User.self)?.requireID()
            req.session.data[Self.flowStateKey] = flow.state
        }
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

    /// `GET /auth/oidc/callback`: finishes the sign-in according to the flow's intent.
    ///
    /// The flow cookie must be valid, its `state` must match the query and may be used only once; `link`/`reauth` flows
    /// must come back to the session and user that started them. After the code exchange: `linkToken` parks the
    /// identity for confirmation, `invite` links the invited account and signs it in, `reauth` records the confirmation
    /// time, `link` links the signed-in account, and `login` signs in the linked account or parks the identity for
    /// „Neues Konto anlegen“ (create new account).
    /// - Parameter req: The request with `state` and `code` (or `error`) from the provider.
    /// - Returns: A redirect, or the login page with an error.
    /// - Throws: `Abort(.notFound)` while OIDC is not configured; database or encryption errors.
    func callback(req: Request) async throws -> Response {
        let (oidc, provider) = try configured(req)
        let cipher = req.application.tokenCipher
        guard let flow = OIDCFlowCookie.open(req.cookies[OIDCFlowCookie.name]?.string, cipher: cipher, now: .now),
              let state = try? req.query.get(String.self, at: "state"), state == flow.state,
              await req.application.oidcUsedStates.consume(flow.state) else {
            return try await page(req, status: .badRequest, error: Self.expiredMessage)
        }
        if flow.intent == .link || flow.intent == .reauth {
            // Only the session that started the flow may finish it.
            let bound = req.hasSession ? req.session.data[Self.flowStateKey] : nil
            if req.hasSession { req.session.data[Self.flowStateKey] = nil }
            guard let user = req.auth.get(User.self), let starter = flow.userID, user.id == starter, bound == flow.state else {
                return try await page(req, status: .badRequest, error: Self.expiredMessage)
            }
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
            // Never bind silently: park the identity and let the visitor confirm the target account first.
            if let problem = try await linkTokenProblem(req, token) { return problem }
            var parked = flow
            parked.pending = identity
            parked.pendingAt = .now
            let response = req.redirect(to: "/auth/oidc/link", redirectType: .normal)
            response.cookies[OIDCFlowCookie.name] = try parked.cookie(cipher, secure: oidc.redirectURL.scheme == "https")
            return response
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
            try await OIDCLinkTokenService(db: req.db).deleteAll(userID: user.requireID())
            try await service.syncEmail(user, from: identity)
            return try await signIn(req, user, redirect: "/account?welcome=1")
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
            return try await signIn(req, user, redirect: flow.returnTo ?? "/")
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
    /// - Parameter req: The request carrying the flow cookie.
    /// - Returns: The flow and its parked identity, or `nil`.
    private func parked(_ req: Request) -> (OIDCFlowCookie, OIDCIdentity)? {
        guard let flow = OIDCFlowCookie.open(req.cookies[OIDCFlowCookie.name]?.string, cipher: req.application.tokenCipher, now: .now),
              let identity = flow.pending else { return nil }
        return (flow, identity)
    }

    /// `GET /auth/oidc/new-account`: renders the confirmation page for a new account with a suggested username (left
    /// empty, and named as taken, when it already exists).
    /// - Parameter req: The request carrying the flow cookie with the parked identity.
    /// - Returns: The page, or the login page with „Anmeldung abgelaufen“ (sign-in expired).
    /// - Throws: `Abort(.notFound)` while OIDC is not configured; database or rendering errors.
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

    /// `POST /auth/oidc/new-account`: creates the linked account for the parked identity and signs it in.
    /// - Parameter req: The request with the chosen username and the flow cookie.
    /// - Returns: A redirect to the flow's `returnTo` or `/account?welcome=1`, the page again with a validation error,
    ///   or the login page when the flow expired.
    /// - Throws: `Abort(.notFound)` while OIDC is not configured; decoding or database errors.
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
        return try await signIn(req, user, redirect: flow.returnTo ?? "/account?welcome=1")
    }

    // MARK: - Link token confirmation

    /// Either a value or the error page to answer with.
    ///
    /// Lets the link-token helpers return the response to send instead of throwing.
    private enum Checked<Value> {
        /// The checked value.
        case ok(Value)
        /// The error page to answer with.
        case page(Response)
    }

    /// The account a link token belongs to, or the error page when the token is unusable or another account is
    /// signed in to this browser.
    /// - Parameters:
    ///   - req: The request.
    ///   - token: The link token.
    /// - Returns: The target account, or the error page (400 for an unusable token, 403 for another signed-in account).
    /// - Throws: Database or rendering errors.
    private func linkTokenTarget(_ req: Request, _ token: String) async throws -> Checked<User> {
        guard let record = try await OIDCLinkTokenService(db: req.db).check(token),
              let user = try await User.find(record.$user.id, on: req.db) else {
            return .page(try await page(req, status: .badRequest, error: Self.invalidLinkMessage))
        }
        if let signedIn = req.auth.get(User.self), signedIn.id != user.id {
            return .page(try await page(req, status: .forbidden, error: Self.otherAccountMessage))
        }
        return .ok(user)
    }

    /// The error page when the link token cannot be used here, as checked by `linkTokenTarget`.
    /// - Parameters:
    ///   - req: The request.
    ///   - token: The link token.
    /// - Returns: The error page, or `nil` when the token is usable.
    /// - Throws: Database or rendering errors.
    private func linkTokenProblem(_ req: Request, _ token: String) async throws -> Response? {
        if case .page(let response) = try await linkTokenTarget(req, token) { return response }
        return nil
    }

    /// The parked link-token flow and its target account.
    /// - Parameter req: The request carrying the flow cookie.
    /// - Returns: Flow, identity and target account, or the error page when the flow expired or the token is unusable.
    /// - Throws: Database or rendering errors.
    private func parkedLink(_ req: Request) async throws -> Checked<(OIDCFlowCookie, OIDCIdentity, User)> {
        guard let (flow, identity) = parked(req), flow.intent == .linkToken, let token = flow.linkToken else {
            return .page(try await page(req, status: .badRequest, error: Self.expiredMessage))
        }
        switch try await linkTokenTarget(req, token) {
        case .ok(let user): return .ok((flow, identity, user))
        case .page(let response): return .page(response)
        }
    }

    /// `GET /auth/oidc/link`: asks the visitor to confirm linking the parked identity with the link token's account.
    /// - Parameter req: The request carrying the flow cookie.
    /// - Returns: The confirmation page, or an error page.
    /// - Throws: `Abort(.notFound)` while OIDC is not configured; database or rendering errors.
    func linkConfirmPage(req: Request) async throws -> Response {
        let (oidc, _) = try configured(req)
        switch try await parkedLink(req) {
        case .page(let response): return response
        case .ok(let (_, identity, user)):
            return try await HTMLResponse(LinkConfirmPage(ssoName: oidc.displayName, username: user.username, identity: identity))
                .encodeResponse(for: req)
        }
    }

    /// `POST /auth/oidc/link`: links the parked identity with the link token's account, uses the token up, ends the
    /// account's password links and signs it in.
    /// - Parameter req: The request carrying the flow cookie.
    /// - Returns: A redirect to `/account?sso=linked`, or an error page (422 when the identity is already taken).
    /// - Throws: `Abort(.notFound)` while OIDC is not configured; database errors.
    func confirmLink(req: Request) async throws -> Response {
        _ = try configured(req)
        switch try await parkedLink(req) {
        case .page(let response): return response
        case .ok(let (flow, identity, user)):
            do {
                try await req.oidcLogin.link(user, to: identity)
            } catch let error as APIError where error.status == .unprocessableEntity {
                return try await page(req, status: .unprocessableEntity, error: error.message)
            }
            if let token = flow.linkToken { _ = try await OIDCLinkTokenService(db: req.db).consume(token) }
            try await PasswordTokenService(db: req.db).deleteAll(userID: user.requireID())
            return try await signIn(req, user, redirect: "/account?sso=linked")
        }
    }

    /// `GET /auth/oidc/cancel`: drops the flow cookie and redirects to `/login`.
    /// - Parameter req: The request.
    /// - Returns: The redirect.
    func cancel(req: Request) async throws -> Response {
        let response = req.redirect(to: "/login", redirectType: .normal)
        response.cookies[OIDCFlowCookie.name] = OIDCFlowCookie.expired
        return response
    }

    // MARK: - Helpers

    /// Why an invitation token cannot be used through the provider (only invitations, not reset links).
    /// - Parameters:
    ///   - req: The request.
    ///   - token: The invitation token.
    /// - Returns: The problem, or `nil` when the token is a usable invitation.
    /// - Throws: Database errors.
    static func inviteProblem(_ req: Request, _ token: String) async throws -> PasswordLinkProblem? {
        switch try await PasswordTokenService(db: req.db).check(token) {
        case .success(let record): return record.tokenPurpose == .invite ? nil : .invalid
        case .failure(let problem): return problem
        }
    }

    /// The provider config in effect and its client.
    /// - Parameter req: The request.
    /// - Returns: Config and provider client.
    /// - Throws: `Abort(.notFound)` while OIDC is not configured.
    private func configured(_ req: Request) throws -> (OIDCConfig, any OIDCProvider) {
        guard let oidc = req.application.loginSettings.current.oidc else { throw Abort(.notFound) }
        return (oidc, req.application.oidcProviders.provider(for: oidc))
    }

    /// Signs in like the password login (new session ID) and ends the flow cookie.
    /// - Parameters:
    ///   - req: The request.
    ///   - user: The account to sign in.
    ///   - redirect: Where to send the browser afterwards.
    /// - Returns: The redirect response.
    /// - Throws: Errors from deleting the old session.
    func signIn(_ req: Request, _ user: User, redirect: String) async throws -> Response {
        try await req.signInWithNewSession(user)
        let response = req.redirect(to: redirect, redirectType: .normal)
        response.cookies[OIDCFlowCookie.name] = OIDCFlowCookie.expired
        return response
    }

    /// Logs an OIDC error and renders the login page with its German message and matching status.
    /// - Parameters:
    ///   - req: The request.
    ///   - error: The error.
    ///   - returnTo: The return path to keep in the login form.
    /// - Returns: The login page.
    /// - Throws: Errors reading the mail settings or rendering.
    private func failure(_ req: Request, _ error: OIDCError, returnTo: String?) async throws -> Response {
        req.logger.warning("OIDC-Anmeldung fehlgeschlagen: \(error.logDescription)")
        let name = req.application.loginSettings.current.oidc?.displayName ?? "SSO"
        return try await page(req, status: Self.status(for: error), error: error.message(name: name), returnTo: returnTo)
    }

    /// The login page with an error; the flow cookie is cleared.
    /// - Parameters:
    ///   - req: The request.
    ///   - status: The HTTP status.
    ///   - error: The German error message.
    ///   - returnTo: The return path to keep in the login form.
    /// - Returns: The login page.
    /// - Throws: Errors reading the mail settings or rendering.
    func page(_ req: Request, status: HTTPStatus, error: String, returnTo: String? = nil) async throws -> Response {
        let response = try await AuthController.loginResponse(req, status: status, error: error, returnTo: returnTo)
        response.cookies[OIDCFlowCookie.name] = OIDCFlowCookie.expired
        return response
    }

    /// The HTTP status for an OIDC error page.
    /// - Parameter error: The error.
    /// - Returns: 503 for provider problems, 403 for a denial, 400 for failed checks.
    static func status(for error: OIDCError) -> HTTPStatus {
        switch error {
        case .unreachable, .misconfigured, .symmetricSigning: .serviceUnavailable
        case .denied: .forbidden
        case .failed, .unknownKey: .badRequest
        }
    }

    /// 32 random bytes, Base64URL (43 characters).
    /// - Returns: A new token from the system's secure random generator.
    static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }
}

/// True when the request reached WatchSwifty under the canonical address of the OIDC flows.
/// - Parameters:
///   - req: The request.
///   - oidc: The provider config with the canonical origin.
/// - Returns: `true` when the request's host matches the redirect URL's origin.
func isCanonical(_ req: Request, _ oidc: OIDCConfig) -> Bool {
    OriginCheckMiddleware.requestMatches(origin: oidc.canonicalOrigin, req)
}

/// Marks a redirect to the canonical address, so a proxy that does not forward the browser's Host cannot cause a loop.
let canonicalMarker = "oidc_c"

/// Redirect of a GET to the same path on the canonical address; nil when already there – or when this request already
/// came from such a redirect (the proxy rewrites Host: continue and warn instead of looping).
/// - Parameters:
///   - req: The request.
///   - oidc: The provider config with the canonical origin.
/// - Returns: The redirect with the `oidc_c` marker, or `nil`.
func canonicalRedirect(_ req: Request, _ oidc: OIDCConfig) -> Response? {
    guard !isCanonical(req, oidc) else { return nil }
    if req.url.query?.split(separator: "&").contains(where: { $0.hasPrefix(canonicalMarker + "=") }) == true {
        req.logger.warning("OIDC: Die Anfrage kommt nicht mit der Adresse \(oidc.canonicalOrigin) an – der Reverse-Proxy sollte Host (inkl. Port) oder X-Forwarded-Host weitergeben.")
        return nil
    }
    let separator = req.url.query == nil ? "?" : "&"
    return req.redirect(to: oidc.canonicalOrigin + req.url.string + separator + canonicalMarker + "=1", redirectType: .normal)
}
