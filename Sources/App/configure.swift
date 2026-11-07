import Fluent
import FluentSQLiteDriver
import Vapor

func configure(_ app: Application, config: AppConfig, tmdbProvider: TMDBProvider,
               releaseFetcher: (any ReleaseFetcher)? = nil) async throws {
    app.appConfig = config
    app.tokenCipher = TokenCipher(key: try TokenKeyLoader.load(key: config.tokenKey, file: config.tokenKeyFile,
                                                               databasePath: config.databasePath, logger: app.logger))
    app.tmdbProvider = tmdbProvider
    app.releaseFetcher = releaseFetcher ?? LiveReleaseFetcher(client: app.client, userAgent: "WatchSwifty/\(config.appVersion.version)")
    app.updateStatus = UpdateStatus()
    app.passwords.use(.bcrypt(cost: config.bcryptCost))
    app.middleware = Middlewares()
    app.middleware.use(HTMLErrorMiddleware())
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

    try checkDataDirectory(databasePath: config.databasePath)
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
    app.migrations.add(AddUserTitleComment())
    app.migrations.add(CreateSeasonNote())
    app.migrations.add(AddTitleDetails())
    app.migrations.add(AddEpisodeOverview())
    app.migrations.add(AddFollowFields())
    app.migrations.add(AddRuntimes())
    app.migrations.add(CreateAppSettings())
    app.migrations.add(CreateFilmListEntry())

    try routes(app)
    try await app.autoMigrate()
    let encrypted = try await encryptStoredTokens(db: app.db, cipher: app.tokenCipher)
    if encrypted > 0 { app.logger.notice("\(encrypted) TMDB-Token verschlüsselt gespeichert") }
    try await app.updates.loadStatus()
    try await bootstrapAdmin(config: config, db: app.db, logger: app.logger, hasher: app.password)

    app.importLock = AsyncMutex()
    app.matchingWorker = MatchingWorker(db: app.db, provider: tmdbProvider, logger: app.logger, cipher: app.tokenCipher,
                                        enabled: config.backgroundJobsEnabled, lock: app.importLock)
    app.filmListWorker = FilmListWorker(db: app.db, provider: tmdbProvider, cipher: app.tokenCipher, logger: app.logger,
                                        today: config.today, enabled: config.backgroundJobsEnabled)
    if config.backgroundJobsEnabled {
        app.lifecycle.use(MatchingWorkerLifecycle())
        app.lifecycle.use(DailyRefreshLifecycle())
        app.lifecycle.use(UpdateCheckLifecycle())
    }
}
