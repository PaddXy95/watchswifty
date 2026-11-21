import Elementary
import ElementaryHTMX2
import Foundation

/// What the „Verfügbarkeit“ block shows (spec §5).
struct AvailabilityView: Sendable {
    let kind: TitleKind
    let tmdbID: Int
    let titleName: String
    let region: String
    let snapshot: AvailabilitySnapshot?
    let services: Set<Int>
    let onList: Bool
    let hasToken: Bool
    /// The stored state is missing or old: the block loads itself again (htmx) once the page is shown.
    var loading = false
    /// The last fetch failed (shown next to the stored state).
    var fetchError: String? = nil
}

/// German country name for a region code („DE“ → „Deutschland“).
func countryName(_ region: String) -> String {
    Locale(identifier: "de_DE").localizedString(forRegionCode: region) ?? region
}

/// „Stand“ date of availability data, `dd.MM.yyyy`.
func availabilityDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "de_DE")
    formatter.dateFormat = "dd.MM.yyyy"
    return formatter.string(from: date)
}

/// Link to JustWatch for the user's country (attribution required by TMDB for watch provider data).
struct JustWatchLink: HTML, Sendable {
    let region: String

    var body: some HTML {
        a(.href("https://www.justwatch.com/\(region.lowercased())"), .target(.blank), .custom(name: "rel", value: "noopener noreferrer")) {
            "JustWatch"
        }
    }
}

/// One service chip; a link to the service's search when WatchSwifty knows one.
struct ProviderChip: HTML, Sendable {
    let offer: Offer
    let titleName: String
    let mine: Bool
    var suffix: String? = nil

    var body: some HTML {
        let classes = mine ? "provider mine" : "provider"
        let text = suffix.map { "\(offer.name) (\($0))" } ?? offer.name
        if let link = StreamingService(tmdbProviderID: offer.providerID)?.watchLink(for: titleName) {
            a(.class(classes), .href(link.url), .target(.blank), .custom(name: "rel", value: "noopener noreferrer"),
              .title(link.label)) {
                ProviderLogo(path: offer.logoPath, name: offer.name)
                span { text }
            }
        } else {
            span(.class(classes)) {
                ProviderLogo(path: offer.logoPath, name: offer.name)
                span { text }
            }
        }
    }
}

/// The block „Verfügbarkeit · <Land>“ on the series and movie page.
struct AvailabilityBlock: HTML, Sendable {
    let view: AvailabilityView

    private var path: String { "/\(view.kind.rawValue)/\(view.tmdbID)/availability" }

    var body: some HTML {
        if view.loading {
            section(.id("availability"), .class("availability"), .hx.get(path), .custom(name: "hx-trigger", value: "load"), .hx.swap(.outerHTML)) {
                content
            }
        } else {
            section(.id("availability"), .class("availability")) { content }
        }
    }

    @HTMLBuilder private var content: some HTML {
        h2 {
            "Verfügbarkeit"
            span(.class("muted")) { " · \(countryName(view.region))" }
        }
        if let snapshot = view.snapshot {
            offers(AvailabilityGroups(snapshot: snapshot, services: view.services))
            p(.class("attribution")) {
                "Verfügbarkeit: "
                JustWatchLink(region: view.region)
                " · Stand \(availabilityDate(snapshot.fetchedAt))"
            }
        } else if view.loading {
            p(.class("muted")) { "Verfügbarkeit wird geladen …" }
        }
        if let fetchError = view.fetchError {
            p(.class("muted")) { fetchError }
        }
        if !view.hasToken {
            p(.class("muted")) {
                "Kein TMDB-Token hinterlegt: Die Verfügbarkeit kann nicht abgefragt werden. "
                a(.href("/account?open=tmdb")) { "Unter Konto eintragen" }
            }
        }
    }

    @HTMLBuilder private func offers(_ groups: AvailabilityGroups) -> some HTML {
        if groups.hasServices {
            if !groups.mine.isEmpty { group("In deinen Abos", groups.mine, mine: true) }
            if !groups.otherSubscriptions.isEmpty { group("Weitere Abos", groups.otherSubscriptions, mine: false) }
        } else if !groups.otherSubscriptions.isEmpty {
            group("Im Abo", groups.otherSubscriptions, mine: false)
        }
        if !groups.free.isEmpty {
            group("Gratis / mit Werbung", groups.free, mine: false, services: view.services)
        }
        if groups.mine.isEmpty && groups.otherSubscriptions.isEmpty {
            p(.class("muted")) {
                "Derzeit bei keinem Abo-Dienst verfügbar."
                if view.onList {
                    " Steht der Titel auf „Später ansehen“, bekommst du eine Nachricht, sobald er bei einem deiner Dienste im Abo läuft."
                }
            }
        }
        if !groups.rentOrBuy.isEmpty {
            details(.class("rent-buy")) {
                summary { "Leihen oder kaufen (\(Set(groups.rentOrBuy.map(\.providerID)).count) Anbieter)" }
                div(.class("providers")) {
                    for offer in groups.rentOrBuy {
                        ProviderChip(offer: offer, titleName: view.titleName, mine: false,
                                     suffix: offer.kind == .rent ? "Leihen" : "Kaufen")
                    }
                }
            }
        }
        if !groups.hasServices {
            p(.class("muted")) { a(.href("/account?open=streaming")) { "Deine Dienste unter Konto festlegen" } }
        }
    }

    @HTMLBuilder private func group(_ label: String, _ offers: [Offer], mine: Bool, services: Set<Int> = []) -> some HTML {
        div(.class("provider-group")) {
            div(.class("label")) { label }
            div(.class("providers")) {
                for offer in offers {
                    ProviderChip(offer: offer, titleName: view.titleName, mine: mine || services.contains(offer.providerID))
                }
            }
        }
    }
}
