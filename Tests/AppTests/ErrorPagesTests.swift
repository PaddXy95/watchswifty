@testable import App
import Elementary
import Fluent
import Testing
import VaporTesting

@Suite("ErrorPages")
struct ErrorPagesTests {
    @Test func htmxErrorsGoToFlash() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat").adding(.htmx)
            try await app.testing().test(.DELETE, "/watches/\(UUID())", headers: headers) { res async in
                #expect(res.status == .notFound)
                #expect(res.headers.first(name: "HX-Retarget") == "#flash")
                #expect(res.body.string.contains("Nicht gefunden"))
                #expect(!res.body.string.contains("\"reason\""))
            }
        }
    }

    @Test func fullPageErrorsAreGermanHTML() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/tv/abc", headers: headers) { res async in
                #expect(res.status == .notFound)
                #expect(res.headers.first(name: .contentType)?.hasPrefix("text/html") == true)
                #expect(res.body.string.contains("Nicht gefunden"))
                #expect(res.body.string.contains("watchswifty"))
            }
        }
    }

    @Test func originRejectionIsGermanHTML() async throws {
        try await withTestApp { app in
            try await app.testing().test(.POST, "/login", headers: ["Host": "localhost:8080", "Origin": "http://evil.example"]) { res async in
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("Herkunft"))
                #expect(res.body.string.contains("PUBLIC_ORIGIN"))
            }
        }
    }

    @Test func searchWithTMDBDownShowsFlash() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.failure = .network("timeout")
        try await withTestApp(tmdb: tmdb) { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat").adding(.htmx)
            try await app.testing().test(.GET, "/search/results?q=Dark", headers: headers) { res async in
                #expect(res.status == .badGateway)
                #expect(res.headers.first(name: "HX-Retarget") == "#flash")
                #expect(res.body.string.contains("TMDB nicht erreichbar"))
            }
        }
    }

    @Test func rejectedTokenExplainsWhatToDo() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.failure = .unauthorized
        try await withTestApp(tmdb: tmdb) { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat").adding(.htmx)
            try await app.testing().test(.GET, "/search/results?q=Dark", headers: headers) { res async in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("TMDB hat deinen Token abgelehnt – bitte unter Konto erneuern."))
            }
        }
    }

    @Test func tooLargeUploadExplainsFile() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            let big = String(repeating: "x", count: 10 * 1024 * 1024 + 10)
            try await app.testing().test(.POST, "/import", headers: headers, beforeRequest: { req in
                try req.content.encode(UploadForm(file: File(data: ByteBuffer(string: big), filename: "ViewingActivity.csv")), as: .formData)
            }, afterResponse: { res async in
                #expect(res.status == .payloadTooLarge)
                #expect(res.body.string.contains("zu groß"))
                #expect(res.body.string.contains("NetflixViewingHistory.csv"))
            })
        }
    }

    @Test func htmxSwapsErrorStatuses() {
        let html = PageLayout(title: "X", nav: nil) { "" }.render()
        #expect(html.contains("[45]..&quot;,&quot;swap&quot;:true"))
    }
}
