import Fluent
import Foundation
import Vapor

/// Browser part of the app login: the app opens `/api/auth/authorize` in a system browser sheet, the user signs in
/// (password or later Authentik) and confirms; the app receives a one-time code at `dev.patmei.watchswifty:/auth`.
struct APIAuthorizeController {
    /// The only accepted redirect URI (the iOS app's custom scheme).
    static let redirectURI = "dev.patmei.watchswifty:/auth"

    /// Query (GET) or form (POST) parameters of the consent page, named as in OAuth/PKCE.
    struct Params: Content {
        var redirect_uri: String
        var state: String
        var code_challenge: String
        var code_challenge_method: String
        var device_name: String
        /// `connect` grants the connection; anything else denies it (POST only).
        var decision: String?
    }

    /// Registers `GET` and `POST /api/auth/authorize` with session authentication (signing in is handled by the pages).
    /// - Parameter routes: The routes builder to register on.
    func register(on routes: any RoutesBuilder) {
        let sessioned = routes.grouped(User.sessionAuthenticator())
        sessioned.get("api", "auth", "authorize", use: show)
        sessioned.post("api", "auth", "authorize", use: decide)
    }

    /// Handles `GET /api/auth/authorize`: renders the consent page `AuthorizePage`.
    ///
    /// With SSO set up, anonymous visitors and SSO accounts arriving at another address are redirected to the canonical
    /// one; SSO accounts without a fresh provider check go through the provider first, anonymous visitors to `/login`
    /// with `returnTo`.
    /// - Parameter req: The incoming request.
    /// - Returns: The consent page or a redirect.
    /// - Throws: `Abort(.badRequest)` for invalid parameters (see `validated(_:)`), query decoding errors.
    func show(req: Request) async throws -> Response {
        let params = try validated(try req.query.decode(Params.self))
        let config = req.application.loginSettings.current
        if let oidc = config.oidc, req.auth.get(User.self).map({ $0.isSSOAccount(oidc, passwordLogin: config.passwordLogin) }) ?? true,
           let redirect = canonicalRedirect(req, oidc) {
            return redirect
        }
        if let reauth = reauthRedirect(req, returnTo: req.url.string) { return reauth }
        guard req.auth.has(User.self) else {
            var components = URLComponents()
            components.path = "/login"
            components.queryItems = [URLQueryItem(name: "returnTo", value: req.url.string)]
            return req.redirect(to: components.string ?? "/login", redirectType: .normal)
        }
        return try await HTMLResponse(AuthorizePage(params: params)).encodeResponse(for: req)
    }

    /// Handles `POST /api/auth/authorize`: redirects to the app with a one-time code and `state` when the user chose
    /// `connect`, otherwise with `error=access_denied`.
    ///
    /// Not signed in redirects to `/login`; SSO accounts without a fresh provider check go through the provider first.
    /// - Parameter req: The incoming request.
    /// - Returns: The redirect.
    /// - Throws: `Abort(.badRequest)` for invalid parameters, form decoding errors.
    func decide(req: Request) async throws -> Response {
        let params = try validated(try req.content.decode(Params.self))
        guard let user = req.auth.get(User.self) else { return req.redirect(to: "/login", redirectType: .normal) }
        if let reauth = reauthRedirect(req, returnTo: Self.showPath(params)) { return reauth }
        var components = URLComponents(string: Self.redirectURI)!
        if params.decision == "connect" {
            let code = await req.application.authCodes.issue(userID: try user.requireID(), challenge: params.code_challenge,
                                                             redirectURI: params.redirect_uri, deviceName: params.device_name)
            components.queryItems = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: params.state)]
        } else {
            components.queryItems = [URLQueryItem(name: "error", value: "access_denied"), URLQueryItem(name: "state", value: params.state)]
        }
        return req.redirect(to: components.string ?? Self.redirectURI, redirectType: .normal)
    }

    /// Signed-in SSO accounts go through the provider first, so an account blocked there gets no new device token
    /// (spec „App verbinden“). Nil when no detour is needed.
    /// - Parameters:
    ///   - req: The incoming request.
    ///   - returnTo: Where the provider login returns to.
    /// - Returns: The redirect to `/auth/oidc/start`, or nil.
    private func reauthRedirect(_ req: Request, returnTo: String) -> Response? {
        let config = req.application.loginSettings.current
        guard let user = req.auth.get(User.self), user.isSSOAccount(config.oidc, passwordLogin: config.passwordLogin),
              !OIDCController.isFresh(verifiedAt: req.session.data[OIDCController.verifiedAtKey], now: .now) else { return nil }
        req.session.data[OIDCController.intentKey] = OIDCIntent.reauth.rawValue
        return req.redirect(to: "/auth/oidc/start?returnTo=" + formEncode(returnTo), redirectType: .normal)
    }

    /// The GET address of the consent page for these parameters.
    /// - Parameter params: The validated parameters.
    /// - Returns: The path with its query.
    static func showPath(_ params: Params) -> String {
        var components = URLComponents()
        components.path = "/api/auth/authorize"
        components.queryItems = [
            URLQueryItem(name: "redirect_uri", value: params.redirect_uri), URLQueryItem(name: "state", value: params.state),
            URLQueryItem(name: "code_challenge", value: params.code_challenge),
            URLQueryItem(name: "code_challenge_method", value: params.code_challenge_method),
            URLQueryItem(name: "device_name", value: params.device_name),
        ]
        return components.string ?? "/api/auth/authorize"
    }

    /// Rejects anything but the app's own redirect and a proper PKCE challenge – never redirects on errors.
    /// The device name is trimmed and must have 1 to 60 characters.
    /// - Parameter input: The decoded parameters.
    /// - Returns: The parameters with the trimmed device name.
    /// - Throws: `Abort(.badRequest)` with a German reason for a foreign redirect URI, an invalid PKCE challenge or
    ///   method, an empty or overlong `state`, or an invalid device name.
    private func validated(_ input: Params) throws -> Params {
        var params = input
        params.device_name = input.device_name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard params.redirect_uri == Self.redirectURI else {
            throw Abort(.badRequest, reason: "Unbekannte Rücksprung-Adresse – nur die WatchSwifty-App kann sich so anmelden.")
        }
        let challengeChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard params.code_challenge_method == "S256", (43...128).contains(params.code_challenge.count),
              params.code_challenge.unicodeScalars.allSatisfy(challengeChars.contains) else {
            throw Abort(.badRequest, reason: "Ungültige Anmeldeanfrage der App (PKCE).")
        }
        guard !params.state.isEmpty, params.state.count <= 200 else { throw Abort(.badRequest, reason: "Ungültige Anmeldeanfrage der App.") }
        guard (1...60).contains(params.device_name.count) else {
            throw Abort(.badRequest, reason: "Der Gerätename muss 1 bis 60 Zeichen haben.")
        }
        return params
    }
}
