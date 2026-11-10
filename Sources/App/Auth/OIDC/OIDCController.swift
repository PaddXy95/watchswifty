import Fluent
import Foundation
import Vapor

/// `/auth/oidc/*`: start, callback and the confirmation of new accounts (spec „Ablauf“). Registered only with OIDC.
struct OIDCController {
    func register(on app: Application) {
        guard app.appConfig.oidc != nil else { return }
        let sessioned = app.grouped(User.sessionAuthenticator()).grouped("auth", "oidc")
        sessioned.get("start", use: start)
        sessioned.get("callback", use: callback)
    }

    static let expiredMessage = "Anmeldung abgelaufen – bitte erneut versuchen."

    // MARK: - Start

    func start(req: Request) async throws -> Response {
        let (oidc, provider) = try configured(req)
        guard isCanonical(req, oidc) else {
            return req.redirect(to: oidc.canonicalOrigin + req.url.string, redirectType: .normal)
        }
        let returnTo = (try? req.query.get(String.self, at: "returnTo")).flatMap { isSafeReturnTo($0) ? $0 : nil }
        let verifier = Self.randomToken()
        let flow = OIDCFlowCookie(state: Self.randomToken(), nonce: Self.randomToken(), verifier: verifier, startedAt: .now,
                                  intent: .login, returnTo: returnTo)
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
        if let user = try await service.account(for: identity) {
            return signIn(req, user, redirect: flow.returnTo ?? "/")
        }
        var parked = flow
        parked.pending = identity
        parked.pendingAt = .now
        let response = req.redirect(to: "/auth/oidc/new-account", redirectType: .normal)
        response.cookies[OIDCFlowCookie.name] = try parked.cookie(cipher, secure: oidc.redirectURL.scheme == "https")
        return response
    }

    // MARK: - Helpers

    private func configured(_ req: Request) throws -> (OIDCConfig, any OIDCProvider) {
        guard let oidc = req.application.appConfig.oidc, let provider = req.application.oidcProvider else { throw Abort(.notFound) }
        return (oidc, provider)
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
        let name = req.application.appConfig.oidc?.displayName ?? "SSO"
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
