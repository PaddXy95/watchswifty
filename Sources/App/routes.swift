import Fluent
import Vapor

func routes(_ app: Application) throws {
    app.get("healthz") { _ in "ok" }
    AuthController().register(on: app)

    let protected = app.grouped(User.sessionAuthenticator(), AuthRedirectMiddleware())
    protected.get { req async throws -> HTMLResponse in
        let user = try req.currentUser
        return HTMLResponse(ContinuePlaceholderPage(nav: .init(username: user.username, isAdmin: user.isAdmin, active: .continueWatching)))
    }
    AdminUsersController().register(on: protected)
    AccountController().register(on: protected)
    SearchController().register(on: protected)
    TitleController().register(on: protected)
}
