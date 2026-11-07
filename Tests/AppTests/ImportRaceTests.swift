@testable import App
import Fluent
import Foundation
import NIOConcurrencyHelpers
import Testing
import VaporTesting

@Suite("ImportRaces")
struct ImportRaceTests {
    @Test func mutexSerializesCriticalSections() async throws {
        let mutex = AsyncMutex()
        let log = NIOLockedValueBox<[String]>([])
        await withTaskGroup(of: Void.self) { group in
            for name in ["a", "b", "c"] {
                group.addTask {
                    await mutex.lock()
                    log.withLockedValue { $0.append("\(name)+") }
                    try? await Task.sleep(for: .milliseconds(20))
                    log.withLockedValue { $0.append("\(name)-") }
                    await mutex.unlock()
                }
            }
        }
        let entries = log.withLockedValue { $0 }
        #expect(entries.count == 6)
        for index in stride(from: 0, to: 6, by: 2) {
            #expect(entries[index].dropLast() == entries[index + 1].dropLast())   // enter/leave pairs never interleave
        }
    }

    @Test func changeToUnknownTitleKeepsOldMapping() async throws {
        try await withTestApp(tmdb: ImportPageTests.fake()) { app in
            let user = try await createUser(app, "pat")
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            _ = try await app.matchingWorker.processAll()
            let mapping = try #require(try await NetflixMapping.query(on: app.db).filter(\.$netflixName == "The Mentalist").first())
            let headers = try await login(app, "pat").adding(.htmx)
            try await app.testing().test(.POST, "/import/mappings/\(mapping.requireID())/change", headers: headers, beforeRequest: { req in
                try req.content.encode(AcceptInput(kind: "tv", tmdbID: 999_999), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })
            let reloaded = try #require(try await NetflixMapping.find(mapping.requireID(), on: app.db))
            #expect(reloaded.mappingStatus == .auto)
            #expect(reloaded.$title.id == mapping.$title.id)
            let watches = try await Watch.query(on: app.db).filter(\.$user.$id == user.requireID()).count()
            #expect(watches == 4)
        }
    }

    @Test func concurrentRunsDoNotDuplicateWatches() async throws {
        let tmdb = MatchingWorkerTests.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            let worker = MatchingWorker(db: app.db, provider: TMDBProvider { _ in tmdb }, logger: app.logger, enabled: false)
            async let first = worker.processAll()
            async let second = worker.processAll()
            _ = try await (first, second)
            _ = try await worker.processAll()
            let watches = try await Watch.query(on: app.db).filter(\.$user.$id == user.requireID()).count()
            #expect(watches == 4)
        }
    }
}
