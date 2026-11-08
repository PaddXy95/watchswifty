import Fluent
import Foundation
import Vapor

/// Browser part of the app login: the app opens `/api/auth/authorize` in a system browser sheet, the user signs in
/// (password or later Authentik) and confirms; the app receives a one-time code at `watchswifty://auth`.
struct APIAuthorizeController {
    static let redirectURI = "watchswifty://auth"

    struct Params: Content {
        var redirect_uri: String
        var state: String
        var code_challenge: String
        var code_challenge_method: String
        var device_name: String
        var decision: String?
    }

    func register(on routes: any RoutesBuilder) {
        let sessioned = routes.grouped(User.sessionAuthenticator())
        sessioned.get("api", "auth", "authorize", use: show)
        sessioned.post("api", "auth", "authorize", use: decide)
    }

    func show(req: Request) async throws -> Response {
        let params = try validated(try req.query.decode(Params.self))
        guard req.auth.has(User.self) else {
            var components = URLComponents()
            components.path = "/login"
            components.queryItems = [URLQueryItem(name: "returnTo", value: req.url.string)]
            return req.redirect(to: components.string ?? "/login", redirectType: .normal)
        }
        return try await HTMLResponse(AuthorizePage(params: params)).encodeResponse(for: req)
    }

    func decide(req: Request) async throws -> Response {
        let params = try validated(try req.content.decode(Params.self))
        guard let user = req.auth.get(User.self) else { return req.redirect(to: "/login", redirectType: .normal) }
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

    /// Rejects anything but the app's own redirect and a proper PKCE challenge – never redirects on errors.
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
