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

    private struct Viewing {
        let titleID: UUID
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
            return Viewing(titleID: watch.$title.id, isEpisode: watch.$episode.id != nil, minutes: minutes, year: year, month: month,
                           service: watch.streamingService)
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
        var serviceMinutes: [StreamingService?: Int] = [:]
        var seriesTally: [UUID: (episodes: Int, minutes: Int)] = [:]
        for viewing in inRange {
            period.add(viewing)
            byRating[ratingByTitle[viewing.titleID] ?? nil, default: Tally()].add(viewing)
            if let minutes = viewing.minutes { serviceMinutes[viewing.service, default: 0] += minutes }
            if viewing.isEpisode {
                let current = seriesTally[viewing.titleID] ?? (0, 0)
                seriesTally[viewing.titleID] = (current.episodes + 1, current.minutes + (viewing.minutes ?? 0))
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
        result.services = serviceMinutes.filter { $0.value > 0 }.map { ServiceShare(service: $0.key, minutes: $0.value) }
            .sorted { ($0.minutes, $0.service?.label ?? "") > ($1.minutes, $1.service?.label ?? "") }
        result.topSeries = seriesTally.compactMap { titleID, tally -> TopSeries? in
            guard let title = titleByID[titleID] else { return nil }
            return TopSeries(tmdbID: title.tmdbID, name: title.name, posterPath: title.posterPath, episodes: tally.episodes,
                             minutes: tally.minutes, rating: ratingByTitle[titleID] ?? nil)
        }.sorted { ($0.minutes, $0.episodes, $1.name) > ($1.minutes, $1.episodes, $0.name) }.prefix(5).map { $0 }
        return result
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
