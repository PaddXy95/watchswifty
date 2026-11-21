import Elementary
import ElementaryHTMX2
import Foundation

/// „Später ansehen“ (spec §3.2).
struct WatchLaterListPage: HTML {
    let navContext: NavContext
    let page: WatchLaterPage
    let filter: String

    private let filters = [("all", "Alle"), ("tv", "Serien"), ("movie", "Filme")]

    var body: some HTML {
        PageLayout(title: "Später ansehen", nav: navContext) {
            h1 { "Später ansehen" }
            nav(.class("filter-bar"), .custom(name: "aria-label", value: "Filter")) {
                for (key, label) in filters {
                    a(.href("/watch-later?filter=\(key)")) { label }
                        .attributes(.class("active"), .custom(name: "aria-current", value: "page"), when: key == filter)
                }
            }
            if page.atMyServices.isEmpty && page.others.isEmpty {
                p(.class("empty-note")) {
                    "Noch nichts vorgemerkt. In der "
                    a(.href("/search")) { "Suche" }
                    " fügst du Titel mit „+ Später“ hinzu."
                }
            } else {
                if !page.hasServices {
                    p(.class("notice")) {
                        "Du hast noch keine Streamingdienste gewählt. "
                        a(.href("/account?open=streaming")) { "Deine Dienste unter Konto festlegen" }
                    }
                }
                if !page.atMyServices.isEmpty {
                    h2 { "Bei deinen Diensten "; span(.class("muted count")) { "\(page.atMyServices.count)" } }
                    div(.class("card-list")) {
                        for item in page.atMyServices { WatchLaterCard(item: item, mine: true) }
                    }
                }
                if !page.others.isEmpty {
                    h2 { "Noch nicht bei deinen Diensten "; span(.class("muted count")) { "\(page.others.count)" } }
                    div(.class("card-list")) {
                        for item in page.others { WatchLaterCard(item: item, mine: false) }
                    }
                }
                p(.class("muted attribution")) {
                    "Verfügbarkeit in \(countryName(page.region)): "
                    JustWatchLink(region: page.region)
                    if let oldest = page.oldestFetch { " · Stand \(availabilityDate(oldest))" }
                    " · Titel verschwinden von der Liste, sobald du sie zu schauen beginnst."
                }
            }
        }
    }
}

struct WatchLaterCard: HTML {
    let item: WatchLaterItem
    let mine: Bool

    private var href: String { "/\(item.title.kind)/\(item.title.tmdbID)" }

    /// Status for titles not at the user's services.
    private var status: String {
        guard let groups = item.groups else { return "Verfügbarkeit noch nicht abgefragt" }
        if !groups.otherSubscriptions.isEmpty {
            return "Im Abo bei " + Self.names(groups.otherSubscriptions)
        }
        if !groups.free.isEmpty { return "Gratis bei " + Self.names(groups.free) }
        if !groups.rentOrBuy.isEmpty { return "Nur leihen oder kaufen" }
        return "Derzeit nirgends verfügbar"
    }

    private static func names(_ offers: [Offer]) -> String {
        var names: [String] = []
        for offer in offers where !names.contains(offer.name) { names.append(offer.name) }
        return names.joined(separator: ", ")
    }

    var body: some HTML {
        div(.class("card watch-later-item")) {
            a(.href(href), .class("poster-link")) { Poster(path: item.title.posterPath, alt: item.title.name, displayWidth: 56) }
            div(.class("card-body")) {
                strong { a(.href(href)) { item.title.name } }
                if let year = item.title.year { span(.class("muted")) { " (\(year))" } }
                " "
                span(.class("badge")) { item.title.titleKind == .tv ? "Serie" : "Film" }
                if let newSince = item.newSince {
                    " "
                    span(.class("new-since")) { "neu seit \(Self.dayMonth(newSince))" }
                }
                if mine {
                    div(.class("providers")) {
                        for offer in item.available { ProviderChip(offer: offer, titleName: item.title.name, mine: true) }
                    }
                } else {
                    div(.class("muted")) { status }
                }
            }
            button(.class("link-button"), .hx.post("/watch-later/\(item.title.kind)/\(item.title.tmdbID)/remove"),
                   .hx.target("closest .card"), .hx.swap(.outerHTML)) { "Entfernen" }
        }
    }

    private static func dayMonth(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM."
        return formatter.string(from: date)
    }
}
