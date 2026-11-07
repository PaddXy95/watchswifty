import Foundation
import Logging
import NIOCore
import NIOPosix
import Vapor

@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let config: AppConfig
        do {
            config = try AppConfig.fromEnvironment(ProcessInfo.processInfo.environment)
        } catch let error as ConfigError {
            FileHandle.standardError.write(Data("\(error.description)\n".utf8))
            exit(1)
        }

        let app = try await Application.make(env)
        do {
            let tmdb = LiveTMDBClient(client: app.client, token: config.tmdbToken, language: config.tmdbLanguage, limiter: RateLimiter())
            try await configure(app, config: config, tmdb: tmdb)
            try await app.execute()
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
