import Foundation
import OpenAPIVapor
import Vapor
import WatchSwiftyAPI

/// Mounts the generated App API under `/api` (paths in the spec start with `/v1/`).
/// - Parameter app: The application to register the routes on.
/// - Throws: Errors of the generated handler registration.
func registerAPI(_ app: Application) throws {
    let api = app.grouped(APIErrorMiddleware(), APIContextMiddleware())
    let transport = VaporTransport(routesBuilder: api)
    try APIHandler().registerHandlers(on: transport, serverURL: URL(string: "/api")!, middlewares: [EmptyBodyMiddleware(), BodyLimitMiddleware()])
}
