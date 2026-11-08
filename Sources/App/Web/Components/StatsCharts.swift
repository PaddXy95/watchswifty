import Elementary

/// One column of a `ColumnChart`; segments are stacked bottom to top, each coloured by its CSS class.
struct ChartColumn: Sendable {
    struct Segment: Sendable {
        let value: Int
        let cssClass: String
    }

    let label: String
    let segments: [Segment]
    /// Tooltip (SVG `<title>`) for the whole column.
    let title: String

    var total: Int { segments.reduce(0) { $0 + $1.value } }
}

/// Column chart as server-rendered SVG (no JavaScript): the plot stretches to the container width, labels and the
/// value axis are HTML so text keeps its size. Hovering a column shows its `title`.
struct ColumnChart: HTML {
    let columns: [ChartColumn]
    /// Top of the value axis (at least the largest column).
    let axisMax: Int
    /// Tick labels at 50 % and 100 % of `axisMax`.
    let tickLabels: (half: String, full: String)
    let label: String

    private static let slot = 10.0
    private static let barWidth = 7.0

    private struct Box {
        let x: Double
        let y: Double
        let height: Double
        let cssClass: String
    }

    private func boxes(_ column: ChartColumn, at index: Int) -> [Box] {
        guard axisMax > 0 else { return [] }
        var top = 100.0
        return column.segments.filter { $0.value > 0 }.map { segment in
            let height = Double(segment.value) / Double(axisMax) * 100
            top -= height
            return Box(x: Double(index) * Self.slot + (Self.slot - Self.barWidth) / 2, y: top, height: height, cssClass: segment.cssClass)
        }
    }

    var body: some HTML {
        let width = Double(max(columns.count, 1)) * Self.slot
        div(.class("chart")) {
            div(.class("chart-ticks"), .custom(name: "aria-hidden", value: "true")) {
                span(.style("bottom: 100%")) { tickLabels.full }
                span(.style("bottom: 50%")) { tickLabels.half }
                span(.style("bottom: 0")) { "0" }
            }
            div(.class("chart-plot")) {
                SVG.svg(.viewBox(0, 0, SVGAttributeValue.Number(width), 100), .class("chart-svg"), .role("img"),
                        .custom(name: "preserveAspectRatio", value: "none"), .custom(name: "aria-label", value: label)) {
                    for fraction in [0.0, 0.5, 1.0] {
                        SVG.line(.x1(0), .y1(SVGAttributeValue.Length(100 - fraction * 100)), .x2(SVGAttributeValue.Length(width)),
                                 .y2(SVGAttributeValue.Length(100 - fraction * 100)), .class("chart-grid"),
                                 .custom(name: "vector-effect", value: "non-scaling-stroke"))
                    }
                    for (index, column) in columns.enumerated() {
                        SVG.g(.class("chart-col")) {
                            SVG.title { column.title }
                            SVG.rect(.x(SVGAttributeValue.Length(Double(index) * Self.slot)), .y(0),
                                     .width(SVGAttributeValue.Length(Self.slot)), .height(100), .class("chart-hit"))
                            for box in boxes(column, at: index) {
                                SVG.rect(.x(SVGAttributeValue.Length(box.x)), .y(SVGAttributeValue.Length(box.y)),
                                         .width(SVGAttributeValue.Length(Self.barWidth)), .height(SVGAttributeValue.Length(box.height)),
                                         .class(box.cssClass))
                            }
                        }
                    }
                }
            }
            div(.class("chart-labels"), .style("grid-template-columns: repeat(\(max(columns.count, 1)), 1fr)"),
                .custom(name: "aria-hidden", value: "true")) {
                for column in columns { span { column.label } }
            }
        }
    }
}

/// Value axis for minutes: a round number of hours (or minutes under two hours) that halves evenly.
func minutesAxis(maxMinutes: Int) -> (max: Int, half: String, full: String) {
    guard maxMinutes > 120 else {
        let top = [30, 60, 120].first { $0 >= maxMinutes } ?? 120
        return (top, "\(top / 2) Min.", top >= 60 ? "\(top / 60) Std." : "\(top) Min.")
    }
    let hours = (maxMinutes + 59) / 60
    let top = [4, 6, 10, 20, 40, 60, 100, 200, 400, 600, 1000, 2000, 4000, 6000, 10000].first { $0 >= hours }
        ?? (hours + 1) / 2 * 2
    return (top * 60, "\(groupedThousands(top / 2)) Std.", "\(groupedThousands(top)) Std.")
}

/// Value axis for counts: the next even number (at least 2).
func countAxis(maxCount: Int) -> (max: Int, half: String, full: String) {
    let top = max(2, (maxCount + 1) / 2 * 2)
    return (top, groupedThousands(top / 2), groupedThousands(top))
}

/// „Zeit pro Monat“ (or per year): series and movies stacked.
struct TimeChart: HTML {
    let bars: [ChartBar]
    let perYear: Bool

    private func title(_ bar: ChartBar) -> String {
        let total = bar.seriesMinutes + bar.movieMinutes
        guard bar.episodes + bar.movies > 0 else { return "\(bar.label): nichts gesehen" }
        var parts: [String] = []
        if bar.episodes > 0 {
            parts.append("\(groupedThousands(bar.episodes)) \(bar.episodes == 1 ? "Folge" : "Folgen") (\(formatDuration(minutes: bar.seriesMinutes)))")
        }
        if bar.movies > 0 {
            parts.append("\(groupedThousands(bar.movies)) \(bar.movies == 1 ? "Film" : "Filme") (\(formatDuration(minutes: bar.movieMinutes)))")
        }
        return "\(bar.label): \(formatDuration(minutes: total)) · " + parts.joined(separator: ", ")
    }

    var body: some HTML {
        let axis = minutesAxis(maxMinutes: bars.map { $0.seriesMinutes + $0.movieMinutes }.max() ?? 0)
        ColumnChart(columns: bars.map { bar in
            ChartColumn(label: bar.label, segments: [.init(value: bar.seriesMinutes, cssClass: "seg-series"),
                                                     .init(value: bar.movieMinutes, cssClass: "seg-movies")],
                        title: title(bar))
        }, axisMax: axis.max, tickLabels: (axis.half, axis.full), label: perYear ? "Zeit pro Jahr" : "Zeit pro Monat")
    }
}

/// Rated titles per rating 1 … 10, then unrated.
struct RatingChart: HTML {
    let ratings: [RatingStats]

    var body: some HTML {
        let ordered = ratings.filter { $0.rating != nil }.sorted { ($0.rating ?? 0) < ($1.rating ?? 0) }
            + ratings.filter { $0.rating == nil }
        let axis = countAxis(maxCount: ordered.map { $0.movies + $0.series }.max() ?? 0)
        ColumnChart(columns: ordered.map { bucket in
            let label = bucket.rating.map { "★ \($0)" } ?? "ohne"
            var parts: [String] = []
            if bucket.movies > 0 { parts.append("\(groupedThousands(bucket.movies)) \(bucket.movies == 1 ? "Film" : "Filme")") }
            if bucket.series > 0 { parts.append("\(groupedThousands(bucket.series)) \(bucket.series == 1 ? "Serie" : "Serien")") }
            let detail = parts.isEmpty ? "keine Titel" : parts.joined(separator: ", ")
                + (bucket.minutes > 0 ? " · \(formatDuration(minutes: bucket.minutes))" : "")
            return ChartColumn(label: label, segments: [.init(value: bucket.series, cssClass: "seg-series"),
                                                        .init(value: bucket.movies, cssClass: "seg-movies")],
                               title: "\(bucket.rating.map { "★ \($0)" } ?? "ohne Bewertung"): \(detail)")
        }, axisMax: axis.max, tickLabels: (axis.half, axis.full), label: "Titel nach Bewertung")
    }
}

/// Share of watch time per service as horizontal bars.
struct ServiceBars: HTML {
    let services: [ServiceShare]

    var body: some HTML {
        let total = services.reduce(0) { $0 + $1.minutes }
        let largest = services.first?.minutes ?? 0
        div(.class("service-bars")) {
            for share in services {
                let percent = total > 0 ? Int((Double(share.minutes) / Double(total) * 100).rounded()) : 0
                div(.class("service-row")) {
                    span(.class("service-name")) { share.service?.label ?? "ohne Dienst" }
                    span(.class("bar"), .custom(name: "aria-hidden", value: "true")) {
                        span(.class("bar-fill"),
                             .style("width: \(largest > 0 ? max(1, Int((Double(share.minutes) / Double(largest) * 100).rounded())) : 0)%")) {}
                    }
                    span(.class("service-value")) { "\(formatDuration(minutes: share.minutes)) · \(percent) %" }
                }
            }
        }
    }
}

/// Top series of the period with poster, episodes, time and rating.
struct TopSeriesList: HTML {
    let series: [TopSeries]

    var body: some HTML {
        ol(.class("top-series")) {
            for item in series {
                li {
                    a(.href("/tv/\(item.tmdbID)"), .class("top-series-link")) {
                        Poster(path: item.posterPath, alt: item.name, displayWidth: 40)
                        span(.class("top-series-text")) {
                            strong { item.name }
                            span(.class("muted")) {
                                "\(groupedThousands(item.episodes)) \(item.episodes == 1 ? "Folge" : "Folgen") · \(formatDuration(minutes: item.minutes))"
                            }
                        }
                        if let rating = item.rating { span(.class("rating")) { "★ \(rating)" } }
                    }
                }
            }
        }
    }
}
