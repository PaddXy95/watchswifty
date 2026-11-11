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

extension Application {
    private struct MailSenderKey: StorageKey { typealias Value = any MailSender }
    private struct BackgroundTasksKey: StorageKey { typealias Value = BackgroundTasks }

    var mailSender: any MailSender {
        get {
            guard let sender = storage[MailSenderKey.self] else { fatalError("Mail sender not configured") }
            return sender
        }
        set { storage[MailSenderKey.self] = newValue }
    }

    var backgroundTasks: BackgroundTasks {
        get {
            guard let tasks = storage[BackgroundTasksKey.self] else { fatalError("Background tasks not configured") }
            return tasks
        }
        set { storage[BackgroundTasksKey.self] = newValue }
    }
}

extension Application {
    private struct DummyPasswordHashKey: StorageKey { typealias Value = String }

    /// Bcrypt hash (same cost as real ones) the login checks for unknown users and accounts without a password.
    var dummyPasswordHash: String {
        get {
            guard let hash = storage[DummyPasswordHashKey.self] else { fatalError("Dummy password hash not configured") }
            return hash
        }
        set { storage[DummyPasswordHashKey.self] = newValue }
    }
}

extension Application {
    private struct OIDCIdentityLockKey: StorageKey { typealias Value = AsyncMutex }
    private struct OIDCUsedStatesKey: StorageKey { typealias Value = OIDCUsedStates }

    /// States of OIDC flows already completed (single-use flow cookies).
    var oidcUsedStates: OIDCUsedStates {
        get {
            guard let states = storage[OIDCUsedStatesKey.self] else { fatalError("OIDC states not configured") }
            return states
        }
        set { storage[OIDCUsedStatesKey.self] = newValue }
    }

    /// Serializes creating and linking OIDC accounts (first admin, unique identities).
    var oidcIdentityLock: AsyncMutex {
        get {
            guard let lock = storage[OIDCIdentityLockKey.self] else { fatalError("OIDC lock not configured") }
            return lock
        }
        set { storage[OIDCIdentityLockKey.self] = newValue }
    }
}

extension Application {
    private struct DailyRunTriggerKey: StorageKey { typealias Value = DailyRunTrigger }

    /// Wakes the daily loop when the admin changes its time.
    var dailyRunTrigger: DailyRunTrigger {
        get {
            guard let trigger = storage[DailyRunTriggerKey.self] else { fatalError("Daily run trigger not configured") }
            return trigger
        }
        set { storage[DailyRunTriggerKey.self] = newValue }
    }
}
