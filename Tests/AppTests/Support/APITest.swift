@testable import App
import Fluent
import Foundation
import VaporTesting

/// Issues an API token for `user` (manual kind) and returns the plain token.
func apiToken(_ app: Application, _ user: User, now: Date = .now) async throws -> String {
    try await APITokenService(db: app.db).issue(userID: user.requireID(), name: "Test", kind: .manual, now: now).token
}

extension HTTPHeaders {
    static func bearer(_ token: String) -> HTTPHeaders {
        ["Authorization": "Bearer \(token)"]
    }
}
