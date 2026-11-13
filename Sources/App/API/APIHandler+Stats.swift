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
        func movie(_ m: MovieStat) -> Components.Schemas.MovieStat {
            .init(tmdbId: m.tmdbID, name: m.name, posterPath: m.posterPath, watches: m.watches, minutes: m.minutes, rating: m.rating)
        }
        func period(_ p: PeriodStats) -> Components.Schemas.Period {
            .init(movies: p.movies, series: p.series, episodes: p.episodes, minutes: p.minutes, unknownRuntime: p.unknownRuntime)
        }
        return .ok(.init(body: .json(.init(
            year: stats.year, period: period(stats.period), previous: stats.previous.map(period),
            chart: stats.chart.map {
                .init(label: $0.label, seriesMinutes: $0.seriesMinutes, movieMinutes: $0.movieMinutes, episodes: $0.episodes, movies: $0.movies)
            },
            services: stats.services.map {
                .init(service: $0.service.flatMap { Components.Schemas.Service(rawValue: $0.rawValue) }, minutes: $0.minutes,
                      episodes: $0.episodes, movies: $0.movies)
            },
            topSeries: stats.topSeries.map {
                .init(tmdbId: $0.tmdbID, name: $0.name, posterPath: $0.posterPath, episodes: $0.episodes, minutes: $0.minutes, rating: $0.rating)
            },
            longestMovies: stats.longestMovies.map(movie),
            mostWatchedMovies: stats.mostWatchedMovies.map(movie),
            mostWatchedEpisodes: stats.mostWatchedEpisodes.map {
                .init(tmdbId: $0.tmdbID, seriesName: $0.seriesName, posterPath: $0.posterPath, season: $0.season, number: $0.number,
                      name: $0.name, watches: $0.watches)
            },
            mostCompletedSeries: stats.mostCompletedSeries.map {
                .init(tmdbId: $0.tmdbID, name: $0.name, posterPath: $0.posterPath, completions: $0.completions, rating: $0.rating)
            },
            genres: stats.genres.compactMap { stat in
                Components.Schemas.Genre(rawValue: stat.genre.rawValue).map {
                    .init(genre: $0, seriesMinutes: stat.seriesMinutes, movieMinutes: stat.movieMinutes, series: stat.series, movies: stat.movies)
                }
            },
            total: period(stats.total), undated: period(stats.undated),
            years: stats.years.map { year in
                .init(year: year.year, stats: period(year.stats), months: year.months.map { .init(month: $0.month, stats: period($0.stats)) })
            },
            ratings: stats.ratings.map { .init(rating: $0.rating, movies: $0.movies, series: $0.series, minutes: $0.minutes) },
            missingRuntimeTitles: stats.missingRuntimeTitles))))
    }
}
