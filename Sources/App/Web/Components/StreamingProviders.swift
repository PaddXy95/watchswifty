import Elementary
import ElementaryHTMX2

/// Konto → Streamingdienste: state of the block.
struct AccountStreaming: Sendable {
    /// Selected country code (e.g. `DE`).
    var region: String
    /// Countries offered in the „Land“ (country) select.
    var regions: [TMDBRegion]
    /// Streaming services TMDB lists for `region`.
    var providers: [TMDBProviderInfo]
    /// TMDB provider IDs the user has chosen.
    var selected: Set<Int>
    /// Whether the user has a TMDB token; without one, no choices are shown.
    var hasToken: Bool
    /// TMDB could not be asked (shown instead of the choices).
    var loadError: String? = nil
}

/// Logo of a streaming service (TMDB image, small).
struct ProviderLogo: HTML, Sendable {
    /// TMDB logo path, or `nil` for a placeholder with the first letter of `name`.
    let path: String?
    /// Name of the service.
    let name: String

    var body: some HTML {
        if let path {
            img(.class("provider-logo"), .src("https://image.tmdb.org/t/p/w92\(path)"), .alt(""), .width(24), .height(24),
                .custom(name: "loading", value: "lazy"))
        } else {
            span(.class("provider-logo provider-logo-empty"), .custom(name: "aria-hidden", value: "true")) { String(name.prefix(1)) }
        }
    }
}

/// The checkboxes of one country (also swapped in by htmx when the country changes).
///
/// The container is `#streaming-providers`; the „Land“ (country) select replaces it (outer HTML).
struct StreamingProviderChoices: HTML, Sendable {
    /// Services TMDB lists for the country, one checkbox each.
    let providers: [TMDBProviderInfo]
    /// Chosen provider IDs; those not in `providers` are kept as hidden inputs.
    let selected: Set<Int>

    var body: some HTML {
        div(.id("streaming-providers"), .class("provider-choices")) {
            if providers.isEmpty {
                p(.class("muted")) { "Für dieses Land kennt TMDB keine Streamingdienste." }
            }
            // Chosen services this country's list does not show stay chosen (spec §2).
            for id in selected.subtracting(providers.map(\.providerID)).sorted() {
                input(.type(.hidden), .name("providers[]"), .value("\(id)"))
            }
            for provider in providers {
                label(.class("provider-choice")) {
                    input(.type(.checkbox), .name("providers[]"), .value("\(provider.providerID)"))
                        .attributes(.checked, when: selected.contains(provider.providerID))
                    ProviderLogo(path: provider.logoPath, name: provider.name)
                    span { provider.name }
                }
            }
        }
    }
}

/// Konto → Streamingdienste (spec §2).
///
/// Without a TMDB token it shows a hint, after a failed TMDB request the error; otherwise the form posting to
/// `/account/streaming`. Changing the „Land“ (country) select fetches `/account/streaming/providers` into
/// `#streaming-providers`.
struct AccountStreamingSection: HTML, Sendable {
    /// State of the block.
    let state: AccountStreaming

    var body: some HTML {
        p(.class("muted")) {
            "Wähle das Land und die Dienste, die du abonniert hast. Auf den Detailseiten und unter „Später ansehen“ werden sie "
            "hervorgehoben; auf Wunsch bekommst du eine Nachricht, sobald ein Titel deiner Liste dort läuft. "
            DocsLink(page: "accounts.md", label: "Mehr dazu")
            "."
        }
        if !state.hasToken {
            p(.class("muted")) { "Für die Auswahl der Dienste wird ein TMDB-Token benötigt (siehe oben)." }
        } else if let loadError = state.loadError {
            p(.class("error")) { loadError }
        } else {
            form(.method(.post), .action("/account/streaming"), .class("streaming-form")) {
                label {
                    "Land "
                    select(.name("region"), .hx.get("/account/streaming/providers"), .hx.target("#streaming-providers"),
                           .hx.swap(.outerHTML), .hx.trigger(.event(.change))) {
                        for region in state.regions {
                            option(.value(region.code)) { region.name }.attributes(.selected, when: region.code == state.region)
                        }
                    }
                }
                StreamingProviderChoices(providers: state.providers, selected: state.selected)
                button(.type(.submit), .class("primary")) { "Speichern" }
            }
        }
    }
}
