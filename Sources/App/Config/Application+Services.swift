import Vapor

extension Application {
    private struct AppConfigKey: StorageKey { typealias Value = AppConfig }

    var appConfig: AppConfig {
        get {
            guard let config = storage[AppConfigKey.self] else { fatalError("AppConfig not configured") }
            return config
        }
        set { storage[AppConfigKey.self] = newValue }
    }
}

extension Application {
    private struct TMDBProviderKey: StorageKey { typealias Value = TMDBProvider }

    var tmdbProvider: TMDBProvider {
        get {
            guard let provider = storage[TMDBProviderKey.self] else { fatalError("TMDB provider not configured") }
            return provider
        }
        set { storage[TMDBProviderKey.self] = newValue }
    }
}

extension Request {
    /// TMDB client for the logged-in user's own token (calls fail with `.missingToken` without one).
    var tmdb: any TMDBClient {
        guard let token = auth.get(User.self)?.tmdbToken, !token.isEmpty else { return MissingTokenTMDBClient() }
        return application.tmdbProvider.make(token)
    }
}

extension Application {
    private struct MatchingWorkerKey: StorageKey { typealias Value = MatchingWorker }

    var matchingWorker: MatchingWorker {
        get {
            guard let worker = storage[MatchingWorkerKey.self] else { fatalError("MatchingWorker not configured") }
            return worker
        }
        set { storage[MatchingWorkerKey.self] = newValue }
    }
}
