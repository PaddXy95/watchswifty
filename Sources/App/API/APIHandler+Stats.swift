import Fluent
import Foundation
import Vapor
import WatchSwiftyAPI

extension APIHandler {
    func getStats(_ input: Operations.getStats.Input) async throws -> Operations.getStats.Output {
        let user = try APIContext.requireUser()
        let request = try APIContext.request()
        let stats = try await StatsService(db: request.db, today: request.watches.today())
            .stats(userID: user.requireID(), ratingYear: input.query.year)
        func period(_ p: PeriodStats) -> Components.Schemas.Period {
            .init(movies: p.movies, series: p.series, episodes: p.episodes, minutes: p.minutes, unknownRuntime: p.unknownRuntime)
        }
        return .ok(.init(body: .json(.init(
            total: period(stats.total), undated: period(stats.undated),
            years: stats.years.map { year in
                .init(year: year.year, stats: period(year.stats), months: year.months.map { .init(month: $0.month, stats: period($0.stats)) })
            },
            ratings: stats.ratings.map { .init(rating: $0.rating, movies: $0.movies, series: $0.series, minutes: $0.minutes) },
            missingRuntimeTitles: stats.missingRuntimeTitles))))
    }
}
