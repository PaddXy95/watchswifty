@testable import App
import Elementary
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("Retry")
struct RetryTests {
    @Test func nonJSONResponseIsInvalidResponse() async throws {
        let http = ScriptedHTTPClient(eventLoop: MultiThreadedEventLoopGroup.singleton.next(), responses: [
            (.ok, [:], "<html>Captive portal</html>"),
        ])
        let client = LiveTMDBClient(client: http, token: "t", language: "de-DE", limiter: RateLimiter(minInterval: .zero))
        await #expect(throws: TMDBError.invalidResponse) { _ = try await client.search("Dark", kind: .tv) }
    }

    @Test func nonTMDBErrorIsRecordedPerUser() async throws {
        let good = MatchingWorkerTests.fake()
        let broken = MatchingWorkerTests.fake()
        broken.genericFailure = true
        try await withTestApp(tmdb: good) { app in
            let alice = try await createUser(app, "alice", tmdbToken: "broken")
            let bob = try await createUser(app, "bobby")
            for user in [alice, bob] {
                _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            }
            let worker = MatchingWorker(db: app.db, provider: TMDBProvider { $0 == "broken" ? broken : good }, logger: app.logger, cipher: app.tokenCipher, enabled: false)
            _ = try await worker.processAll()
            #expect(try await worker.lastError(for: alice.requireID())?.hasPrefix("Zuordnung fehlgeschlagen") == true)
            let bobMentalist = try await NetflixRow.query(on: app.db).filter(\.$user.$id == bob.requireID()).all()
                .filter { $0.rawTitle.contains("The Mentalist") }
            #expect(bobMentalist.allSatisfy { $0.rowStatus == .matched })
        }
    }

    @Test func retryButtonOnlyWhenSomethingIsStuck() {
        let stuck = ImportProgress(isRunning: false, pendingRows: 3, waitingForReview: 0, lastError: "TMDB nicht erreichbar").render()
        let idle = ImportProgress(isRunning: false, pendingRows: 0, waitingForReview: 2, lastError: nil).render()
        let running = ImportProgress(isRunning: true, pendingRows: 3, waitingForReview: 0, lastError: nil).render()
        #expect(stuck.contains("Erneut versuchen"))
        #expect(stuck.contains("/import/retry"))
        #expect(!idle.contains("Erneut versuchen"))
        #expect(!running.contains("Erneut versuchen"))
    }

    @Test func retryEndpointReturnsProgress() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat").adding(.htmx)
            try await app.testing().test(.POST, "/import/retry", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("import-progress"))
            }
        }
    }

    @Test func workerRetriesByItselfAfterTMDBFailure() async throws {
        let tmdb = MatchingWorkerTests.fake()
        tmdb.failure = .network("down")
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            let worker = MatchingWorker(db: app.db, provider: TMDBProvider { _ in tmdb }, logger: app.logger, cipher: app.tokenCipher, enabled: true,
                                        retryDelay: .milliseconds(100))
            await worker.kick()
            var sawError = false
            for _ in 0..<500 where !sawError {   // up to 10 s: slow CI containers
                try await Task.sleep(for: .milliseconds(20))
                sawError = try await worker.lastError(for: user.requireID()) != nil
            }
            #expect(sawError)
            tmdb.failure = nil
            var matched = false
            for _ in 0..<330 where !matched {   // up to 10 s
                try await Task.sleep(for: .milliseconds(30))
                matched = try await NetflixRow.query(on: app.db).filter(\.$user.$id == user.requireID()).all()
                    .filter { $0.rawTitle.contains("The Mentalist") }.allSatisfy { $0.rowStatus == .matched }
            }
            #expect(matched)
            while await worker.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        }
    }
}
