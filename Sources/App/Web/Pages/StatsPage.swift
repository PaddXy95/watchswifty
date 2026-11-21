import Elementary

/// Statistics dashboard: one period (all years or one year) drives tiles, charts, services and top series; the full
/// year/month table sits folded under „Alle Zahlen“.
struct StatsPage: HTML {
    let navContext: NavContext
    /// All figures for the selected period and the year/month table.
    let stats: Stats

    /// German month names, index 0 is January.
    static let monthNames = ["Januar", "Februar", "März", "April", "Mai", "Juni",
                             "Juli", "August", "September", "Oktober", "November", "Dezember"]

    /// The period's time in whole days („≈ 3 Tage“, about 3 days); nil below one day.
    private var days: String? {
        guard stats.period.minutes >= 1440 else { return nil }
        let days = Int((Double(stats.period.minutes) / 1440).rounded())
        return days == 1 ? "≈ 1 Tag" : "≈ \(groupedThousands(days)) Tage"
    }

    /// Note that viewings without known runtime are missing from the time (and that runtimes are being fetched from TMDB);
    /// nil when every runtime is known.
    private var runtimeNote: String? {
        let unknown = stats.period.unknownRuntime
        guard unknown > 0 else { return nil }
        var note = unknown == 1 ? "1 Sichtung ohne bekannte Laufzeit ist" : "\(groupedThousands(unknown)) Sichtungen ohne bekannte Laufzeit sind"
        note += " in der Zeit nicht enthalten."
        if stats.missingRuntimeTitles > 0 {
            note += " Die Laufzeiten für \(stats.missingRuntimeTitles) Titel werden gerade von TMDB nachgeladen."
        }
        return note
    }

    /// Year chips: all years with viewings, plus a selected year without any (so the choice stays visible).
    private var chipYears: [Int] {
        var years = stats.years.map(\.year)
        if let year = stats.year, !years.contains(year) { years.append(year) }
        return years.sorted(by: >)
    }

    var body: some HTML {
        PageLayout(title: "Statistik", nav: navContext) {
            h1 { "Statistik" }
            if stats.total.isEmpty {
                p(.class("muted")) {
                    "Noch nichts gesehen – markiere Folgen oder Filme als gesehen oder importiere deinen Netflix-Verlauf."
                }
            } else {
                nav(.class("filter-bar stats-years"), .custom(name: "aria-label", value: "Zeitraum")) {
                    a(.href("/stats")) { "Alle Jahre" }
                        .attributes(.class("active"), .custom(name: "aria-current", value: "true"), when: stats.year == nil)
                    for year in chipYears {
                        a(.href("/stats?year=\(year)")) { "\(year)" }
                            .attributes(.class("active"), .custom(name: "aria-current", value: "true"), when: stats.year == year)
                    }
                }
                if stats.period.isEmpty {
                    p(.class("muted")) { "In \(stats.year.map(String.init) ?? "diesem Zeitraum") nichts gesehen." }
                } else {
                    dashboard
                }
                allNumbers
            }
        }
    }

    /// Dashboard of the selected period: stat tiles (with the change against the previous period when there is one),
    /// the time chart per year or month, services, top lists, genres and ratings.
    @HTMLBuilder private var dashboard: some HTML {
        let previous = stats.previous
        let compare = stats.year.map { " ggü. \($0 - 1)" } ?? ""
        div(.class("stat-tiles")) {
            StatTile(value: formatDuration(minutes: stats.period.minutes), caption: days.map { "Zeit · \($0)" } ?? "Zeit",
                     delta: previous.flatMap { formatDelta(stats.period.minutes, $0.minutes) }.map { $0 + compare })
            StatTile(value: groupedThousands(stats.period.episodes), caption: "Folgen",
                     delta: previous.flatMap { formatDelta(stats.period.episodes, $0.episodes) }.map { $0 + compare })
            StatTile(value: groupedThousands(stats.period.series), caption: "Serien",
                     delta: previous.flatMap { formatDelta(stats.period.series, $0.series) }.map { $0 + compare })
            StatTile(value: groupedThousands(stats.period.movies), caption: "Filme",
                     delta: previous.flatMap { formatDelta(stats.period.movies, $0.movies) }.map { $0 + compare })
        }
        if let runtimeNote { p(.class("muted stats-note")) { runtimeNote } }

        section(.class("stats-panel")) {
            div(.class("stats-panel-head")) {
                h2 { stats.year == nil ? "Zeit pro Jahr" : "Zeit pro Monat" }
                ChartLegend()
            }
            if stats.chart.isEmpty {
                p(.class("muted")) { "Nur Sichtungen ohne Datum." }
            } else {
                TimeChart(bars: stats.chart, perYear: stats.year == nil)
            }
            if stats.year == nil, !stats.undated.isEmpty {
                p(.class("muted stats-note")) {
                    "Dazu \(formatDuration(minutes: stats.undated.minutes)) ohne Datum (z. B. „Ganze Staffel gesehen“) – in den Kennzahlen enthalten, im Diagramm nicht."
                }
            }
        }

        div(.class("stats-grid")) {
            if !stats.services.isEmpty {
                section(.class("stats-panel stats-services")) {
                    h2 { "Dienste" }
                    ServiceBars(services: stats.services)
                }
            }
            if !stats.topSeries.isEmpty {
                section(.class("stats-panel")) {
                    h2 { "Längste Serien" }
                    RankedList(items: stats.topSeries.map {
                        RankedItem(href: "/tv/\($0.tmdbID)", posterPath: $0.posterPath, name: $0.name,
                                   detail: "\(countLabel($0.episodes, "Folge", "Folgen")) · \(formatDuration(minutes: $0.minutes))", rating: $0.rating)
                    })
                }
            }
            if !stats.longestMovies.isEmpty {
                section(.class("stats-panel")) {
                    h2 { "Längste Filme" }
                    RankedList(items: stats.longestMovies.map(Self.movieItem))
                }
            }
            if !stats.mostCompletedSeries.isEmpty {
                section(.class("stats-panel")) {
                    div(.class("stats-panel-head")) {
                        h2 { "Meistgesehene Serien" }
                        span(.class("muted stats-panel-note")) { "über alle Jahre" }
                    }
                    RankedList(items: stats.mostCompletedSeries.map {
                        RankedItem(href: "/tv/\($0.tmdbID)", posterPath: $0.posterPath, name: $0.name,
                                   detail: "\($0.completions)× komplett", rating: $0.rating)
                    })
                }
            }
            if !stats.mostWatchedMovies.isEmpty {
                section(.class("stats-panel")) {
                    h2 { "Meistgesehene Filme" }
                    RankedList(items: stats.mostWatchedMovies.map(Self.movieItem))
                }
            }
            if !stats.mostWatchedEpisodes.isEmpty {
                section(.class("stats-panel")) {
                    h2 { "Meistgesehene Folgen" }
                    RankedList(items: stats.mostWatchedEpisodes.map {
                        RankedItem(href: "/tv/\($0.tmdbID)", posterPath: $0.posterPath, name: $0.seriesName,
                                   detail: [$0.code, $0.name].filter { !$0.isEmpty }.joined(separator: " ") + " · \($0.watches)×", rating: nil)
                    })
                }
            }
        }

        if !stats.genres.isEmpty {
            section(.class("stats-panel")) {
                div(.class("stats-panel-head")) {
                    h2 { "Genres" }
                    ChartLegend()
                }
                GenreBars(genres: stats.genres)
                p(.class("muted stats-note")) {
                    "Ein Titel zählt bei jedem seiner Genres; Titel, deren Genres noch nicht geladen sind, fehlen."
                }
            }
        }

        section(.class("stats-panel"), .id("bewertung")) {
            div(.class("stats-panel-head")) {
                h2 { "Nach Bewertung" }
                ChartLegend()
            }
            RatingChart(ratings: stats.ratings)
            p(.class("muted stats-note")) {
                "Filme und Serien zählen je Zeitraum einmal; Folgen und Zeit enthalten auch erneut Gesehenes."
            }
        }
    }

    /// The folded „Alle Zahlen“ (all figures) table: one expandable row per year with its months, the undated row and the
    /// total; bars are scaled to the largest year or month.
    @HTMLBuilder private var allNumbers: some HTML {
        details(.class("stats-all")) {
            summary { "Alle Zahlen" }
            h2 { "Pro Jahr" }
            div(.class("stats-table")) {
                div(.class("stats-row stats-head")) {
                    span { "Jahr" }; span { "Filme" }; span { "Serien" }; span { "Folgen" }; span { "Zeit" }; span(.class("bar-head")) {}
                }
                let maxYear = stats.years.map(\.stats.minutes).max() ?? 0
                for year in stats.years {
                    details(.class("stats-year")) {
                        summary(.class("stats-row")) { PeriodCells(caption: "\(year.year)", stats: year.stats, maxMinutes: maxYear) }
                        div(.class("stats-months")) {
                            let maxMonth = year.months.map(\.stats.minutes).max() ?? 0
                            for month in year.months {
                                div(.class("stats-row")) {
                                    PeriodCells(caption: Self.monthNames[month.month - 1], stats: month.stats, maxMinutes: maxMonth)
                                }
                            }
                        }
                    }
                }
                if !stats.undated.isEmpty {
                    div(.class("stats-row stats-undated")) { PeriodCells(caption: "ohne Datum", stats: stats.undated, maxMinutes: 0) }
                }
                div(.class("stats-row stats-sum")) { PeriodCells(caption: "Gesamt", stats: stats.total, maxMinutes: 0) }
            }
            if !stats.undated.isEmpty {
                p(.class("muted stats-note")) {
                    "„ohne Datum“: Folgen und Filme, die ohne Datum abgehakt wurden (z. B. „Ganze Staffel gesehen“)."
                }
            }
        }
    }
}

extension StatsPage {
    /// „2× · 4 Std. 32 Min.“ (time only when the runtime is known).
    /// - Parameter movie: The movie's figures.
    /// - Returns: The entry for a `RankedList`, linking to the movie page.
    static func movieItem(_ movie: MovieStat) -> RankedItem {
        RankedItem(href: "/movie/\(movie.tmdbID)", posterPath: movie.posterPath, name: movie.name,
                   detail: "\(movie.watches)×" + (movie.minutes > 0 ? " · \(formatDuration(minutes: movie.minutes))" : ""),
                   rating: movie.rating)
    }
}

/// Legend for the stacked bars (series and movies); hidden from screen readers.
struct ChartLegend: HTML {
    var body: some HTML {
        span(.class("chart-legend"), .custom(name: "aria-hidden", value: "true")) {
            span { i(.class("swatch seg-series")) {}; "Serien" }
            span { i(.class("swatch seg-movies")) {}; "Filme" }
        }
    }
}

/// A count for the figures table: grouped thousands, or „–“ for zero.
/// - Parameter value: The count.
/// - Returns: The text for the cell.
func countText(_ value: Int) -> String { value == 0 ? "–" : groupedThousands(value) }

/// Dashboard tile with a big value, a caption and an optional change, styled up or down by its leading „+“ or „−“.
struct StatTile: HTML {
    /// The formatted figure.
    let value: String
    /// What the figure counts.
    let caption: String
    /// Percentage change against the previous period, e.g. „+12 % ggü. 2025“ (vs. 2025); nil hides it.
    var delta: String? = nil

    var body: some HTML {
        div(.class("stat-tile")) {
            strong { value }
            span { caption }
            if let delta {
                span(.class(delta.hasPrefix("+") ? "delta up" : delta.hasPrefix("−") ? "delta down" : "delta")) { delta }
            }
        }
    }
}

/// Cells of one row of the figures table: caption, movies, series, episodes, time and a bar.
struct PeriodCells: HTML {
    /// Row caption (year, month, „ohne Datum“ or „Gesamt“).
    let caption: String
    /// Figures of the row.
    let stats: PeriodStats
    /// Largest time among the sibling rows; scales the bar (0 leaves it empty).
    let maxMinutes: Int

    var body: some HTML {
        span { caption }
        span { countText(stats.movies) }
        span { countText(stats.series) }
        span { countText(stats.episodes) }
        span { stats.minutes > 0 ? formatDuration(minutes: stats.minutes) : "–" }
        Bar(value: stats.minutes, max: maxMinutes)
    }
}

/// Horizontal bar filled to `value` as a share of `max` (empty when `max` is 0); hidden from screen readers.
struct Bar: HTML {
    /// Value to show.
    let value: Int
    /// Value of a full bar.
    let max: Int

    var body: some HTML {
        span(.class("bar"), .custom(name: "aria-hidden", value: "true")) {
            span(.class("bar-fill"), .style("width: \(max > 0 ? Int((Double(value) / Double(max) * 100).rounded()) : 0)%")) {}
        }
    }
}
