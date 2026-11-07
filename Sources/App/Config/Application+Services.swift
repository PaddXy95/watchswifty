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
