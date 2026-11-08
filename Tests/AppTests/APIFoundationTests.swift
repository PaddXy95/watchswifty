@testable import App
import Foundation
import Testing
import VaporTesting

struct APIErrorBody: Codable { let code: String; let message: String }

@Suite("APIFoundation")
struct APIFoundationTests {
    @Test func versionEndpoint() async throws {
        try await withTestApp { app in
            try await app.testing().test(.GET, "/api/v1/version") { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.contentType?.subType == "json")
                struct Version: Codable { let version: String; let commit: String? }
                #expect(try res.content.decode(Version.self).version == "dev")
            }
        }
    }

    @Test func unknownAPIPathIsJSON404() async throws {
        try await withTestApp { app in
            try await app.testing().test(.GET, "/api/v1/nope") { res async throws in
                #expect(res.status == .notFound)
                #expect(res.headers.contentType?.subType == "json")
                #expect(try res.content.decode(APIErrorBody.self).code == "notFound")
            }
        }
    }

    @Test func apiPostSkipsOriginCheck() async throws {
        try await withTestApp { app in
            try await app.testing().test(.POST, "/api/v1/nope") { res async throws in
                #expect(res.status == .notFound)
                #expect(try res.content.decode(APIErrorBody.self).code == "notFound")
            }
        }
    }
}
