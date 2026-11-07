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
    private struct TMDBKey: StorageKey { typealias Value = any TMDBClient }

    var tmdb: any TMDBClient {
        get {
            guard let client = storage[TMDBKey.self] else { fatalError("TMDB client not configured") }
            return client
        }
        set { storage[TMDBKey.self] = newValue }
    }
}

extension Request {
    var tmdb: any TMDBClient { application.tmdb }
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
