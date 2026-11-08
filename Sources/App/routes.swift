import Fluent
import Vapor

func routes(_ app: Application) throws {
    app.get("healthz") { _ in "ok" }
    app.get("version") { _ in AppVersion.current }
    try registerAPI(app)
    APIAuthorizeController().register(on: app)
    AuthController().register(on: app)

    let protected = app.grouped(User.sessionAuthenticator(), AuthRedirectMiddleware())
    HomeController().register(on: protected)
    HistoryController().register(on: protected)
    LibraryController().register(on: protected)
    StatsController().register(on: protected)
    ImportController().register(on: protected)
    FilmListController().register(on: protected)
    AdminUsersController().register(on: protected)
    SystemController().register(on: protected)
    AccountController().register(on: protected)
    SearchController().register(on: protected)
    TitleController().register(on: protected)
}
