import Elementary

struct StatsPage: HTML {
    let navContext: NavContext
    let stats: Stats
    let ratingYear: Int?

    static let monthNames = ["Januar", "Februar", "März", "April", "Mai", "Juni",
                             "Juli", "August", "September", "Oktober", "November", "Dezember"]

    private var days: String? {
        guard stats.total.minutes >= 1440 else { return nil }
        let days = Int((Double(stats.total.minutes) / 1440).rounded())
        return days == 1 ? "≈ 1 Tag" : "≈ \(groupedThousands(days)) Tage"
    }

    private var runtimeNote: String? {
        let unknown = stats.total.unknownRuntime
        guard unknown > 0 else { return nil }
        var note = unknown == 1 ? "1 Sichtung ohne bekannte Laufzeit ist" : "\(groupedThousands(unknown)) Sichtungen ohne bekannte Laufzeit sind"
        note += " in der Zeit nicht enthalten."
        if stats.missingRuntimeTitles > 0 {
            note += " Die Laufzeiten für \(stats.missingRuntimeTitles) Titel werden gerade von TMDB nachgeladen."
        }
        return note
    }

    var body: some HTML {
        PageLayout(title: "Statistik", nav: navContext) {
            h1 { "Statistik" }
            if stats.total.isEmpty {
                p(.class("muted")) {
                    "Noch nichts gesehen – markiere Folgen oder Filme als gesehen oder importiere deinen Netflix-Verlauf."
                }
            } else {
                div(.class("stat-tiles")) {
                    StatTile(value: groupedThousands(stats.total.movies), caption: "Filme")
                    StatTile(value: groupedThousands(stats.total.series), caption: "Serien")
                    StatTile(value: groupedThousands(stats.total.episodes), caption: "Folgen")
                    StatTile(value: formatDuration(minutes: stats.total.minutes), caption: days.map { "Zeit · \($0)" } ?? "Zeit")
                }
                if let runtimeNote { p(.class("muted stats-note")) { runtimeNote } }

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
                }
                if !stats.undated.isEmpty {
                    p(.class("muted stats-note")) {
                        "„ohne Datum“: Folgen und Filme, die ohne Datum abgehakt wurden (z. B. „Ganze Staffel gesehen“)."
                    }
                }

                h2(.id("bewertung")) { "Nach Bewertung" }
                nav(.class("filter-bar"), .custom(name: "aria-label", value: "Jahr")) {
                    a(.href("/stats#bewertung")) { "Alle Jahre" }
                        .attributes(.class("active"), .custom(name: "aria-current", value: "true"), when: ratingYear == nil)
                    for year in stats.years {
                        a(.href("/stats?year=\(year.year)#bewertung")) { "\(year.year)" }
                            .attributes(.class("active"), .custom(name: "aria-current", value: "true"), when: ratingYear == year.year)
                    }
                }
                div(.class("stats-table ratings")) {
                    div(.class("stats-row stats-head")) {
                        span { "Bewertung" }; span { "Filme" }; span { "Serien" }; span { "Zeit" }; span(.class("bar-head")) {}
                    }
                    let maxCount = stats.ratings.map { $0.movies + $0.series }.max() ?? 0
                    for bucket in stats.ratings {
                        div(.class("stats-row")) {
                            span { bucket.rating.map { "★ \($0)" } ?? "ohne Bewertung" }
                            span { countText(bucket.movies) }
                            span { countText(bucket.series) }
                            span { bucket.minutes > 0 ? formatDuration(minutes: bucket.minutes) : "–" }
                            Bar(value: bucket.movies + bucket.series, max: maxCount)
                        }
                    }
                }
                p(.class("muted stats-note")) {
                    "Filme und Serien zählen je Zeitraum einmal; Folgen und Zeit enthalten auch erneut Gesehenes."
                }
            }
        }
    }
}

func countText(_ value: Int) -> String { value == 0 ? "–" : groupedThousands(value) }

struct StatTile: HTML {
    let value: String
    let caption: String

    var body: some HTML {
        div(.class("stat-tile")) {
            strong { value }
            span { caption }
        }
    }
}

struct PeriodCells: HTML {
    let caption: String
    let stats: PeriodStats
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

struct Bar: HTML {
    let value: Int
    let max: Int

    var body: some HTML {
        span(.class("bar"), .custom(name: "aria-hidden", value: "true")) {
            span(.class("bar-fill"), .style("width: \(max > 0 ? Int((Double(value) / Double(max) * 100).rounded()) : 0)%")) {}
        }
    }
}
