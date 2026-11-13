@testable import App
import Fluent
import NIOConcurrencyHelpers
import Testing
import VaporTesting

@Suite("Runtimes")
struct RuntimeTests {
    @Test func decodesRuntimes() throws {
        let movie = try LiveTMDBClient.decodeMovie(Data(#"{"id":603,"title":"Matrix","runtime":136}"#.utf8))
        #expect(movie.runtime == 136)
        #expect(try LiveTMDBClient.decodeMovie(Data(#"{"id":1,"title":"X","runtime":0}"#.utf8)).runtime == nil)
        #expect(try LiveTMDBClient.decodeMovie(Data(#"{"id":1,"title":"X"}"#.utf8)).runtime == nil)

        let series = try LiveTMDBClient.decodeSeries(Data(#"{"id":1,"name":"X","episode_run_time":[42,45],"seasons":[]}"#.utf8))
        #expect(series.episodeRunTime == 42)
        #expect(try LiveTMDBClient.decodeSeries(Data(#"{"id":1,"name":"X","episode_run_time":[],"seasons":[]}"#.utf8)).episodeRunTime == nil)

        let episodes = try LiveTMDBClient.decodeSeason(Data(#"{"episodes":[{"id":1,"episode_number":1,"season_number":1,"name":"A","runtime":51},{"id":2,"episode_number":2,"season_number":1,"name":"B","runtime":null},{"id":3,"episode_number":3,"season_number":1,"name":"C"}]}"#.utf8))
        #expect(episodes.map(\.runtime) == [51, nil, nil])
    }

    @Test func refreshStoresRuntimes() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.addSeries(TMDBSeries(id: 1, name: "Serie", originalName: nil, year: 2020, posterPath: nil, status: "Ended",
                                  seasonNumbers: [1], episodeRunTime: 45), episodes: [:])
        tmdb.setSeason(seriesID: 1, number: 1, [
            TMDBEpisode(id: 11, season: 1, number: 1, name: "A", airDate: "2020-01-01", runtime: 58),
            TMDBEpisode(id: 12, season: 1, number: 2, name: "B", airDate: "2020-01-08"),
        ])
        tmdb.addSeries(TMDBSeries(id: 2, name: "Ohne", originalName: nil, year: 2020, posterPath: nil, status: "Ended",
                                  seasonNumbers: []), episodes: [:])
        tmdb.addMovie(TMDBMovie(id: 603, name: "Matrix", originalName: nil, year: 1999, posterPath: nil, runtime: 136))
        tmdb.addMovie(TMDBMovie(id: 604, name: "Unbekannt", originalName: nil, year: 1999, posterPath: nil))
        try await withTestApp(tmdb: tmdb) { app in
            let catalog = CatalogService(db: app.db, tmdb: tmdb)
            let series = try await catalog.title(kind: .tv, tmdbID: 1)
            #expect(series.runtime == 45)
            #expect(try await catalog.episodes(of: series.requireID()).map(\.runtime) == [58, 0])
            #expect(try await catalog.title(kind: .tv, tmdbID: 2).runtime == 0)
            #expect(try await catalog.title(kind: .movie, tmdbID: 603).runtime == 136)
            #expect(try await catalog.title(kind: .movie, tmdbID: 604).runtime == 0)
        }
    }

    @Test func missingRuntimeListsWatchedTitlesOnly() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let watched = try await seedMovie(app, tmdbID: 1)
            _ = try await seedMovie(app, tmdbID: 2)   // nobody watched it
            let known = try await seedMovie(app, tmdbID: 3, runtime: 100)
            for title in [watched, known] {
                try await Watch(userID: user.requireID(), titleID: title.requireID(), episodeID: nil, watchedOn: "2026-01-01",
                                service: nil, origin: .manual).save(on: app.db)
            }
            #expect(try await titlesMissingDetails(on: app.db).map(\.tmdbID) == [1])
        }
    }

    @Test func missingGenresCountAsMissingDetails() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let title = try await seedMovie(app, tmdbID: 7, runtime: 100, genres: nil)
            try await Watch(userID: user.requireID(), titleID: title.requireID(), episodeID: nil, watchedOn: "2026-01-01",
                            service: nil, origin: .manual).save(on: app.db)
            #expect(try await titlesMissingDetails(on: app.db).map(\.tmdbID) == [7])
        }
    }

    @Test func backfillRefreshesMissingRuntimes() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.addMovie(TMDBMovie(id: 603, name: "Matrix", originalName: nil, year: 1999, posterPath: nil, runtime: 136))
        let tokens = NIOLockedValueBox<[String]>([])
        let provider = TMDBProvider { token in
            tokens.withLockedValue { $0.append(token) }
            return tmdb
        }
        try await withTestApp(tmdb: tmdb) { app in
            _ = try await createUser(app, "other", tmdbToken: "other-token")
            let watcher = try await createUser(app, "pat", tmdbToken: "pat-token")
            let movie = try await seedMovie(app, tmdbID: 603)
            try await Watch(userID: watcher.requireID(), titleID: movie.requireID(), episodeID: nil, watchedOn: nil,
                            service: nil, origin: .manual).save(on: app.db)

            #expect(await backfillDetails(db: app.db, provider: provider, cipher: app.tokenCipher, logger: app.logger) == 1)
            #expect(tokens.withLockedValue { $0 } == ["pat-token"])
            #expect(try await Title.find(movie.requireID(), on: app.db)?.runtime == 136)

            #expect(await backfillDetails(db: app.db, provider: provider, cipher: app.tokenCipher, logger: app.logger) == 0)
            #expect(tmdb.calls.filter { $0 == "movie:603" }.count == 1)
        }
    }

    @Test func detailPageFetchesMissingRuntime() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.addMovie(TMDBMovie(id: 603, name: "Matrix", originalName: nil, year: 1999, posterPath: nil, overview: "Neo.",
                                imdbID: "tt0133093", runtime: 136))
        try await withTestApp(tmdb: tmdb) { app in
            _ = try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            let movie = try await seedMovie(app, tmdbID: 603, name: "Matrix")
            movie.overview = "Neo."
            movie.imdbID = "tt0133093"
            try await movie.save(on: app.db)   // fresh cache with details, but cached before runtimes existed

            try await app.testing().test(.GET, "/movie/603", headers: headers) { res async in
                #expect(res.status == .ok)
            }
            #expect(tmdb.calls.contains("movie:603"))
            #expect(try await Title.find(movie.requireID(), on: app.db)?.runtime == 136)
        }
    }
}

@Suite("RuntimeDisplay")
struct RuntimeDisplayTests {
    @Test func moviePageShowsRuntime() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.addMovie(TMDBMovie(id: 603, name: "Matrix", originalName: nil, year: 1999, posterPath: nil, overview: "Neo.", runtime: 136))
        tmdb.addMovie(TMDBMovie(id: 604, name: "Ohne", originalName: nil, year: 1999, posterPath: nil, overview: "?"))
        try await withTestApp(tmdb: tmdb) { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/movie/603", headers: headers) { res async in
                #expect(res.body.string.contains(#"<p class="muted title-meta">2 Std. 16 Min.</p>"#))
            }
            try await app.testing().test(.GET, "/movie/604", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(!res.body.string.contains("title-meta"))   // TMDB knows no runtime
            }
        }
    }

    @Test func episodeRowsShowRuntime() async throws {
        let tmdb = FakeTMDBClient()
        tmdb.addSeries(TMDBSeries(id: 7, name: "Serie", originalName: nil, year: nil, posterPath: nil, status: nil,
                                  seasonNumbers: [1], overview: "Serie.", episodeRunTime: 45), episodes: [:])
        tmdb.setSeason(seriesID: 7, number: 1, [
            TMDBEpisode(id: 71, season: 1, number: 1, name: "Pilot", airDate: "2020-01-01", overview: "A", runtime: 51),
            TMDBEpisode(id: 72, season: 1, number: 2, name: "Zwei", airDate: "2020-01-08", overview: "B"),
        ])
        try await withTestApp(tmdb: tmdb) { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/tv/7", headers: headers) { res async in
                let body = res.body.string
                #expect(body.contains(#"<span class="runtime">51 Min.</span>"#))
                #expect(body.components(separatedBy: #"class="runtime""#).count == 2)   // unknown runtime: nothing shown
            }
        }
    }
}
