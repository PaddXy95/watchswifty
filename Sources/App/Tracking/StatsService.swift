import Fluent
import Foundation
import SQLKit
import Vapor

/// Counts for one period. Movies and series are distinct per period; episodes and minutes count every viewing.
struct PeriodStats: Equatable, Sendable {
    var movies = 0
    var series = 0
    var episodes = 0
    var minutes = 0
    /// Viewings whose runtime TMDB does not know (or that is not loaded yet); not part of `minutes`.
    var unknownRuntime = 0

    var isEmpty: Bool { movies == 0 && series == 0 && episodes == 0 }
}

struct MonthStats: Equatable, Sendable {
    let month: Int
    let stats: PeriodStats
}

struct YearStats: Equatable, Sendable {
    let year: Int
    let stats: PeriodStats
    /// January first; in the current year only up to the current month.
    let months: [MonthStats]
}

struct RatingStats: Equatable, Sendable {
    let rating: Int?
    var movies = 0
    var series = 0
    var minutes = 0
}

/// One column of „Zeit pro Monat“ (a month of the selected year, or a year for „Alle Jahre“).
struct ChartBar: Equatable, Sendable {
    let label: String
    var seriesMinutes = 0
    var movieMinutes = 0
    var episodes = 0
    var movies = 0
}

/// Watch time on one service (nil = no service given).
struct ServiceShare: Equatable, Sendable {
    let service: StreamingService?
    let minutes: Int
    var episodes = 0
    var movies = 0
}

/// A movie in „Längste Filme“ / „Meistgesehene Filme“: all its viewings in the period.
struct MovieStat: Equatable, Sendable {
    let tmdbID: Int
    let name: String
    let posterPath: String?
    let watches: Int
    let minutes: Int
    let rating: Int?
}

/// An episode in „Meistgesehene Folgen“.
struct EpisodeStat: Equatable, Sendable {
    let tmdbID: Int
    let seriesName: String
    let posterPath: String?
    let code: String
    let season: Int
    let number: Int
    let name: String
    let watches: Int
}

/// A series in „Meistgesehene Serien“: how often every aired regular episode was watched (all years).
struct CompletedSeries: Equatable, Sendable {
    let tmdbID: Int
    let name: String
    let posterPath: String?
    let completions: Int
    let rating: Int?
}

/// Time and distinct titles per genre in the period; a title counts for each of its genres.
struct GenreStat: Equatable, Sendable {
    let genre: Genre
    var seriesMinutes = 0
    var movieMinutes = 0
    var series = 0
    var movies = 0
}

struct TopSeries: Equatable, Sendable {
    let tmdbID: Int
    let name: String
    let posterPath: String?
    let episodes: Int
    let minutes: Int
    let rating: Int?
}

struct Stats: Sendable {
    /// Selected year, nil = all years.
    var year: Int? = nil
    /// The selected range (all years include undated viewings).
    var period = PeriodStats()
    /// The year before the selected one, only when it has viewings.
    var previous: PeriodStats? = nil
    var chart: [ChartBar] = []
    /// By minutes, largest first.
    var services: [ServiceShare] = []
    /// At most 5 series, by minutes.
    var topSeries: [TopSeries] = []
    /// Up to 5 movies by the time of all their viewings (runtime known).
    var longestMovies: [MovieStat] = []
    /// Up to 5 movies watched at least twice, most viewings first.
    var mostWatchedMovies: [MovieStat] = []
    /// Up to 5 episodes watched at least twice.
    var mostWatchedEpisodes: [EpisodeStat] = []
    /// Up to 5 series watched completely at least once – always over all years.
    var mostCompletedSeries: [CompletedSeries] = []
    /// Genres by time in the period.
    var genres: [GenreStat] = []
    let total: PeriodStats
    let undated: PeriodStats
    /// Newest first.
    let years: [YearStats]
    /// Ratings 10 … 1, then unrated (for the selected range).
    let ratings: [RatingStats]
    /// Watched titles whose runtimes are not loaded from TMDB yet.
    let missingRuntimeTitles: Int
}

/// Viewing statistics of one user, built from their watches and the cached TMDB runtimes.
struct StatsService {
    let db: any Database
    let today: String

    static let listLimit = 5

    private struct Viewing {
        let titleID: UUID
        let episodeID: UUID?
        let isEpisode: Bool
        let minutes: Int?
        let year: Int?
        let month: Int?
        let service: StreamingService?
    }

    private struct Tally {
        var movieIDs: Set<UUID> = []
        var seriesIDs: Set<UUID> = []
        var episodes = 0
        var minutes = 0
        var unknown = 0

        mutating func add(_ viewing: Viewing) {
            if viewing.isEpisode {
                seriesIDs.insert(viewing.titleID)
                episodes += 1
            } else {
                movieIDs.insert(viewing.titleID)
            }
            if let minutes = viewing.minutes { self.minutes += minutes } else { unknown += 1 }
        }

        var stats: PeriodStats {
            PeriodStats(movies: movieIDs.count, series: seriesIDs.count, episodes: episodes, minutes: minutes, unknownRuntime: unknown)
        }
    }

    static let monthLabels = ["Jan", "Feb", "Mär", "Apr", "Mai", "Jun", "Jul", "Aug", "Sep", "Okt", "Nov", "Dez"]

    /// `year` (nil = all years) selects the range for period, chart, services, ratings and top series; the yearly table
    /// (`years`, `undated`, `total`) always covers everything.
    func stats(userID: UUID, year selectedYear: Int?) async throws -> Stats {
        let watches = try await WatchRow.all(userID: userID, on: db)
        let titleIDs = Array(Set(watches.map(\.titleID)))
        let titles = titleIDs.isEmpty ? [] : try await Title.query(on: db).filter(\.$id ~~ titleIDs).all()
        let titleByID = Dictionary(titles.compactMap { title in title.id.map { ($0, title) } }, uniquingKeysWith: { a, _ in a })
        let episodeByID = try await watchedEpisodes(userID: userID)
        let entries = try await UserTitle.query(on: db).filter(\.$user.$id == userID).all()
        let ratingByTitle = Dictionary(entries.map { ($0.$title.id, $0.rating) }, uniquingKeysWith: { a, _ in a })

        let viewings: [Viewing] = watches.compactMap { watch in
            guard let title = titleByID[watch.titleID] else { return nil }
            let seriesRuntime = (title.runtime ?? 0) > 0 ? title.runtime : nil
            let minutes: Int?
            if let episodeID = watch.episodeID {
                let own = episodeByID[episodeID]?.info.runtime
                minutes = (own ?? 0) > 0 ? own : seriesRuntime
            } else if title.titleKind == .movie {
                minutes = seriesRuntime
            } else {
                return nil
            }
            let (year, month) = Self.yearMonth(watch.watchedOn)
            return Viewing(titleID: watch.titleID, episodeID: watch.episodeID, isEpisode: watch.episodeID != nil, minutes: minutes,
                           year: year, month: month, service: watch.service)
        }

        var total = Tally(), undated = Tally()
        var byYear: [Int: Tally] = [:]
        var byMonth: [Int: [Int: Tally]] = [:]
        var byRating: [Int?: Tally] = [:]
        for viewing in viewings {
            total.add(viewing)
            if let year = viewing.year, let month = viewing.month {
                byYear[year, default: Tally()].add(viewing)
                byMonth[year, default: [:]][month, default: Tally()].add(viewing)
            } else {
                undated.add(viewing)
            }
        }
        let inRange = viewings.filter { selectedYear == nil || $0.year == selectedYear }
        var period = Tally()
        var serviceTally: [StreamingService?: (minutes: Int, episodes: Int, movies: Int)] = [:]
        var seriesTally: [UUID: (episodes: Int, minutes: Int)] = [:]
        var movieTally: [UUID: (watches: Int, minutes: Int)] = [:]
        var episodeWatches: [UUID: Int] = [:]
        var genreTally: [Genre: (stat: GenreStat, seriesIDs: Set<UUID>, movieIDs: Set<UUID>)] = [:]
        for viewing in inRange {
            period.add(viewing)
            byRating[ratingByTitle[viewing.titleID] ?? nil, default: Tally()].add(viewing)
            var service = serviceTally[viewing.service] ?? (0, 0, 0)
            service.minutes += viewing.minutes ?? 0
            if viewing.isEpisode { service.episodes += 1 } else { service.movies += 1 }
            serviceTally[viewing.service] = service
            if viewing.isEpisode {
                let current = seriesTally[viewing.titleID] ?? (0, 0)
                seriesTally[viewing.titleID] = (current.episodes + 1, current.minutes + (viewing.minutes ?? 0))
                if let episodeID = viewing.episodeID { episodeWatches[episodeID, default: 0] += 1 }
            } else {
                let current = movieTally[viewing.titleID] ?? (0, 0)
                movieTally[viewing.titleID] = (current.watches + 1, current.minutes + (viewing.minutes ?? 0))
            }
            for genre in titleByID[viewing.titleID]?.genreList ?? [] {
                var entry = genreTally[genre] ?? (GenreStat(genre: genre), [], [])
                if viewing.isEpisode {
                    entry.stat.seriesMinutes += viewing.minutes ?? 0
                    entry.seriesIDs.insert(viewing.titleID)
                } else {
                    entry.stat.movieMinutes += viewing.minutes ?? 0
                    entry.movieIDs.insert(viewing.titleID)
                }
                genreTally[genre] = entry
            }
        }

        let (currentYear, currentMonth) = Self.yearMonth(today)
        let years = byYear.keys.sorted(by: >).map { year in
            let months = byMonth[year] ?? [:]
            let last = year == currentYear ? max(currentMonth ?? 12, months.keys.max() ?? 1) : 12
            return YearStats(year: year, stats: byYear[year]!.stats,
                             months: (1...last).map { MonthStats(month: $0, stats: months[$0]?.stats ?? PeriodStats()) })
        }
        let ratings = ((1...10).reversed().map { Optional($0) } + [nil]).map { rating in
            let stats = byRating[rating]?.stats ?? PeriodStats()
            return RatingStats(rating: rating, movies: stats.movies, series: stats.series, minutes: stats.minutes)
        }
        var result = Stats(total: total.stats, undated: undated.stats, years: years, ratings: ratings,
                           missingRuntimeTitles: titles.filter { $0.runtime == nil }.count)
        result.year = selectedYear
        result.period = period.stats
        if let selectedYear, let previous = byYear[selectedYear - 1] { result.previous = previous.stats }
        result.chart = Self.chart(inRange, year: selectedYear, years: byYear.keys.sorted(), monthCount: selectedYear.map { year in
            years.first { $0.year == year }?.months.count ?? (year == currentYear ? currentMonth ?? 12 : 12)
        })
        result.services = serviceTally.map { ServiceShare(service: $0.key, minutes: $0.value.minutes, episodes: $0.value.episodes,
                                                          movies: $0.value.movies) }
            .sorted { ($0.minutes, $0.episodes + $0.movies, $1.service?.label ?? "") > ($1.minutes, $1.episodes + $1.movies, $0.service?.label ?? "") }
        result.topSeries = seriesTally.compactMap { titleID, tally -> TopSeries? in
            guard let title = titleByID[titleID] else { return nil }
            return TopSeries(tmdbID: title.tmdbID, name: title.name, posterPath: title.posterPath, episodes: tally.episodes,
                             minutes: tally.minutes, rating: ratingByTitle[titleID] ?? nil)
        }.sorted { ($0.minutes, $0.episodes, $1.name) > ($1.minutes, $1.episodes, $0.name) }.prefix(Self.listLimit).map { $0 }

        let movies = movieTally.compactMap { titleID, tally -> MovieStat? in
            guard let title = titleByID[titleID] else { return nil }
            return MovieStat(tmdbID: title.tmdbID, name: title.name, posterPath: title.posterPath, watches: tally.watches,
                             minutes: tally.minutes, rating: ratingByTitle[titleID] ?? nil)
        }
        result.longestMovies = movies.filter { $0.minutes > 0 }
            .sorted { ($0.minutes, $0.watches, $1.name) > ($1.minutes, $1.watches, $0.name) }.prefix(Self.listLimit).map { $0 }
        result.mostWatchedMovies = movies.filter { $0.watches >= 2 }
            .sorted { ($0.watches, $0.minutes, $1.name) > ($1.watches, $1.minutes, $0.name) }.prefix(Self.listLimit).map { $0 }

        result.mostWatchedEpisodes = episodeWatches.filter { $0.value >= 2 }.compactMap { episodeID, watches -> EpisodeStat? in
            guard let (titleID, episode) = episodeByID[episodeID], let title = titleByID[titleID] else { return nil }
            return EpisodeStat(tmdbID: title.tmdbID, seriesName: title.name, posterPath: title.posterPath, code: episode.code,
                               season: episode.season, number: episode.number, name: episode.name, watches: watches)
        }.sorted { ($0.watches, $1.seriesName, $1.season, $1.number) > ($1.watches, $0.seriesName, $0.season, $0.number) }
            .prefix(Self.listLimit).map { $0 }

        result.mostCompletedSeries = try await completedSeries(userID: userID, watches: watches, titleByID: titleByID,
                                                               ratingByTitle: ratingByTitle)
        result.genres = genreTally.values.map { entry in
            var stat = entry.stat
            stat.series = entry.seriesIDs.count
            stat.movies = entry.movieIDs.count
            return stat
        }.sorted { ($0.seriesMinutes + $0.movieMinutes, $1.genre.label) > ($1.seriesMinutes + $1.movieMinutes, $0.genre.label) }
        return result
    }

    /// The episodes the user watched (runtime, code and name), one SQL join instead of thousands of Fluent models.
    private func watchedEpisodes(userID: UUID) async throws -> [UUID: (titleID: UUID, info: EpisodeInfo)] {
        guard let sql = db as? any SQLDatabase else {
            let ids = Array(Set(try await Watch.query(on: db).filter(\.$user.$id == userID).filter(\.$episode.$id != nil).all()
                .compactMap(\.$episode.id)))
            let episodes = ids.isEmpty ? [] : try await Episode.query(on: db).filter(\.$id ~~ ids).all()
            return Dictionary(episodes.map { ($0.id!, ($0.$title.id, EpisodeInfo($0))) }, uniquingKeysWith: { a, _ in a })
        }
        struct Row: Decodable {
            let id: UUID
            let title_id: UUID
            let season_number: Int
            let episode_number: Int
            let name: String
            let runtime: Int?
        }
        let rows = try await sql.raw("""
            SELECT DISTINCT e.id AS id, e.title_id AS title_id, e.season_number AS season_number,
                   e.episode_number AS episode_number, e.name AS name, e.runtime AS runtime
            FROM episodes e JOIN watches w ON w.episode_id = e.id
            WHERE w.user_id = \(bind: userID)
            """).all(decoding: Row.self)
        return Dictionary(rows.map { row in
            (row.id, (row.title_id, EpisodeInfo(id: row.id, season: row.season_number, number: row.episode_number, name: row.name,
                                                airDate: nil, runtime: row.runtime)))
        }, uniquingKeysWith: { a, _ in a })
    }

    /// How often each watched series was seen completely: the fewest watches of any aired regular episode (season ≥ 1,
    /// air date ≤ today; specials and episodes without a date do not count). Uses all watches, not only the period.
    /// Counted in SQL: one row per series instead of every episode of every watched series.
    private func completedSeries(userID: UUID, watches: [WatchRow], titleByID: [UUID: Title],
                                 ratingByTitle: [UUID: Int?]) async throws -> [CompletedSeries] {
        var counts: [(titleID: UUID, completions: Int)] = []
        if let sql = db as? any SQLDatabase {
            struct Row: Decodable {
                let title_id: UUID
                let completions: Int
            }
            counts = try await sql.raw("""
                SELECT e.title_id AS title_id, MIN(COALESCE(w.cnt, 0)) AS completions
                FROM episodes e
                LEFT JOIN (SELECT episode_id, COUNT(*) AS cnt FROM watches
                           WHERE user_id = \(bind: userID) AND episode_id IS NOT NULL GROUP BY episode_id) w ON w.episode_id = e.id
                WHERE e.season_number >= 1 AND e.air_date IS NOT NULL AND e.air_date <= \(bind: today)
                  AND e.title_id IN (SELECT title_id FROM watches WHERE user_id = \(bind: userID) AND episode_id IS NOT NULL)
                GROUP BY e.title_id
                """).all(decoding: Row.self).map { ($0.title_id, $0.completions) }
        } else {
            var countByEpisode: [UUID: Int] = [:]
            for watch in watches { if let episodeID = watch.episodeID { countByEpisode[episodeID, default: 0] += 1 } }
            let seriesIDs = Array(Set(watches.filter { $0.episodeID != nil }.map(\.titleID)))
            for (titleID, episodes) in try await Episode.infos(ofTitles: seriesIDs, minSeason: 1, on: db) {
                let aired = episodes.filter { $0.isAired(today: today) }
                if let fewest = aired.map({ countByEpisode[$0.id] ?? 0 }).min() { counts.append((titleID, fewest)) }
            }
        }
        return counts.filter { $0.completions > 0 }.compactMap { titleID, completions -> CompletedSeries? in
            guard let title = titleByID[titleID] else { return nil }
            return CompletedSeries(tmdbID: title.tmdbID, name: title.name, posterPath: title.posterPath, completions: completions,
                                   rating: ratingByTitle[titleID] ?? nil)
        }.sorted { ($0.completions, $1.name) > ($1.completions, $0.name) }.prefix(Self.listLimit).map { $0 }
    }

    /// Months of the selected year (up to `monthCount`) or one bar per year; undated viewings have no bar.
    private static func chart(_ viewings: [Viewing], year: Int?, years: [Int], monthCount: Int?) -> [ChartBar] {
        var bars: [ChartBar]
        if year != nil {
            bars = (0..<(monthCount ?? 12)).map { ChartBar(label: monthLabels[$0]) }
        } else {
            bars = years.map { ChartBar(label: String($0)) }
        }
        for viewing in viewings {
            guard let viewingYear = viewing.year, let month = viewing.month else { continue }
            let index = year != nil ? month - 1 : years.firstIndex(of: viewingYear)
            guard let index, bars.indices.contains(index) else { continue }
            if viewing.isEpisode {
                bars[index].episodes += 1
                bars[index].seriesMinutes += viewing.minutes ?? 0
            } else {
                bars[index].movies += 1
                bars[index].movieMinutes += viewing.minutes ?? 0
            }
        }
        return bars
    }

    /// `2026-11-07` → (2026, 11); anything else → (nil, nil).
    private static func yearMonth(_ date: String?) -> (Int?, Int?) {
        guard let date, date.count >= 7, let year = Int(date.prefix(4)),
              let month = Int(date.dropFirst(5).prefix(2)), (1...12).contains(month) else { return (nil, nil) }
        return (year, month)
    }
}

/// Change against the previous year: „+18 %“, „−6 %“, „±0 %“; nil without a previous value.
func formatDelta(_ current: Int, _ previous: Int) -> String? {
    guard previous > 0 else { return nil }
    let percent = Int((Double(current - previous) / Double(previous) * 100).rounded())
    if percent == 0 { return "±0 %" }
    return percent > 0 ? "+\(percent) %" : "−\(-percent) %"
}

/// `45 Min.`, `3 Std. 20 Min.` (under 10 h), `1.240 Std.`
func formatDuration(minutes: Int) -> String {
    if minutes < 60 { return "\(minutes) Min." }
    let hours = minutes / 60, rest = minutes % 60
    if hours < 10 { return rest == 0 ? "\(hours) Std." : "\(hours) Std. \(rest) Min." }
    return "\(groupedThousands(hours)) Std."
}

/// German digit grouping without depending on the server locale: 1240 → `1.240`.
func groupedThousands(_ value: Int) -> String {
    let digits = Array(String(value))
    var result = ""
    for (index, digit) in digits.enumerated() {
        if index > 0, (digits.count - index) % 3 == 0 { result.append(".") }
        result.append(digit)
    }
    return result
}
