@testable import App
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
import VaporTesting

/// Findings of the final review (logging, user errors, body limits, paging overflow).
@Suite("APIReviewFixes")
struct APIReviewFixTests {
    @Test func errorLogNeverContainsTokensOrBodies() {
        var request = HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/api/v1/me/password")
        request.headerFields[.authorization] = "Bearer ws_secret-token-value"
        request.headerFields[.cookie] = "watchswifty_session=geheim"
        struct Input: Sendable { let password = "mein-passwort" }
        let error = ServerError(operationID: "changePassword", request: request, requestBody: nil,
                                requestMetadata: ServerRequestMetadata(), operationInput: Input(),
                                causeDescription: "Handler threw", underlyingError: TMDBError.network("down"))
        let line = APIErrorMiddleware.logDescription(of: error)
        #expect(line.contains("changePassword"))
        #expect(line.contains("down"))
        #expect(!line.contains("ws_secret-token-value"))
        #expect(!line.contains("geheim"))
        #expect(!line.contains("mein-passwort"))
    }

    @Test func wrongContentTypeIs4xx() async throws {
        try await withTestApp { app in
            try await app.testing().test(.POST, "/api/v1/auth/token", beforeRequest: { req in
                req.body = ByteBuffer(string: #"{"code":"x","codeVerifier":"y","redirectUri":"dev.patmei.watchswifty:/auth"}"#)
                req.headers.contentType = .plainText
            }, afterResponse: { res async throws in
                #expect((400..<500).contains(res.status.code), "got \(res.status.code)")
                #expect(try res.content.decode(APIErrorBody.self).code != "internal")
            })
        }
    }

    @Test func missingRequiredBodyIs4xx() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            try await app.testing().test(.PUT, "/api/v1/me/password", headers: .bearer(token)) { res async in
                #expect((400..<500).contains(res.status.code), "got \(res.status.code)")
            }
        }
    }

    @Test func oversizedJSONBodyIs413() async throws {
        try await withTestApp { app in
            let huge = #"{"code":""# + String(repeating: "x", count: 2 * 1024 * 1024) + #"","codeVerifier":"y","redirectUri":"dev.patmei.watchswifty:/auth"}"#
            try await app.testing().test(.POST, "/api/v1/auth/token", beforeRequest: { req in
                req.body = ByteBuffer(string: huge)
                req.headers.contentType = .json
            }, afterResponse: { res async throws in
                #expect(res.status == .payloadTooLarge)
                #expect(try res.content.decode(APIErrorBody.self).code == "payloadTooLarge")
            })
        }
    }

    @Test func hugePageNumberDoesNotCrash() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            try await app.testing().test(.GET, "/api/v1/history?page=9223372036854775807", headers: .bearer(token)) { res async in
                #expect(res.status == .ok)
            }
            let web = try await login(app, "pat")
            try await app.testing().test(.GET, "/history?page=9223372036854775807", headers: web) { res async in
                #expect(res.status == .ok)
            }
        }
    }

    /// Out-of-range years count as "all years" instead of trapping in `year - 1` (security audit F09).
    @Test(arguments: ["-9223372036854775808", "9223372036854775807"])
    func extremeStatsYearDoesNotCrash(year: String) async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let token = try await apiToken(app, user)
            try await app.testing().test(.GET, "/api/v1/stats?year=\(year)", headers: .bearer(token)) { res async in
                #expect(res.status == .ok)
            }
            let web = try await login(app, "pat")
            try await app.testing().test(.GET, "/stats?year=\(year)", headers: web) { res async in
                #expect(res.status == .ok)
            }
        }
    }
}
