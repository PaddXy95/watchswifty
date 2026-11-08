import Vapor
import WatchSwiftyAPI

extension APIHandler {
    func getVersion(_ input: Operations.getVersion.Input) async throws -> Operations.getVersion.Output {
        let version = AppVersion.current
        return .ok(.init(body: .json(.init(version: version.version, commit: version.commit))))
    }
}
