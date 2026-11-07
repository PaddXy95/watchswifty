import Vapor

extension Request {
    /// True when the request was issued by htmx (`HX-Request: true`).
    var isHTMX: Bool { headers.first(name: "HX-Request") == "true" }
}
