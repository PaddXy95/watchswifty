import Elementary
import Vapor

/// Renders Elementary content into a `text/html` response.
struct HTMLResponse: AsyncResponseEncodable {
    var status: HTTPStatus
    var headers: HTTPHeaders
    var html: String

    init(status: HTTPStatus = .ok, headers: HTTPHeaders = [:], _ content: some HTML) {
        self.status = status
        self.headers = headers
        self.html = content.render()
    }

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
