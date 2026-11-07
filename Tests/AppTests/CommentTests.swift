@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

struct CommentInput: Content { var comment: String }

@Suite("Comments")
struct CommentTests {
    func withUser(_ body: (Application, User, HTTPHeaders) async throws -> Void) async throws {
        try await withTestApp(tmdb: TitlePagesTests.fake()) { app in
            let user = try await createUser(app, "pat")
            try await body(app, user, try await login(app, "pat").adding(.htmx))
        }
    }

    func post(_ app: Application, _ path: String, _ comment: String, _ headers: HTTPHeaders,
              _ check: @escaping (TestingHTTPResponse) async -> Void) async throws {
        try await app.testing().test(.POST, path, headers: headers, beforeRequest: { req in
            try req.content.encode(CommentInput(comment: comment), as: .urlEncodedForm)
        }, afterResponse: check)
    }

    @Test func seriesCommentSavedAndShown() async throws {
        try await withUser { app, _, headers in
            try await post(app, "/tv/1399/comment", "  Richtig gute Serie  ", headers) { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Richtig gute Serie"))
                #expect(res.body.string.contains("Gespeichert."))
            }
            try await app.testing().test(.GET, "/tv/1399", headers: headers) { res async in
                #expect(res.body.string.contains("Kommentar zur Serie"))
                #expect(res.body.string.contains("Richtig gute Serie"))
            }
        }
    }

    @Test func seasonCommentSavedAndShown() async throws {
        try await withUser { app, _, headers in
            try await post(app, "/tv/1399/seasons/2/comment", "Staffel 2 zieht sich", headers) { res in
                #expect(res.status == .ok)
            }
            try await app.testing().test(.GET, "/tv/1399", headers: headers) { res async in
                let body = res.body.string
                #expect(body.contains("Kommentar zur Staffel"))
                let season2 = body.range(of: #"id="season-2""#)
                let comment = body.range(of: "Staffel 2 zieht sich")
                if let season2, let comment { #expect(season2.lowerBound < comment.lowerBound) } else { Issue.record("missing") }
            }
            // Re-rendered season sections keep the comment.
            try await app.testing().test(.POST, "/tv/1399/episodes/2/1/watch", headers: headers) { res async in
                #expect(res.body.string.contains("Staffel 2 zieht sich"))
            }
        }
    }

    @Test func movieComment() async throws {
        try await withUser { app, _, headers in
            try await post(app, "/movie/603/comment", "Klassiker", headers) { res in #expect(res.status == .ok) }
            try await app.testing().test(.GET, "/movie/603", headers: headers) { res async in
                #expect(res.body.string.contains("Klassiker"))
            }
        }
    }

    @Test func emptyCommentDeletes() async throws {
        try await withUser { app, user, headers in
            try await post(app, "/tv/1399/comment", "weg damit", headers) { _ in }
            try await post(app, "/tv/1399/seasons/1/comment", "auch weg", headers) { _ in }
            try await post(app, "/tv/1399/comment", "   ", headers) { res in #expect(res.status == .ok) }
            try await post(app, "/tv/1399/seasons/1/comment", "", headers) { res in #expect(res.status == .ok) }
            let entry = try await UserTitle.query(on: app.db).filter(\.$user.$id == user.requireID()).first()
            #expect(entry?.comment == nil)
            #expect(try await SeasonNote.query(on: app.db).count() == 0)
        }
    }

    @Test func tooLongComment422() async throws {
        try await withUser { app, _, headers in
            try await post(app, "/tv/1399/comment", String(repeating: "a", count: 2001), headers) { res in
                #expect(res.status == .unprocessableEntity)
                #expect(res.body.string.contains("Kommentar darf höchstens 2.000 Zeichen haben."))
            }
            try await post(app, "/tv/1399/comment", String(repeating: "a", count: 2000), headers) { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func markupIsEscaped() async throws {
        try await withUser { app, _, headers in
            try await post(app, "/tv/1399/comment", "<b>fett</b>\nZeile 2", headers) { _ in }
            try await app.testing().test(.GET, "/tv/1399", headers: headers) { res async in
                #expect(res.body.string.contains("&lt;b&gt;fett&lt;/b&gt;\nZeile 2"))
                #expect(!res.body.string.contains("<b>fett</b>"))
            }
        }
    }

    @Test func commentsArePrivate() async throws {
        try await withUser { app, _, headers in
            try await post(app, "/tv/1399/comment", "Geheim-Serie", headers) { _ in }
            try await post(app, "/tv/1399/seasons/1/comment", "Geheim-Staffel", headers) { _ in }
            try await post(app, "/movie/603/comment", "Geheim-Film", headers) { _ in }
            try await createUser(app, "other")
            let other = try await login(app, "other").adding(.htmx)
            try await app.testing().test(.GET, "/tv/1399", headers: other) { res async in
                #expect(!res.body.string.contains("Geheim-Serie"))
                #expect(!res.body.string.contains("Geheim-Staffel"))
            }
            try await app.testing().test(.GET, "/movie/603", headers: other) { res async in
                #expect(!res.body.string.contains("Geheim-Film"))
            }
        }
    }

    @Test func deletingUserRemovesSeasonNotes() async throws {
        try await withUser { app, user, headers in
            try await post(app, "/tv/1399/seasons/1/comment", "Notiz", headers) { _ in }
            try await user.delete(on: app.db)
            #expect(try await SeasonNote.query(on: app.db).count() == 0)
        }
    }
}
