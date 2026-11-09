import Elementary
import ElementaryHTMX2
import Foundation

struct AccountPage: HTML {
    let nav: NavContext
    let tokenSuffix: String?
    let error: String?
    let notice: String?
    var followed: [FollowedSeries] = []
    /// A token is stored but cannot be decrypted (server key changed).
    var tokenUnreadable = false
    /// App devices and manual tokens (App API).
    var devices: [APIToken] = []
    /// A token created just now (shown only once).
    var newToken: String? = nil
    var email: EmailState = .none
    var mailConfigured = false

    var body: some HTML {
        PageLayout(title: "Konto", nav: nav) {
            h1 { "Konto" }
            p(.class("muted")) { "Angemeldet als \(nav.username)" }
            Messages(error: error, notice: notice)

            h2 { "TMDB-Token" }
            p(.class("muted")) {
                "Für Suche, Poster und den Netflix-Import brauchst du einen eigenen kostenlosen Read Access Token von "
                a(.href("https://www.themoviedb.org/settings/api"), .target(.blank), .custom(name: "rel", value: "noopener noreferrer")) { "themoviedb.org" }
                "."
            }
            if let tokenSuffix {
                p { "Hinterlegt: \(tokenSuffix)" }
            } else if tokenUnreadable {
                p(.class("error")) { "Token nicht lesbar – bitte neu eintragen (der Server-Schlüssel hat sich geändert)." }
            } else {
                p { "Kein TMDB-Token hinterlegt." }
            }
            TokenHelp(open: tokenSuffix == nil)
            form(.method(.post), .action("/account/tmdb-token"), .class("inline-form")) {
                input(.type(.password), .name("token"), .required, .custom(name: "autocomplete", value: "off"),
                      .custom(name: "placeholder", value: "Read Access Token"), .custom(name: "aria-label", value: "TMDB-Token"))
                button(.type(.submit), .class("primary")) { tokenSuffix == nil ? "Speichern" : "Ersetzen" }
            }
            if tokenSuffix != nil {
                form(.method(.post), .action("/account/tmdb-token/remove"), .class("inline-form")) {
                    button(.type(.submit)) { "Entfernen" }
                }
            }

            h2 { "Beobachtete Serien" }
            if followed.isEmpty {
                p(.class("muted")) { "Du beobachtest noch keine Serien. Auf der Serienseite gibt es dafür „🔔 Beobachten“." }
            } else {
                ul(.class("followed-list")) {
                    for series in followed {
                        li {
                            a(.href("/tv/\(series.tmdbID)")) { series.name }
                            if let next = series.nextEpisode, let air = next.airDate {
                                span(.class("muted")) { "Nächste Folge: \(next.code) am \(CalendarDay.display(air))" }
                            }
                            button(.class("link-button"), .hx.post("/tv/\(series.tmdbID)/follow"),
                                   .hx.vals(#"{"followed":"false","context":"account"}"#),
                                   .hx.target("closest li"), .hx.swap(.outerHTML)) { "Nicht mehr beobachten" }
                        }
                    }
                }
            }

            h2 { "Geräte" }
            p(.class("muted")) {
                "Apps und Skripte mit Zugriff auf dein Konto über die API (Doku unter "
                a(.href("/api")) { "/api" }
                "). Jede Anmeldung gilt 90 Tage."
            }
            if let newToken {
                p(.class("notice"), .custom(name: "role", value: "status")) {
                    "Neues Token (wird nur jetzt angezeigt): "
                    code(.class("new-token")) { newToken }
                }
            }
            if devices.isEmpty {
                p(.class("muted")) { "Keine Geräte verbunden." }
            } else {
                ul(.class("device-list")) {
                    for device in devices {
                        li {
                            strong { device.name }
                            span(.class("muted")) {
                                " \(device.tokenKind == .manual ? "manuell erstellt" : "Gerät") · angelegt \(formatDateTime(device.createdAt))"
                                " · läuft ab \(formatDateTime(device.expiresAt))"
                                " · zuletzt benutzt \(device.lastUsedAt.map(formatDateTime) ?? "nie")"
                            }
                            form(.method(.post), .action("/account/devices/\(device.id?.uuidString ?? "")/revoke"), .class("inline-form")) {
                                button(.type(.submit), .class("link-button")) { "Abmelden" }
                            }
                        }
                    }
                }
            }
            form(.method(.post), .action("/account/devices"), .class("inline-form")) {
                input(.type(.text), .name("name"), .required, .custom(name: "maxlength", value: "60"),
                      .custom(name: "placeholder", value: "Name, z. B. Skript"), .custom(name: "aria-label", value: "Name des Tokens"))
                button(.type(.submit)) { "Token erstellen" }
            }

            h2 { "E-Mail-Adresse" }
            p(.class("muted")) { "Für „Passwort vergessen“. Nur du siehst sie vollständig." }
            if !mailConfigured {
                p(.class("muted")) { "Der Admin hat den Mail-Versand noch nicht eingerichtet – „Passwort vergessen“ funktioniert erst danach." }
            }
            switch email {
            case .none: p { "Keine Adresse hinterlegt." }
            case .unreadable: p(.class("error")) { "Adresse nicht lesbar – bitte neu eintragen (der Server-Schlüssel hat sich geändert)." }
            case .address(let address): p { "Hinterlegt: \(address)" }
            }
            form(.method(.post), .action("/account/email")) {
                label {
                    "E-Mail-Adresse (leer lassen zum Entfernen)"
                    input(.type(.email), .name("email"), .value(email.address ?? ""), .custom(name: "autocomplete", value: "email"))
                }
                label {
                    "Aktuelles Passwort"
                    input(.type(.password), .name("currentPassword"), .required, .custom(name: "autocomplete", value: "current-password"))
                }
                button(.type(.submit)) { "Adresse speichern" }
            }

            h2 { "Passwort ändern" }
            form(.method(.post), .action("/account/password")) {
                label {
                    "Aktuelles Passwort"
                    input(.type(.password), .name("currentPassword"), .required, .custom(name: "autocomplete", value: "current-password"))
                }
                label {
                    "Neues Passwort (mindestens 8 Zeichen)"
                    input(.type(.password), .name("newPassword"), .required, .custom(name: "minlength", value: "8"),
                          .custom(name: "autocomplete", value: "new-password"))
                }
                button(.type(.submit), .class("primary")) { "Passwort ändern" }
            }
        }
    }
}

/// Step-by-step help for getting a TMDB token (open while none is stored).
struct TokenHelp: HTML {
    var open = false

    var body: some HTML {
        details(.class("token-help")) {
            summary { "So bekommst du einen TMDB-Token" }
            ol {
                li {
                    "Kostenloses Konto bei TMDB anlegen: "
                    a(.href("https://www.themoviedb.org/signup"), .target(.blank), .custom(name: "rel", value: "noopener noreferrer")) { "themoviedb.org/signup" }
                    " (E-Mail bestätigen)."
                }
                li {
                    "Angemeldet zu Einstellungen → API gehen: "
                    a(.href("https://www.themoviedb.org/settings/api"), .target(.blank), .custom(name: "rel", value: "noopener noreferrer")) { "themoviedb.org/settings/api" }
                    "."
                }
                li { "Einen API-Schlüssel anfordern (private, nicht-kommerzielle Nutzung), Nutzungsbedingungen akzeptieren und das kurze Formular ausfüllen – als Anwendung z. B. „WatchSwifty, privater Serien-Tracker“." }
                li {
                    "Danach auf derselben Seite den langen "
                    strong { "„API Read Access Token“" }
                    " kopieren (beginnt mit „eyJ“) – nicht den kurzen „API Key“."
                }
                li { "Hier einfügen und speichern. WatchSwifty prüft den Token sofort bei TMDB." }
            }
        }
        .attributes(.custom(name: "open", value: ""), when: open)
    }
}
