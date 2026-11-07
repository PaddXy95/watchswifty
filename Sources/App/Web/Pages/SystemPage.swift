import Elementary
import Foundation

/// Snapshot of the stored update check for rendering.
struct UpdateState {
    var enabled = false
    var checkedAt: Date?
    var latestVersion: String?
    var latestURL: String?
    var error: String?

    init(_ settings: AppSettings) {
        enabled = settings.updateCheck
        checkedAt = settings.checkedAt
        latestVersion = settings.latestVersion
        latestURL = settings.latestURL
        error = settings.checkError
    }
}

/// `07.11.2026, 14:32` in the server's time zone.
func formatDateTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "de_DE")
    formatter.timeZone = .current
    formatter.dateFormat = "dd.MM.yyyy, HH:mm"
    return formatter.string(from: date)
}

struct SystemPage: HTML {
    let nav: NavContext
    let current: AppVersion
    let state: UpdateState
    let notice: String?

    var body: some HTML {
        PageLayout(title: "System", nav: nav) {
            h1 { "System" }
            Messages(error: nil, notice: notice)
            section {
                h2 { "Version" }
                p { "Installiert: \(current.label)" }
            }
            section(.class("updates")) {
                h2 { "Updates" }
                p(.class("muted update-note")) {
                    "Für die Prüfung fragt WatchSwifty die GitHub-API (api.github.com) nach dem neuesten Release von "
                    "PaddXy95/watchswifty. GitHub sieht dabei die IP-Adresse dieses Servers; Daten aus WatchSwifty werden "
                    "nicht übertragen."
                }
                form(.method(.post), .action("/admin/system/update-check"), .class("inline-form")) {
                    label(.class("checkbox")) {
                        input(.type(.checkbox), .name("enabled"))
                            .attributes(.checked, when: state.enabled)
                        " Automatisch alle 12 Stunden prüfen"
                    }
                    button(.type(.submit)) { "Speichern" }
                }
                form(.method(.post), .action("/admin/system/check-now"), .class("inline-form")) {
                    button(.type(.submit), .class("primary")) { "Jetzt prüfen" }
                }
                UpdateResult(current: current, state: state)
            }
        }
    }
}

struct UpdateResult: HTML {
    let current: AppVersion
    let state: UpdateState

    var body: some HTML {
        div(.class("update-result")) {
            if let checkedAt = state.checkedAt {
                p(.class("muted")) { "Zuletzt geprüft: \(formatDateTime(checkedAt))" }
                if let error = state.error {
                    p(.class("error"), .custom(name: "role", value: "alert")) { error }
                }
                if let latest = state.latestVersion {
                    switch isNewerVersion(latest, than: current.version) {
                    case true?:
                        div(.class("update-available")) {
                            p {
                                strong { "Neue Version v\(latest) verfügbar" }
                                if let url = state.latestURL {
                                    " · "
                                    a(.href(url), .target(.blank), .custom(name: "rel", value: "noopener noreferrer")) { "Release-Notes" }
                                }
                            }
                            p { "So aktualisierst du (im Verzeichnis mit der docker-compose.yml):" }
                            pre { code { "docker compose pull && docker compose up -d" } }
                            p(.class("muted")) { "Mit docker run: siehe README, Abschnitt „Update“. Vorher ein Backup machen schadet nicht." }
                        }
                    case false?:
                        p(.class("notice")) { "Du nutzt die neueste Version (v\(latest))." }
                    case nil:
                        p { "Neueste Version: v\(latest). Diese Installation ist eine Entwicklerversion (\(current.label)), daher kein Vergleich." }
                    }
                }
            } else {
                p(.class("muted")) { "Noch nicht geprüft." }
            }
        }
    }
}
