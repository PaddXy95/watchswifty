import Fluent
import FluentSQLiteDriver
import Vapor

func configure(_ app: Application, config: AppConfig) async throws {
    app.appConfig = config
    app.http.server.configuration.hostname = config.host
    app.http.server.configuration.port = config.port

    if config.databasePath == ":memory:" {
        app.databases.use(.sqlite(.memory), as: .sqlite)
    } else {
        app.databases.use(.sqlite(.file(config.databasePath)), as: .sqlite)
    }

    try routes(app)
    try await app.autoMigrate()
}
