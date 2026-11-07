@testable import App
import Elementary
import Fluent
import Foundation
import Testing
import VaporTesting

struct AcceptInput: Content { var kind: String; var tmdbID: Int }
struct AssignInput: Content { var episodeID: UUID }

@Suite("ImportPage")
struct ImportPageTests {
    static func fake() -> FakeTMDBClient {
        let tmdb = MatchingWorkerTests.fake()
        tmdb.setSearch("tv", "Rick and Morty", [
            TMDBSearchResult(id: 60625, kind: .tv, name: "Rick and Morty", originalName: nil, year: 2013, posterPath: nil),
            TMDBSearchResult(id: 60626, kind: .tv, name: "Rick and Morty", originalName: nil, year: 2020, posterPath: nil),
        ])
        tmdb.addSeries(TMDBSeries(id: 60625, name: "Rick and Morty", originalName: nil, year: 2013, posterPath: nil,
                                  status: "Returning Series", seasonNumbers: [8]),
                       episodes: [8: ["Papa-Morty"]], airDate: "2025-01-01")
        tmdb.addSeries(TMDBSeries(id: 1002, name: "Mentalist (Neu)", originalName: nil, year: 2030, posterPath: nil,
                                  status: "Ended", seasonNumbers: [1, 4]),
                       episodes: [1: ["Pilot"], 4: ["Scharlachrote Briefe", "Die Aura des Todes", "Keine Lust auf Shakespeare"]],
                       airDate: "2011-01-01")
        return tmdb
    }

    /// Logged-in "pat" with the fixture imported and one matching run done.
    func withImported(tmdb: FakeTMDBClient = ImportPageTests.fake(), before: ((Application, User) async throws -> Void)? = nil,
                      _ body: (Application, User, HTTPHeaders) async throws -> Void) async throws {
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            try await before?(app, user)
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            _ = try await app.matchingWorker.processAll()
            try await body(app, user, try await login(app, "pat").adding(.htmx))
        }
    }

    func mapping(_ app: Application, _ name: String) async throws -> NetflixMapping {
        guard let m = try await NetflixMapping.query(on: app.db).filter(\.$netflixName == name).first() else { fatalError("no mapping \(name)") }
        return m
    }

    func rows(_ app: Application, containing text: String) async throws -> [NetflixRow] {
        try await NetflixRow.query(on: app.db).all().filter { $0.rawTitle.contains(text) }
    }

    @Test func pageShowsSections() async throws {
        try await withImported { app, _, headers in
            try await app.testing().test(.GET, "/import", headers: headers) { res async in
                let body = res.body.string
                #expect(body.contains("Zu prüfen"))
                #expect(body.contains("Nicht zugeordnet"))
                #expect(body.contains("Zuordnungen"))
                #expect(body.contains("Rick and Morty"))
                #expect(body.contains("automatisch"))
            }
        }
    }

    @Test func acceptMatchesRows() async throws {
        try await withImported { app, _, headers in
            let rick = try await mapping(app, "Rick and Morty")
            #expect(rick.mappingStatus == .review)
            try await app.testing().test(.POST, "/import/mappings/\(rick.requireID())/accept", headers: headers, beforeRequest: { req in
                try req.content.encode(AcceptInput(kind: "tv", tmdbID: 60625), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "HX-Trigger") == "importChanged")
            })
            _ = try await app.matchingWorker.processAll()
            #expect(try await mapping(app, "Rick and Morty").mappingStatus == .confirmed)
            #expect(try await rows(app, containing: "Papa-Morty").first?.rowStatus == .matched)
        }
    }

    @Test func ignoreMapping() async throws {
        try await withImported { app, _, headers in
            let rick = try await mapping(app, "Rick and Morty")
            try await app.testing().test(.POST, "/import/mappings/\(rick.requireID())/ignore", headers: headers) { res async in
                #expect(res.status == .ok)
            }
            #expect(try await mapping(app, "Rick and Morty").mappingStatus == .ignored)
            #expect(try await rows(app, containing: "Rick and Morty").allSatisfy { $0.rowStatus == .ignored })
        }
    }

    @Test func resetKeepsMergedManualWatch() async throws {
        var manualID: UUID?
        try await withImported(before: { app, user in
            _ = try await CatalogService(db: app.db, tmdb: app.tmdbProvider.make("test-token")).title(kind: .tv, tmdbID: 1001)
            let aura = try #require(try await Episode.query(on: app.db).filter(\.$name == "Die Aura des Todes").first())
            manualID = try await WatchService(db: app.db).markEpisode(userID: user.requireID(), episodeID: aura.requireID(),
                                                                      day: "2026-11-06", service: .netflix).id
        }) { app, user, headers in
            let mentalist = try await mapping(app, "The Mentalist")
            try await app.testing().test(.POST, "/import/mappings/\(mentalist.requireID())/reset", headers: headers) { res async in
                #expect(res.status == .ok)
            }
            let remaining = try await Watch.query(on: app.db).filter(\.$user.$id == user.requireID()).all()
            #expect(remaining.map(\.id) == [manualID])
            #expect(try await rows(app, containing: "The Mentalist").allSatisfy { $0.rowStatus == .pending && $0.$watch.id == nil })
            #expect(try await mapping(app, "The Mentalist").mappingStatus == .pending)
        }
    }

    @Test func changeRematchesToOtherTitle() async throws {
        try await withImported { app, user, headers in
            let mentalist = try await mapping(app, "The Mentalist")
            try await app.testing().test(.POST, "/import/mappings/\(mentalist.requireID())/change", headers: headers, beforeRequest: { req in
                try req.content.encode(AcceptInput(kind: "tv", tmdbID: 1002), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Mentalist (Neu)"))
            })
            _ = try await app.matchingWorker.processAll()
            let newTitle = try #require(try await Title.query(on: app.db).filter(\.$tmdbID == 1002).first())
            let watches = try await Watch.query(on: app.db).filter(\.$user.$id == user.requireID()).all()
            #expect(watches.count == 4)
            #expect(watches.allSatisfy { $0.$title.id == newTitle.id })
        }
    }

    @Test func assignUnmatchedRow() async throws {
        let tmdb = ImportPageTests.fake()
        tmdb.addSeries(TMDBSeries(id: 1001, name: "The Mentalist", originalName: "The Mentalist", year: 2008, posterPath: nil,
                                  status: "Ended", seasonNumbers: [1, 4]),
                       episodes: [1: ["Pilot"], 4: ["Scharlachrote Briefe", "Die Aura des Todes"]], airDate: "2011-01-01")
        try await withImported(tmdb: tmdb) { app, user, headers in
            let row = try #require(try await rows(app, containing: "Shakespeare").first)
            #expect(row.rowStatus == .unmatched)
            try await app.testing().test(.GET, "/import", headers: headers) { res async in
                #expect(res.body.string.contains("Keine Lust auf Shakespeare"))
            }
            let target = try #require(try await Episode.query(on: app.db).filter(\.$name == "Scharlachrote Briefe").first())
            try await app.testing().test(.POST, "/import/rows/\(row.requireID())/assign", headers: headers, beforeRequest: { req in
                try req.content.encode(AssignInput(episodeID: try target.requireID()), as: .urlEncodedForm)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            let reloaded = try #require(try await NetflixRow.find(row.requireID(), on: app.db))
            #expect(reloaded.rowStatus == .matched)
            let watch = try #require(try await Watch.find(reloaded.$watch.id, on: app.db))
            #expect(watch.$episode.id == target.id)
            #expect(watch.watchedOn == "2026-11-07")
        }
    }

    @Test func foreignMappingIs404() async throws {
        try await withImported { app, _, _ in
            let rick = try await mapping(app, "Rick and Morty")
            try await createUser(app, "other")
            let otherHeaders = try await login(app, "other").adding(.htmx)
            try await app.testing().test(.POST, "/import/mappings/\(rick.requireID())/ignore", headers: otherHeaders) { res async in
                #expect(res.status == .notFound)
            }
            let row = try #require(try await rows(app, containing: "Rick").first)
            try await app.testing().test(.POST, "/import/rows/\(row.requireID())/ignore", headers: otherHeaders) { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test func progressShowsWaitingCount() async throws {
        try await withImported { app, user, headers in
            let review = try await NetflixMapping.query(on: app.db).filter(\.$status == MappingStatus.review.rawValue).all().compactMap(\.id)
            let waiting = try await NetflixRow.query(on: app.db).filter(\.$user.$id == user.requireID())
                .filter(\.$status == RowStatus.pending.rawValue).filter(\.$mapping.$id ~~ review).count()
            #expect(waiting > 0)
            try await app.testing().test(.GET, "/import/progress", headers: headers) { res async in
                #expect(res.body.string.contains("\(waiting) Zeilen warten auf Prüfung"))
            }
        }
    }

    @Test func progressShowsTMDBError() async throws {
        let tmdb = ImportPageTests.fake()
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            tmdb.failure = .unauthorized
            _ = try await app.matchingWorker.processAll()
            let headers = try await login(app, "pat").adding(.htmx)
            try await app.testing().test(.GET, "/import/progress", headers: headers) { res async in
                #expect(res.body.string.contains("TMDB nicht erreichbar"))
            }
        }
    }

    @Test func progressPollsOnlyWhileRunning() {
        let running = ImportProgress(isRunning: true, pendingRows: 10, waitingForReview: 0, lastError: nil).render()
        let idle = ImportProgress(isRunning: false, pendingRows: 0, waitingForReview: 2, lastError: nil).render()
        #expect(running.contains("every 2s"))
        #expect(running.contains("Zuordnung läuft"))
        #expect(!idle.contains("every 2s"))
        #expect(idle.contains("2 Zeilen warten auf Prüfung"))
    }
}

@Suite("ImportPageLight")
struct ImportPageLightTests {
    static func withUnmatched(_ body: (Application, NetflixRow, HTTPHeaders) async throws -> Void) async throws {
        let tmdb = ImportPageTests.fake()
        tmdb.addSeries(TMDBSeries(id: 1001, name: "The Mentalist", originalName: "The Mentalist", year: 2008, posterPath: nil,
                                  status: "Ended", seasonNumbers: [1, 4]),
                       episodes: [1: ["Pilot"], 4: ["Scharlachrote Briefe", "Die Aura des Todes"]], airDate: "2011-01-01")
        try await withTestApp(tmdb: tmdb) { app in
            let user = try await createUser(app, "pat")
            _ = try await ImportService(db: app.db).ingest(text: try fixtureText(), filename: "a.csv", userID: user.requireID())
            _ = try await app.matchingWorker.processAll()
            let row = try #require(try await NetflixRow.query(on: app.db).all().first { $0.rawTitle.contains("Shakespeare") })
            try await body(app, row, try await login(app, "pat").adding(.htmx))
        }
    }

    @Test func pageDoesNotEmbedEpisodeLists() async throws {
        try await Self.withUnmatched { app, row, headers in
            try await app.testing().test(.GET, "/import", headers: headers) { res async in
                #expect(res.body.string.contains("Keine Lust auf Shakespeare"))
                #expect(res.body.string.contains("/import/rows/\(row.id!.uuidString)/options"))
                #expect(!res.body.string.contains("Scharlachrote Briefe"))
            }
        }
    }

    @Test func optionsAreLoadedOnDemand() async throws {
        try await Self.withUnmatched { app, row, headers in
            try await app.testing().test(.GET, "/import/rows/\(row.id!.uuidString)/options", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("S04E01 · Scharlachrote Briefe"))
                #expect(res.body.string.contains("/import/rows/\(row.id!.uuidString)/assign"))
            }
            try await createUser(app, "other")
            let other = try await login(app, "other").adding(.htmx)
            try await app.testing().test(.GET, "/import/rows/\(row.id!.uuidString)/options", headers: other) { res async in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test func finishedRunOffersReloadInsteadOfForcingIt() async throws {
        try await Self.withUnmatched { app, _, headers in
            try await app.testing().test(.GET, "/import/progress?polling=1", headers: headers) { res async in
                #expect(res.headers.first(name: "HX-Refresh") == nil)
                #expect(res.body.string.contains("Seite aktualisieren"))
            }
        }
    }
}

@Suite("CandidateLabel")
struct CandidateLabelTests {
    @Test func candidateLabel() {
        let html = CandidateList(mappingID: UUID(), results: [
            TMDBSearchResult(id: 1, kind: .movie, name: "Aftermath", originalName: nil, year: 2021, posterPath: nil),
        ], action: "accept", target: "x").render()
        #expect(html.contains("Aftermath (2021) · "))
        #expect(html.contains("Übernehmen"))
        #expect(!html.contains("Film"))
        #expect(!html.contains("FilmÜbernehmen"))
    }
}
