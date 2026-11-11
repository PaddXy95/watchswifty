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
    /// OIDC section; nil without OIDC.
    var sso: AccountSSO? = nil
    /// „Passwort ändern“ only for accounts with a password while the password login is on.
    var passwordChange = true
    /// SSO account without a fresh provider confirmation: a manual token first needs „Über … bestätigen“.
    var tokenNeedsReauth = false
    var notifications: AccountNotifications? = nil

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

            if let notifications { AccountNotificationsSection(state: notifications) }

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
            if tokenNeedsReauth, let sso {
                p(.class("muted")) { "Für ein neues Token einmal über \(sso.name) bestätigen (gilt 5 Minuten)." }
                form(.method(.post), .action("/account/oidc/reauth"), .class("inline-form")) {
                    button(.type(.submit)) { "Über \(sso.name) bestätigen" }
                }
            }
            form(.method(.post), .action("/account/devices"), .class("inline-form")) {
                input(.type(.text), .name("name"), .required, .custom(name: "maxlength", value: "60"),
                      .custom(name: "placeholder", value: "Name, z. B. Skript"), .custom(name: "aria-label", value: "Name des Tokens"))
                button(.type(.submit)) { "Token erstellen" }
            }

            if let sso {
                h2 { sso.name }
                if sso.linked {
                    p { "Mit \(sso.name) verknüpft." }
                } else {
                    p(.class("muted")) { "Verknüpfe dein Konto, um dich künftig über \(sso.name) anzumelden." }
                    form(.method(.post), .action("/account/oidc/link")) {
                        if sso.needsPassword {
                            label {
                                "Aktuelles Passwort"
                                input(.type(.password), .name("currentPassword"), .required,
                                      .custom(name: "autocomplete", value: "current-password"))
                            }
                        }
                        button(.type(.submit), .class("primary")) { "Mit \(sso.name) verknüpfen" }
                    }
                }
            }

            h2 { "E-Mail-Adresse" }
            if let sso, sso.emailFromProvider {
                switch email {
                case .address(let address): p { "Hinterlegt: \(address)" }
                default: p { "Keine Adresse hinterlegt." }
                }
                p(.class("muted")) { "Die Adresse kommt von \(sso.name) – dort ändern." }
            } else {
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
            }

            if passwordChange {
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
}

/// What the Konto page shows about the OIDC link.
struct AccountSSO: Sendable {
    let name: String
    let linked: Bool
    let emailFromProvider: Bool
    /// Linking asks for the current password (accounts that have one).
    var needsPassword = false
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

/// What Konto → Benachrichtigungen shows.
struct AccountNotifications: Sendable {
    var announced: Bool
    var soon: Bool
    var today: Bool
    var available: [NotifyChannel]
    var active: NotifyChannel?
    var preferred: NotifyChannel
    /// The admin set up a webhook address (only then the key field appears).
    var webhookConfigured: Bool
    var keyState: WebhookKeyState
    var dailyRunTime: String
    /// Changing the key asks for the current password (accounts with a password).
    var needsPassword: Bool
}

struct AccountNotificationsSection: HTML, Sendable {
    let state: AccountNotifications

    private func channelName(_ channel: NotifyChannel) -> String {
        switch channel {
        case .mail: "E-Mail"
        case .webhook: "Webhook (KNot)"
        }
    }

    var body: some HTML {
        h2 { "Benachrichtigungen" }
        form(.method(.post), .action("/account/notifications"), .class("notification-prefs")) {
            p { "Neue Folgen beobachteter Serien:" }
            label(.class("checkbox")) {
                input(.type(.checkbox), .name("announced")).attributes(.checked, when: state.announced)
                " sobald eine neue Folge bekannt wird"
            }
            label(.class("checkbox")) {
                input(.type(.checkbox), .name("soon")).attributes(.checked, when: state.soon)
                " 3 Tage vor der Ausstrahlung"
            }
            label(.class("checkbox")) {
                input(.type(.checkbox), .name("today")).attributes(.checked, when: state.today)
                " am Tag der Ausstrahlung"
            }
            p(.class("muted")) {
                "Geprüft wird täglich um \(state.dailyRunTime) Uhr; alles Neue kommt in einer Nachricht. "
                "Der Hinweis auf neu verbundene Geräte geht immer über denselben Weg. "
                DocsLink(page: "notifications.md", label: "Mehr dazu")
                "."
            }
            if state.available.count > 1 {
                p { "Senden per" }
                for channel in state.available {
                    label(.class("checkbox")) {
                        input(.type(.radio), .name("channel"), .value(channel.rawValue))
                            .attributes(.checked, when: channel == (state.active ?? state.preferred))
                        " \(channelName(channel))"
                    }
                }
            } else if let only = state.available.first {
                // Keeps the stored choice: a channel that is gone for a while must not be replaced for good.
                input(.type(.hidden), .name("channel"), .value(state.preferred.rawValue))
                p { "Senden per \(channelName(only))" }
            } else {
                input(.type(.hidden), .name("channel"), .value(state.preferred.rawValue))
                p(.class("muted")) {
                    "Noch kein Versandweg: hinterlege eine Mail-Adresse oder einen Webhook-Schlüssel – oder der Admin hat den "
                    "Versand noch nicht eingerichtet."
                }
            }
            button(.type(.submit), .class("primary")) { "Speichern" }
        }
        if state.webhookConfigured {
            h3 { "Webhook-Schlüssel (KNot)" }
            switch state.keyState {
            case .key: p { "Schlüssel gespeichert." }
            case .unreadable: p(.class("error")) { "Schlüssel nicht lesbar – bitte neu eintragen." }
            case .none: p(.class("muted")) { "Kein Schlüssel hinterlegt. Den Schlüssel bekommst du vom Admin." }
            }
            form(.method(.post), .action("/account/notifications/webhook-key")) {
                label {
                    "Webhook-Schlüssel"
                    input(.type(.password), .name("key"), .required, .custom(name: "autocomplete", value: "off"))
                }
                if state.needsPassword {
                    label {
                        "Aktuelles Passwort"
                        input(.type(.password), .name("currentPassword"), .required, .custom(name: "autocomplete", value: "current-password"))
                    }
                }
                button(.type(.submit)) { "Schlüssel speichern" }
            }
            if state.keyState != .none {
                form(.method(.post), .action("/account/notifications/webhook-key/remove"), .class("inline-form")) {
                    if state.needsPassword {
                        input(.type(.password), .name("currentPassword"), .required, .custom(name: "autocomplete", value: "current-password"),
                              .custom(name: "placeholder", value: "Aktuelles Passwort"), .custom(name: "aria-label", value: "Aktuelles Passwort"))
                    }
                    button(.type(.submit)) { "Schlüssel entfernen" }
                }
            }
        }
        if let active = state.active {
            form(.method(.post), .action("/account/notifications/test"), .class("inline-form")) {
                button(.type(.submit)) { "Testnachricht senden" }
                span(.class("muted")) { " (per \(channelName(active)))" }
            }
        }
    }
}
