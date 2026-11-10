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
    var error: String? = nil
    var mail: MailSettingsState = .notConfigured
    var mailForm = MailFormValues(baseURL: "")
    var testRecipient: String? = nil

    var body: some HTML {
        PageLayout(title: "System", nav: nav) {
            h1 { "System" }
            Messages(error: error, notice: notice)
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
                div(.class("update-actions")) {
                    form(.method(.post), .action("/admin/system/update-check"), .class("inline-form")) {
                        label(.class("checkbox")) {
                            input(.type(.checkbox), .name("enabled"))
                                .attributes(.checked, when: state.enabled)
                            "Automatisch alle 12 Stunden prüfen"
                        }
                        button(.type(.submit)) { "Speichern" }
                    }
                    form(.method(.post), .action("/admin/system/check-now"), .class("inline-form")) {
                        button(.type(.submit), .class("primary")) { "Jetzt prüfen" }
                    }
                }
                UpdateResult(current: current, state: state)
            }
            MailSection(state: mail, values: mailForm, testRecipient: testRecipient)
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

/// Values shown in the mail form: the stored settings, the admin's last (rejected) input, or a blank form.
/// Never contains the password.
struct MailFormValues {
    var host = ""
    var port = ""
    var encryption = MailEncryption.starttls.rawValue
    var username = ""
    var fromAddress = ""
    var fromName = ""
    var caFile = ""
    var baseURL = ""

    init(baseURL: String) {
        self.baseURL = baseURL
    }

    init(_ settings: MailSettings) {
        host = settings.host
        port = settings.port.map(String.init) ?? ""
        encryption = settings.encryption.rawValue
        username = settings.username ?? ""
        fromAddress = settings.fromAddress
        fromName = settings.fromName
        caFile = settings.caFile ?? ""
        baseURL = settings.baseURL
    }

    init(_ input: MailSettingsInput) {
        host = input.host
        port = input.port ?? ""
        encryption = input.encryption
        username = input.username ?? ""
        fromAddress = input.fromAddress
        fromName = input.fromName ?? ""
        caFile = input.caFile ?? ""
        baseURL = input.baseURL
    }
}

/// System → E-Mail: SMTP settings, test mail, delete.
struct MailSection: HTML {
    let state: MailSettingsState
    let values: MailFormValues
    let testRecipient: String?

    private var hasPassword: Bool { state.settings?.password != nil }

    var body: some HTML {
        section(.class("mail-settings")) {
            h2 { "E-Mail" }
            p(.class("muted")) {
                "Optional: Damit verschickt WatchSwifty Einladungen, Links für „Passwort vergessen“ und Hinweise auf neu "
                "verbundene Geräte. Die Einstellungen "
                "werden verschlüsselt gespeichert (Schlüssel TOKEN_KEY). Beispiel für SwiftyRelay und andere Anbieter: "
                "README, Abschnitt „E-Mail (optional)“."
            }
            switch state {
            case .notConfigured: p { "Nicht eingerichtet." }
            case .unreadable: p(.class("error")) { "E-Mail-Einstellungen nicht lesbar – bitte neu eintragen." }
            case .configured: p(.class("notice")) { "Eingerichtet." }
            }
            form(.method(.post), .action("/admin/system/mail")) {
                label {
                    "Server"
                    input(.type(.text), .name("host"), .value(values.host), .required, .custom(name: "autocomplete", value: "off"),
                          .custom(name: "placeholder", value: "z. B. swifty-relay oder smtp.example.com"))
                }
                label {
                    "Port (leer = Standard: 587 STARTTLS, 465 SSL/TLS, 25 ohne)"
                    input(.type(.text), .name("port"), .value(values.port), .custom(name: "inputmode", value: "numeric"))
                }
                label {
                    "Verschlüsselung"
                    select(.name("encryption")) {
                        for encryption in MailEncryption.allCases {
                            option(.value(encryption.rawValue)) { encryption.label }
                                .attributes(.selected, when: encryption.rawValue == values.encryption)
                        }
                    }
                }
                label {
                    "Benutzer (leer = ohne Anmeldung)"
                    input(.type(.text), .name("username"), .value(values.username), .custom(name: "autocomplete", value: "off"))
                }
                label {
                    "Passwort"
                    input(.type(.password), .name("password"), .custom(name: "autocomplete", value: "new-password"),
                          .custom(name: "placeholder", value: hasPassword ? "gespeichert – leer lassen zum Behalten" : ""))
                }
                p(.class("muted")) { "Ändern sich Server, Port, Verschlüsselung oder Benutzer, muss das Passwort neu eingegeben werden." }
                label {
                    "Absender-Adresse"
                    input(.type(.email), .name("fromAddress"), .value(values.fromAddress), .required)
                }
                label {
                    "Absender-Name (leer = WatchSwifty)"
                    input(.type(.text), .name("fromName"), .value(values.fromName))
                }
                label {
                    "CA-Datei (optional, Pfad im Container; leer = System-Zertifikate)"
                    input(.type(.text), .name("caFile"), .value(values.caFile),
                          .custom(name: "placeholder", value: "/certs/swifty-relay/ca/ca-bundle.pem"))
                }
                label {
                    "Adresse von WatchSwifty (für Links in Mails)"
                    input(.type(.url), .name("baseURL"), .value(values.baseURL), .required,
                          .custom(name: "placeholder", value: "https://watch.example.lan"))
                }
                button(.type(.submit), .class("primary")) { "Speichern" }
            }
            if state.settings != nil {
                div(.class("mail-tool")) {
                    h3 { "Testmail" }
                    p(.class("muted")) { "Schickt eine kurze Mail mit den gespeicherten Einstellungen. Klappt es nicht, steht hier die Ursache." }
                    form(.method(.post), .action("/admin/system/mail/test"), .class("inline-form")) {
                        input(.type(.email), .name("to"), .value(testRecipient ?? ""), .required,
                              .custom(name: "placeholder", value: "Empfänger"), .custom(name: "aria-label", value: "Empfänger der Testmail"))
                        button(.type(.submit)) { "Testmail senden" }
                    }
                }
            }
            if state != .notConfigured {
                div(.class("mail-tool")) {
                    h3 { "Einstellungen löschen" }
                    p(.class("muted")) { "Danach verschickt WatchSwifty keine Mails mehr – keine Einladungen, kein „Passwort vergessen“." }
                    form(.method(.post), .action("/admin/system/mail/delete"), .class("inline-form")) {
                        button(.type(.submit), .class("danger")) { "E-Mail-Einstellungen löschen" }
                    }
                }
            }
        }
    }
}
