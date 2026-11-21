import Fluent
import Vapor

/// Registers all routes: health and version, the App API and its docs page at `/api`, the public authentication
/// controllers (app login, login, OIDC, password reset), and the feature controllers behind session authentication and
/// `AuthRedirectMiddleware`.
/// - Parameter app: The application.
/// - Throws: Errors of `registerAPI(_:)`.
func routes(_ app: Application) throws {
    app.get("healthz") { _ in "ok" }
    app.get("version") { _ in AppVersion.current }
    try registerAPI(app)
    app.get("api") { _ in HTMLResponse(APIDocsPage()) }
    APIAuthorizeController().register(on: app)
    AuthController().register(on: app)
    OIDCController().register(on: app)
    PasswordResetController().register(on: app)

    let protected = app.grouped(User.sessionAuthenticator(), AuthRedirectMiddleware())
    HomeController().register(on: protected)
    HistoryController().register(on: protected)
    LibraryController().register(on: protected)
    StatsController().register(on: protected)
    ImportController().register(on: protected)
    StandardImportController().register(on: protected)
    AdminUsersController().register(on: protected)
    SystemController().register(on: protected)
    AccountController().register(on: protected)
    SearchController().register(on: protected)
    TitleController().register(on: protected)
    WatchLaterController().register(on: protected)
}
