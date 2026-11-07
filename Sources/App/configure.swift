import Fluent
import FluentSQLiteDriver
import Vapor

func configure(_ app: Application, config: AppConfig) async throws {
    app.appConfig = config
    app.passwords.use(.bcrypt(cost: config.bcryptCost))
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    app.middleware.use(OriginCheckMiddleware())
    app.sessions.use(.fluent)
    app.sessions.configuration = .init(cookieName: "watchswifty_session") { sessionID in
        .init(string: sessionID.string, expires: Date(timeIntervalSinceNow: 2_592_000), maxAge: 2_592_000,
              isSecure: false, isHTTPOnly: true, sameSite: .lax)
    }
    app.middleware.use(app.sessions.middleware)
    app.http.server.configuration.hostname = config.host
    app.http.server.configuration.port = config.port

    if config.databasePath == ":memory:" {
        app.databases.use(.sqlite(.memory), as: .sqlite)
    } else {
        app.databases.use(.sqlite(.file(config.databasePath)), as: .sqlite)
    }

    app.migrations.add(CreateUser())
    app.migrations.add(SessionRecord.migration)

    try routes(app)
    try await app.autoMigrate()
    try await bootstrapAdmin(config: config, db: app.db, logger: app.logger, hasher: app.password)
}
