import Fluent
import Vapor

/// Password login and logout: `GET`/`POST /login` and `POST /logout`.
struct AuthController {
    /// Form fields of `POST /login`; `returnTo` is only followed when `isSafeReturnTo(_:)` accepts it.
    struct LoginInput: Content {
        var username: String
        var password: String
        var returnTo: String?
    }

    static let failureMessage = "Benutzername oder Passwort falsch."

    /// Registers the login and logout routes behind the session authenticator.
    /// - Parameter routes: The public routes builder.
    func register(on routes: any RoutesBuilder) {
        let sessioned = routes.grouped(User.sessionAuthenticator())
        sessioned.get("login", use: loginPage)
        sessioned.post("login", use: login)
        sessioned.post("logout", use: logout)
    }

    /// `GET /login`: renders the login page, or redirects a signed-in user to the safe `returnTo` or `/`.
    /// - Parameter req: The request, optionally with a `returnTo` query parameter.
    /// - Returns: The login page or the redirect.
    /// - Throws: Errors reading the mail settings or rendering.
    func loginPage(req: Request) async throws -> Response {
        let returnTo = (try? req.query.get(String.self, at: "returnTo")).flatMap { isSafeReturnTo($0) ? $0 : nil }
        if req.auth.has(User.self) { return req.redirect(to: returnTo ?? "/", redirectType: .normal) }
        return try await Self.loginResponse(req, status: .ok, error: nil, returnTo: returnTo)
    }

    /// The login page (password form and/or the OIDC button).
    /// - Parameters:
    ///   - req: The request.
    ///   - status: The HTTP status.
    ///   - error: The German error message to show, if any.
    ///   - username: Prefill for the username field.
    ///   - returnTo: The already validated return path, kept in the form.
    /// - Returns: The rendered login page.
    /// - Throws: Errors reading the mail settings or rendering.
    static func loginResponse(_ req: Request, status: HTTPStatus, error: String?, username: String = "",
                              returnTo: String?) async throws -> Response {
        let config = req.application.loginSettings.current
        let page = LoginPage(error: error, username: username, returnTo: returnTo,
                             forgotPasswordLink: try await req.mailSettings.state().settings != nil,
                             ssoName: config.oidc?.displayName, passwordLogin: config.passwordLogin)
        return try await HTMLResponse(status: status, page).encodeResponse(for: req)
    }

    /// `POST /login`: checks username and password and signs the user in on a new session.
    ///
    /// Unknown users and accounts without password are verified against a dummy hash, and every failure waits
    /// `loginFailureDelay`, so neither the answer nor its timing reveals which usernames exist.
    /// - Parameter req: The request with the login form.
    /// - Returns: A redirect to the safe `returnTo` or `/`, or the login page with „Benutzername oder Passwort falsch.“
    ///   (wrong username or password).
    /// - Throws: `Abort(.notFound)` while the password login is off; decoding, database and hashing errors.
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
            try await req.signInWithNewSession(user)
            return req.redirect(to: returnTo ?? "/", redirectType: .normal)
        }
        try await Task.sleep(for: req.application.appConfig.loginFailureDelay)
        return try await Self.loginResponse(req, status: .ok, error: Self.failureMessage, username: input.username,
                                            returnTo: returnTo)
    }

    /// `POST /logout`: signs out, destroys the session and redirects to `/login`.
    /// - Parameter req: The request.
    /// - Returns: The redirect to `/login`.
    func logout(req: Request) async throws -> Response {
        req.auth.logout(User.self)
        req.session.unauthenticate(User.self)
        req.session.destroy()
        return req.redirect(to: "/login", redirectType: .normal)
    }
}
