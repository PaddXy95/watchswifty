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

extension Application {
    private struct TokenCipherKey: StorageKey { typealias Value = TokenCipher }

    var tokenCipher: TokenCipher {
        get {
            guard let cipher = storage[TokenCipherKey.self] else { fatalError("Token cipher not configured") }
            return cipher
        }
        set { storage[TokenCipherKey.self] = newValue }
    }
}

extension Request {
    /// The logged-in user's decrypted TMDB token (nil without one or when it cannot be decrypted).
    var tmdbToken: String? {
        application.tokenCipher.open(auth.get(User.self)?.tmdbToken)
    }

    /// TMDB client for the logged-in user's own token (calls fail with `.missingToken` without one).
    var tmdb: any TMDBClient {
        guard let token = tmdbToken else { return MissingTokenTMDBClient() }
        return application.tmdbProvider.make(token)
    }
}

extension Application {
    private struct ImportLockKey: StorageKey { typealias Value = AsyncMutex }

    /// Serializes import decisions (MappingService) with the matching worker's writes.
    var importLock: AsyncMutex {
        get {
            guard let lock = storage[ImportLockKey.self] else { fatalError("import lock not configured") }
            return lock
        }
        set { storage[ImportLockKey.self] = newValue }
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
