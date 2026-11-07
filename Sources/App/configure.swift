import Fluent
import FluentSQLiteDriver
import Vapor

func configure(_ app: Application, config: AppConfig, tmdbProvider: TMDBProvider) async throws {
    app.appConfig = config
    app.tmdbProvider = tmdbProvider
    app.passwords.use(.bcrypt(cost: config.bcryptCost))
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    app.middleware.use(OriginCheckMiddleware(allowedOrigins: config.publicOrigins))
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
    app.migrations.add(CreateTitle())
    app.migrations.add(CreateEpisode())
    app.migrations.add(CreateUserTitle())
    app.migrations.add(CreateWatch())
    app.migrations.add(CreateNetflixImport())
    app.migrations.add(CreateNetflixMapping())
    app.migrations.add(CreateNetflixRow())
    app.migrations.add(AddUserTMDBToken())

    try routes(app)
    try await app.autoMigrate()
    try await bootstrapAdmin(config: config, db: app.db, logger: app.logger, hasher: app.password)

    app.matchingWorker = MatchingWorker(db: app.db, provider: tmdbProvider, logger: app.logger, enabled: config.backgroundJobsEnabled)
    if config.backgroundJobsEnabled {
        app.lifecycle.use(MatchingWorkerLifecycle())
        app.lifecycle.use(DailyRefreshLifecycle())
    }
}
