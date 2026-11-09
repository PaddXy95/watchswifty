@testable import App
import Fluent
import Testing
import VaporTesting

func withTestApp(config: AppConfig = .testing, tmdb: FakeTMDBClient = FakeTMDBClient(),
                 releases: FakeReleaseFetcher = FakeReleaseFetcher(), mail: FakeMailSender = FakeMailSender(),
                 _ test: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    do {
        try await configure(app, config: config, tmdbProvider: TMDBProvider { _ in tmdb }, releaseFetcher: releases,
                            mailSender: mail)
        try await test(app)
    } catch {
        try await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

extension HTTPHeaders {
    /// Headers of a same-origin browser request (passes the Origin check).
    static var sameOrigin: HTTPHeaders {
        ["Origin": "http://localhost:8080", "Host": "localhost:8080"]
    }

    static var htmx: HTTPHeaders {
        var h = HTTPHeaders.sameOrigin
        h.add(name: "HX-Request", value: "true")
        return h
    }

    func adding(_ other: HTTPHeaders) -> HTTPHeaders {
        var h = self
        for (name, value) in other { h.replaceOrAdd(name: name, value: value) }
        return h
    }
}

struct LoginForm: Content {
    var username: String
    var password: String
}

@discardableResult
func createUser(_ app: Application, _ username: String, password: String = "password123", isAdmin: Bool = false,
                tmdbToken: String? = "test-token") async throws -> User {
    let user = User(username: User.normalize(username), passwordHash: try app.password.hash(password), isAdmin: isAdmin)
    user.tmdbToken = tmdbToken
    try await user.save(on: app.db)
    return user
}

/// Logs in through the real form and returns headers (session cookie + same-origin) for follow-up requests.
func login(_ app: Application, _ username: String, password: String = "password123") async throws -> HTTPHeaders {
    var cookie: String?
    try await app.testing().test(.POST, "/login", headers: .sameOrigin, beforeRequest: { req in
        try req.content.encode(LoginForm(username: username, password: password), as: .urlEncodedForm)
    }, afterResponse: { res async in
        #expect(res.status == .seeOther, "login failed for \(username)")
        cookie = res.headers.setCookie?["watchswifty_session"].map { "watchswifty_session=\($0.string)" }
    })
    var headers = HTTPHeaders.sameOrigin
    if let cookie { headers.add(name: .cookie, value: cookie) }
    return headers
}
