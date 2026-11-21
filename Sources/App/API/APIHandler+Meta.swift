import Vapor
import WatchSwiftyAPI

extension APIHandler {
    /// Handles `GET /api/v1/version`: the running build's version and commit (`AppVersion.current`); needs no token.
    /// - Parameter input: The generated operation input (no parameters).
    /// - Returns: `.ok` with version and commit.
    func getVersion(_ input: Operations.getVersion.Input) async throws -> Operations.getVersion.Output {
        let version = AppVersion.current
        return .ok(.init(body: .json(.init(version: version.version, commit: version.commit))))
    }
}
