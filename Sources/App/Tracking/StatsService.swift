import Fluent
import Foundation
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

struct Stats: Sendable {
    let total: PeriodStats
    let undated: PeriodStats
    /// Newest first.
    let years: [YearStats]
    /// Ratings 10 … 1, then unrated.
    let ratings: [RatingStats]
    /// Watched titles whose runtimes are not loaded from TMDB yet.
    let missingRuntimeTitles: Int
}

/// Viewing statistics of one user, built from their watches and the cached TMDB runtimes.
struct StatsService {
    let db: any Database
    let today: String

    private struct Viewing {
        let titleID: UUID
        let isEpisode: Bool
        let minutes: Int?
        let year: Int?
        let month: Int?
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

    func stats(userID: UUID, ratingYear: Int?) async throws -> Stats {
        let watches = try await Watch.query(on: db).filter(\.$user.$id == userID).all()
        let titleIDs = Array(Set(watches.map(\.$title.id)))
        let titles = titleIDs.isEmpty ? [] : try await Title.query(on: db).filter(\.$id ~~ titleIDs).all()
        let titleByID = Dictionary(titles.compactMap { title in title.id.map { ($0, title) } }, uniquingKeysWith: { a, _ in a })
        let episodeIDs = Array(Set(watches.compactMap(\.$episode.id)))
        let episodes = episodeIDs.isEmpty ? [] : try await Episode.query(on: db).filter(\.$id ~~ episodeIDs).all()
        let episodeRuntime = Dictionary(episodes.compactMap { episode in episode.id.map { ($0, episode.runtime) } },
                                        uniquingKeysWith: { a, _ in a })
        let entries = try await UserTitle.query(on: db).filter(\.$user.$id == userID).all()
        let ratingByTitle = Dictionary(entries.map { ($0.$title.id, $0.rating) }, uniquingKeysWith: { a, _ in a })

        let viewings: [Viewing] = watches.compactMap { watch in
            guard let title = titleByID[watch.$title.id] else { return nil }
            let seriesRuntime = (title.runtime ?? 0) > 0 ? title.runtime : nil
            let minutes: Int?
            if let episodeID = watch.$episode.id {
                let own = episodeRuntime[episodeID] ?? nil
                minutes = (own ?? 0) > 0 ? own : seriesRuntime
            } else if title.titleKind == .movie {
                minutes = seriesRuntime
            } else {
                return nil
            }
            let (year, month) = Self.yearMonth(watch.watchedOn)
            return Viewing(titleID: watch.$title.id, isEpisode: watch.$episode.id != nil, minutes: minutes, year: year, month: month)
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
            if ratingYear == nil || viewing.year == ratingYear {
                byRating[ratingByTitle[viewing.titleID] ?? nil, default: Tally()].add(viewing)
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
        return Stats(total: total.stats, undated: undated.stats, years: years, ratings: ratings,
                     missingRuntimeTitles: titles.filter { $0.runtime == nil }.count)
    }

    /// `2026-11-07` → (2026, 11); anything else → (nil, nil).
    private static func yearMonth(_ date: String?) -> (Int?, Int?) {
        guard let date, date.count >= 7, let year = Int(date.prefix(4)),
              let month = Int(date.dropFirst(5).prefix(2)), (1...12).contains(month) else { return (nil, nil) }
        return (year, month)
    }
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
