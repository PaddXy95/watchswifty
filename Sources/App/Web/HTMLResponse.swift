import Elementary
import Vapor

/// Renders Elementary content into a `text/html` response.
struct HTMLResponse: AsyncResponseEncodable {
    /// HTTP status of the response.
    var status: HTTPStatus
    /// Extra headers (e.g. `HX-Retarget`, `HX-Trigger`); `Content-Type` is always set on encoding.
    var headers: HTTPHeaders
    /// The rendered markup.
    var html: String

    /// Renders the content right away.
    /// - Parameters:
    ///   - status: HTTP status of the response.
    ///   - headers: Extra response headers.
    ///   - content: The Elementary page or fragment to render.
    init(status: HTTPStatus = .ok, headers: HTTPHeaders = [:], _ content: some HTML) {
        self.status = status
        self.headers = headers
        self.html = content.render()
    }

    /// Builds the response with `Content-Type: text/html; charset=utf-8`.
    /// - Parameter request: The request being answered (unused).
    /// - Returns: The response with the rendered markup as body.
    /// - Throws: Nothing in practice; required by `AsyncResponseEncodable`.
    func encodeResponse(for request: Request) async throws -> Response {
        var headers = headers
        headers.replaceOrAdd(name: .contentType, value: "text/html; charset=utf-8")
        return Response(status: status, headers: headers, body: .init(string: html))
    }
}

/// Renders nothing (used when an htmx swap should remove its target).
struct EmptyHTML: HTML {
    var body: some HTML { "" }
}
