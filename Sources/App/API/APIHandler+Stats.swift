import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    func getStats(_ input: Operations.getStats.Input) async throws -> Operations.getStats.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let stats = try await StatsService(db: request.db, today: request.watches.today())
            .stats(userID: user.requireID(), year: input.query.year)
        func period(_ p: PeriodStats) -> Components.Schemas.Period {
            .init(movies: p.movies, series: p.series, episodes: p.episodes, minutes: p.minutes, unknownRuntime: p.unknownRuntime)
        }
        return .ok(.init(body: .json(.init(
            year: stats.year, period: period(stats.period), previous: stats.previous.map(period),
            chart: stats.chart.map {
                .init(label: $0.label, seriesMinutes: $0.seriesMinutes, movieMinutes: $0.movieMinutes, episodes: $0.episodes, movies: $0.movies)
            },
            services: stats.services.map { .init(service: $0.service.flatMap { Components.Schemas.Service(rawValue: $0.rawValue) }, minutes: $0.minutes) },
            topSeries: stats.topSeries.map {
                .init(tmdbId: $0.tmdbID, name: $0.name, posterPath: $0.posterPath, episodes: $0.episodes, minutes: $0.minutes, rating: $0.rating)
            },
            total: period(stats.total), undated: period(stats.undated),
            years: stats.years.map { year in
                .init(year: year.year, stats: period(year.stats), months: year.months.map { .init(month: $0.month, stats: period($0.stats)) })
            },
            ratings: stats.ratings.map { .init(rating: $0.rating, movies: $0.movies, series: $0.series, minutes: $0.minutes) },
            missingRuntimeTitles: stats.missingRuntimeTitles))))
    }
}
