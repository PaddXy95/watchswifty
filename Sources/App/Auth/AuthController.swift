import Fluent
import Vapor

struct AuthController {
    struct LoginInput: Content {
        var username: String
        var password: String
        var returnTo: String?
    }

    static let failureMessage = "Benutzername oder Passwort falsch."

    func register(on routes: any RoutesBuilder) {
        let sessioned = routes.grouped(User.sessionAuthenticator())
        sessioned.get("login", use: loginPage)
        sessioned.post("login", use: login)
        sessioned.post("logout", use: logout)
    }

    func loginPage(req: Request) async throws -> Response {
        let returnTo = (try? req.query.get(String.self, at: "returnTo")).flatMap { isSafeReturnTo($0) ? $0 : nil }
        if req.auth.has(User.self) { return req.redirect(to: returnTo ?? "/", redirectType: .normal) }
        return try await Self.loginResponse(req, status: .ok, error: nil, returnTo: returnTo)
    }

    /// The login page (password form and/or the OIDC button).
    static func loginResponse(_ req: Request, status: HTTPStatus, error: String?, username: String = "",
                              returnTo: String?) async throws -> Response {
        let config = req.application.loginSettings.current
        let page = LoginPage(error: error, username: username, returnTo: returnTo,
                             forgotPasswordLink: try await req.mailSettings.state().settings != nil,
                             ssoName: config.oidc?.displayName, passwordLogin: config.passwordLogin)
        return try await HTMLResponse(status: status, page).encodeResponse(for: req)
    }

    func login(req: Request) async throws -> Response {
        guard req.application.loginSettings.current.passwordLogin else { throw Abort(.notFound) }
        let input = try req.content.decode(LoginInput.self)
        let returnTo = input.returnTo.flatMap { isSafeReturnTo($0) ? $0 : nil }
        let username = User.normalize(input.username)
        let user = try await User.query(on: req.db).filter(\.$username == username).first()
        // Unknown users and accounts without a password are checked against a dummy hash, so the response time does
        // not reveal which usernames exist.
        let hash = user.flatMap { $0.hasPassword ? $0.passwordHash : nil } ?? req.application.dummyPasswordHash
        let matches = try await req.password.async.verify(input.password, created: hash)
        if let user, user.hasPassword, matches {
            req.auth.login(user)
            req.session.authenticate(user)
            return req.redirect(to: returnTo ?? "/", redirectType: .normal)
        }
        try await Task.sleep(for: req.application.appConfig.loginFailureDelay)
        return try await Self.loginResponse(req, status: .ok, error: Self.failureMessage, username: input.username,
                                            returnTo: returnTo)
    }

    func logout(req: Request) async throws -> Response {
        req.auth.logout(User.self)
        req.session.unauthenticate(User.self)
        req.session.destroy()
        return req.redirect(to: "/login", redirectType: .normal)
    }
}
