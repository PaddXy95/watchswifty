import Foundation
import Logging
import NIOCore
import NIOPosix
import Vapor

/// Process entry point: reads the configuration, builds the live TMDB provider and runs the Vapor application.
@main
enum Entrypoint {
    /// Configures the application, runs the requested command (`serve` by default) and shuts down.
    ///
    /// A `ConfigError` (at startup or from `configure`) prints its German message and exits with status 1; a failed
    /// command (`CommandFailure`, already logged by `execute()`) also exits with status 1.
    /// - Throws: Errors from detecting the environment, bootstrapping logging or creating the application, and any
    ///   other error from configuring or running the app (logged first).
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
            let limiter = RateLimiter()   // one TMDB budget shared by all users
            let client = app.client
            let provider = TMDBProvider { token in
                LiveTMDBClient(client: client, token: token, language: config.tmdbLanguage, limiter: limiter)
            }
            try await configure(app, config: config, tmdbProvider: provider)
            try await app.execute()
        } catch is CommandFailure {
            // e.g. `reset-password` with an unknown user: `execute()` already logged the message.
            try? await app.asyncShutdown()
            exit(1)
        } catch let error as ConfigError {
            // Setup problems (key, data folder) get a clear message instead of a crash dump.
            FileHandle.standardError.write(Data("\(error.description)\n".utf8))
            try? await app.asyncShutdown()
            exit(1)
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
