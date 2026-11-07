@testable import App
import Testing
import VaporTesting

func withTestApp(config: AppConfig = .testing, _ test: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    do {
        try await configure(app, config: config)
        try await test(app)
    } catch {
        try await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}
