import Vapor

func routes(_ app: Application) throws {
    app.get("healthz") { _ in "ok" }
}
