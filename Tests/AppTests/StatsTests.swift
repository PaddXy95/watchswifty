@testable import App
import Fluent
import Testing
import VaporTesting

@Suite("Stats")
struct StatsTests {
    func watch(_ app: Application, _ user: User, _ title: Title, _ episode: Episode? = nil, on date: String?) async throws {
        try await Watch(userID: user.requireID(), titleID: title.requireID(), episodeID: episode?.requireID(), watchedOn: date,
                        service: nil, origin: .manual).save(on: app.db)
    }

    func rate(_ app: Application, _ user: User, _ title: Title, _ rating: Int) async throws {
        try await WatchService(db: app.db).setRating(userID: user.requireID(), titleID: title.requireID(), rating: rating)
    }

    func stats(_ app: Application, _ user: User, ratingYear: Int? = nil) async throws -> Stats {
        try await StatsService(db: app.db, today: "2026-11-07").stats(userID: user.requireID(), year: ratingYear)
    }

    @Test func statsTotals() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let matrix = try await seedMovie(app, tmdbID: 1, runtime: 120)
            let heat = try await seedMovie(app, tmdbID: 2, runtime: 90)
            let show = try await seedSeries(app, tmdbID: 3, seasons: [1: 3], runtime: 45, episodeRuntimes: ["1x1": 50, "1x3": 50])
            try await watch(app, user, matrix, on: "2026-01-10")
            try await watch(app, user, matrix, on: "2026-03-01")   // rewatch: counted once as a movie, twice in time
            try await watch(app, user, heat, on: "2025-05-05")
            for number in 1...3 { try await watch(app, user, show, try await episode(app, show, 1, number), on: "2026-02-0\(number)") }

            let total = try await stats(app, user).total
            #expect(total == PeriodStats(movies: 2, series: 1, episodes: 3, minutes: 120 * 2 + 90 + 50 + 45 + 50, unknownRuntime: 0))
        }
    }

    @Test func episodeFallsBackToSeriesRuntime() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 3, seasons: [1: 2], runtime: 45, episodeRuntimes: ["1x1": 0])
            try await watch(app, user, show, try await episode(app, show, 1, 1), on: "2026-02-01")   // 0 = unknown → 45
            try await watch(app, user, show, try await episode(app, show, 1, 2), on: "2026-02-02")   // nil → 45
            #expect(try await stats(app, user).total.minutes == 90)
        }
    }

    @Test func unknownRuntimeCounted() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let unknown = try await seedMovie(app, tmdbID: 1, runtime: 0)
            let notLoaded = try await seedMovie(app, tmdbID: 2)
            try await watch(app, user, unknown, on: "2026-01-01")
            try await watch(app, user, notLoaded, on: "2026-01-02")
            let result = try await stats(app, user)
            #expect(result.total.minutes == 0)
            #expect(result.total.unknownRuntime == 2)
            #expect(result.missingRuntimeTitles == 1)
        }
    }

    @Test func statsPerYearAndMonth() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let show = try await seedSeries(app, tmdbID: 3, seasons: [1: 2], runtime: 30)
            try await watch(app, user, show, try await episode(app, show, 1, 1), on: "2025-12-30")
            try await watch(app, user, show, try await episode(app, show, 1, 2), on: "2026-01-02")

            let years = try await stats(app, user).years
            #expect(years.map(\.year) == [2026, 2025])
            #expect(years[0].stats == PeriodStats(movies: 0, series: 1, episodes: 1, minutes: 30, unknownRuntime: 0))
            #expect(years[1].stats == PeriodStats(movies: 0, series: 1, episodes: 1, minutes: 30, unknownRuntime: 0))
            #expect(years[0].months.map(\.month) == Array(1...11))   // current year: up to this month
            #expect(years[0].months[0].stats.episodes == 1)
            #expect(years[1].months.map(\.month) == Array(1...12))
            #expect(years[1].months[11].stats.series == 1)
            #expect(years[1].months[0].stats == PeriodStats())
        }
    }

    @Test func undatedOnlyInTotals() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let movie = try await seedMovie(app, tmdbID: 1, runtime: 100)
            try await watch(app, user, movie, on: nil)
            let result = try await stats(app, user)
            #expect(result.total.movies == 1)
            #expect(result.undated == PeriodStats(movies: 1, series: 0, episodes: 0, minutes: 100, unknownRuntime: 0))
            #expect(result.years.isEmpty)
        }
    }

    @Test func ratingBreakdown() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let rated = try await seedMovie(app, tmdbID: 1, runtime: 100)
            let unrated = try await seedMovie(app, tmdbID: 2, runtime: 80)
            let show = try await seedSeries(app, tmdbID: 3, seasons: [1: 2], runtime: 40)
            try await watch(app, user, rated, on: "2026-01-01")
            try await watch(app, user, unrated, on: "2025-01-01")
            try await watch(app, user, show, try await episode(app, show, 1, 1), on: "2026-02-01")
            try await watch(app, user, show, try await episode(app, show, 1, 2), on: "2026-02-02")
            try await rate(app, user, rated, 8)
            try await rate(app, user, show, 8)

            let all = try await stats(app, user).ratings
            #expect(all.map(\.rating) == [10, 9, 8, 7, 6, 5, 4, 3, 2, 1, nil])
            #expect(all[2] == RatingStats(rating: 8, movies: 1, series: 1, minutes: 180))
            #expect(all[10] == RatingStats(rating: nil, movies: 1, series: 0, minutes: 80))

            let only2025 = try await stats(app, user, ratingYear: 2025).ratings
            #expect(only2025[2] == RatingStats(rating: 8, movies: 0, series: 0, minutes: 0))
            #expect(only2025[10] == RatingStats(rating: nil, movies: 1, series: 0, minutes: 80))
        }
    }

    @Test func statsIsolatedPerUser() async throws {
        try await withTestApp { app in
            let pat = try await createUser(app, "pat")
            let other = try await createUser(app, "other")
            let movie = try await seedMovie(app, tmdbID: 1, runtime: 100)
            try await watch(app, user: other, movie)
            #expect(try await stats(app, pat).total == PeriodStats())
        }
    }

    func watch(_ app: Application, user: User, _ title: Title) async throws {
        try await watch(app, user, title, on: "2026-01-01")
    }

    @Test func formatDurationExamples() {
        #expect(formatDuration(minutes: 0) == "0 Min.")
        #expect(formatDuration(minutes: 45) == "45 Min.")
        #expect(formatDuration(minutes: 180) == "3 Std.")
        #expect(formatDuration(minutes: 200) == "3 Std. 20 Min.")
        #expect(formatDuration(minutes: 600) == "10 Std.")
        #expect(formatDuration(minutes: 18_745) == "312 Std.")
        #expect(formatDuration(minutes: 74_400) == "1.240 Std.")
    }

    @Test func statsPageRenders() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            let movie = try await seedMovie(app, tmdbID: 1, name: "Matrix", runtime: 120)
            let other = try await seedMovie(app, tmdbID: 2, runtime: 60)
            try await watch(app, user, movie, on: "2026-01-10")
            try await watch(app, user, other, on: nil)
            try await rate(app, user, movie, 9)

            try await app.testing().test(.GET, "/stats", headers: headers) { res async in
                #expect(res.status == .ok)
                let body = res.body.string
                #expect(body.contains(#"<a href="/stats" class="active" aria-current="page">Statistik</a>"#))
                #expect(body.contains("Pro Jahr"))
                #expect(body.contains("Januar"))
                #expect(body.contains("ohne Datum"))
                #expect(body.contains("Nach Bewertung"))
                #expect(body.contains("★ 9"))
                #expect(body.contains("3 Std."))   // total: 120 + 60 minutes
            }
            try await app.testing().test(.GET, "/stats?year=2026", headers: headers) { res async in
                #expect(res.body.string.contains(#"<a href="/stats?year=2026" class="active""#))
            }
            try await app.testing().test(.GET, "/stats?year=abc", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains(#"<a href="/stats" class="active" aria-current="true">Alle Jahre"#))
            }
        }
    }

    @Test func statsPageEmptyState() async throws {
        try await withTestApp { app in
            _ = try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/stats", headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Noch nichts gesehen"))
            }
        }
    }
}

@Suite("StatsDashboard")
struct StatsDashboardTests {
    func watch(_ app: Application, _ user: User, _ title: Title, _ episode: Episode? = nil, on date: String?,
               service: StreamingService? = nil) async throws {
        try await Watch(userID: user.requireID(), titleID: title.requireID(), episodeID: episode?.requireID(), watchedOn: date,
                        service: service, origin: .manual).save(on: app.db)
    }

    func stats(_ app: Application, _ user: User, year: Int?) async throws -> Stats {
        try await StatsService(db: app.db, today: "2026-11-07").stats(userID: user.requireID(), year: year)
    }

    /// 2025: movie (100 min). 2026: series episodes in Jan (2×45) and Mar (45), movie in Mar (120), one undated movie.
    func seed(_ app: Application, _ user: User) async throws {
        let old = try await seedMovie(app, tmdbID: 1, name: "Alt", runtime: 100)
        let new = try await seedMovie(app, tmdbID: 2, name: "Neu", runtime: 120)
        let undated = try await seedMovie(app, tmdbID: 3, name: "Ohne", runtime: 90)
        let show = try await seedSeries(app, tmdbID: 4, name: "Dark", seasons: [1: 3], runtime: 45)
        try await watch(app, user, old, on: "2025-05-05", service: .netflix)
        try await watch(app, user, show, try await episode(app, show, 1, 1), on: "2026-01-10", service: .netflix)
        try await watch(app, user, show, try await episode(app, show, 1, 2), on: "2026-01-11", service: .netflix)
        try await watch(app, user, show, try await episode(app, show, 1, 3), on: "2026-03-01", service: .primeVideo)
        try await watch(app, user, new, on: "2026-03-02", service: .cinema)
        try await watch(app, user, undated, on: nil)
    }

    @Test func periodAndChartForYear() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            try await seed(app, user)
            let result = try await stats(app, user, year: 2026)
            #expect(result.year == 2026)
            #expect(result.period == PeriodStats(movies: 1, series: 1, episodes: 3, minutes: 255, unknownRuntime: 0))
            #expect(result.chart.count == 11)   // Jan … Nov (today 2026-11-07)
            #expect(result.chart[0] == ChartBar(label: "Jan", seriesMinutes: 90, movieMinutes: 0, episodes: 2, movies: 0))
            #expect(result.chart[2] == ChartBar(label: "Mär", seriesMinutes: 45, movieMinutes: 120, episodes: 1, movies: 1))
        }
    }

    @Test func chartPerYearForAllYears() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            try await seed(app, user)
            let result = try await stats(app, user, year: nil)
            #expect(result.year == nil)
            #expect(result.period.movies == 3)   // undated counts in „Alle Jahre“
            #expect(result.chart.map(\.label) == ["2025", "2026"])
            #expect(result.chart[0].movieMinutes == 100)
            #expect(result.chart[1].seriesMinutes == 135)
            #expect(result.previous == nil)
        }
    }

    @Test func servicesShareByMinutes() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            try await seed(app, user)
            let services = try await stats(app, user, year: 2026).services
            #expect(services == [ServiceShare(service: .cinema, minutes: 120), ServiceShare(service: .netflix, minutes: 90),
                                 ServiceShare(service: .primeVideo, minutes: 45)])
            let all = try await stats(app, user, year: nil).services
            #expect(all.contains(ServiceShare(service: nil, minutes: 90)))   // undated movie without service
        }
    }

    @Test func topSeriesByTime() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            try await seed(app, user)
            let other = try await seedSeries(app, tmdbID: 5, name: "Kurz", seasons: [1: 1], runtime: 20)
            try await watch(app, user, other, try await episode(app, other, 1, 1), on: "2026-02-01")
            try await WatchService(db: app.db).setRating(userID: user.requireID(), titleID: try #require(try await Title.query(on: app.db).filter(\.$tmdbID == 4).first()).requireID(), rating: 9)
            let top = try await stats(app, user, year: 2026).topSeries
            #expect(top.map(\.name) == ["Dark", "Kurz"])
            #expect(top.first == TopSeries(tmdbID: 4, name: "Dark", posterPath: nil, episodes: 3, minutes: 135, rating: 9))
            #expect(try await stats(app, user, year: 2025).topSeries.isEmpty)
        }
    }

    @Test func previousYearDelta() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            try await seed(app, user)
            #expect(try await stats(app, user, year: 2026).previous?.minutes == 100)
            #expect(try await stats(app, user, year: 2025).previous == nil)
        }
    }

    @Test func formatDeltaExamples() {
        #expect(formatDelta(118, 100) == "+18 %")
        #expect(formatDelta(94, 100) == "−6 %")
        #expect(formatDelta(100, 100) == "±0 %")
        #expect(formatDelta(5, 0) == nil)
    }

    @Test func statsPageShowsDashboard() async throws {
        try await withTestApp { app in
            let user = try await createUser(app, "pat")
            try await seed(app, user)
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/stats?year=2026", headers: headers) { res async in
                let body = res.body.string
                #expect(res.status == .ok)
                #expect(body.contains(#"<a href="/stats?year=2026" class="active""#))
                #expect(body.contains(#"<a href="/stats""#))
                #expect(body.contains("Zeit pro Monat"))
                #expect(body.contains("<svg"))
                #expect(body.contains("<title>Mär: 2 Std. 45 Min."))
                #expect(body.contains("Dienste"))
                #expect(body.contains("Kino"))
                #expect(body.contains("Meistgesehen"))
                #expect(body.contains("Dark"))
                #expect(body.contains("+155 %"))   // 255 vs 100 minutes
                #expect(body.contains("Alle Zahlen"))
            }
        }
    }
}
