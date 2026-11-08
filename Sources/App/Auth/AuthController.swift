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
        return try await HTMLResponse(LoginPage(error: nil, username: "", returnTo: returnTo)).encodeResponse(for: req)
    }

    func login(req: Request) async throws -> Response {
        let input = try req.content.decode(LoginInput.self)
        let returnTo = input.returnTo.flatMap { isSafeReturnTo($0) ? $0 : nil }
        let username = User.normalize(input.username)
        if let user = try await User.query(on: req.db).filter(\.$username == username).first(),
           try await req.password.async.verify(input.password, created: user.passwordHash) {
            req.auth.login(user)
            req.session.authenticate(user)
            return req.redirect(to: returnTo ?? "/", redirectType: .normal)
        }
        try await Task.sleep(for: req.application.appConfig.loginFailureDelay)
        return try await HTMLResponse(LoginPage(error: Self.failureMessage, username: input.username, returnTo: returnTo))
            .encodeResponse(for: req)
    }

    func logout(req: Request) async throws -> Response {
        req.auth.logout(User.self)
        req.session.unauthenticate(User.self)
        req.session.destroy()
        return req.redirect(to: "/login", redirectType: .normal)
    }
}
