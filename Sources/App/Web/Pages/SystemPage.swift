import Elementary
import Foundation

/// Snapshot of the stored update check for rendering.
struct UpdateState {
    var enabled = false
    var checkedAt: Date?
    var latestVersion: String?
    var latestURL: String?
    var error: String?

    /// Reads the update check from the stored settings.
    /// - Parameter settings: The app settings row.
    init(_ settings: AppSettings) {
        enabled = settings.updateCheck
        checkedAt = settings.checkedAt
        latestVersion = settings.latestVersion
        latestURL = settings.latestURL
        error = settings.checkError
    }
}

/// `07.11.2026, 14:32` in the server's time zone.
/// - Parameter date: The point in time.
/// - Returns: Date and time in German format.
func formatDateTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "de_DE")
    formatter.timeZone = .current
    formatter.dateFormat = "dd.MM.yyyy, HH:mm"
    return formatter.string(from: date)
}

/// The foldable blocks of the System page; the block of the last action (or `?open=`) is shown open.
enum SystemBlock: String, Sendable {
    case updates, mail, notifications, oidc

    /// Element ID of the block's `FoldableBlock`, e.g. `block-mail`.
    var id: String { "block-\(rawValue)" }
}

/// „System“ admin page at `/admin/system`: foldable blocks for „Version & Updates“, „E-Mail“, „Benachrichtigungen“
/// (notifications) and OIDC sign-in.
///
/// The notifications and OIDC blocks only appear when their section is given; `openBlock` is shown open.
struct SystemPage: HTML {
    let nav: NavContext
    /// The running version.
    let current: AppVersion
    /// Setting and result of the update check.
    let state: UpdateState
    /// Success message of the last action.
    let notice: String?
    /// Error message of the last action.
    var error: String? = nil
    /// State of the stored SMTP settings.
    var mail: MailSettingsState = .notConfigured
    /// Values shown in the mail form.
    var mailForm = MailFormValues(baseURL: "")
    /// Prefilled test mail recipient: the address just used, else the admin's own address.
    var testRecipient: String? = nil
    /// OIDC block content; nil leaves the block out.
    var oidc: OIDCSection? = nil
    /// Notifications block content; nil leaves the block out.
    var notifications: NotificationsSection? = nil
    /// Block of the last action (or `?open=`), shown open.
    var openBlock: SystemBlock? = nil

    var body: some HTML {
        PageLayout(title: "System", nav: nav) {
            SectionTabs.admin(.system)
            h1 { "System" }
            Messages(error: error, notice: notice)
            FoldableBlock(id: SystemBlock.updates.id, title: "Version & Updates", open: openBlock == .updates) {
            section(.class("updates")) {
                p { "Installiert: \(current.label)" }
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
            }
            FoldableBlock(id: SystemBlock.mail.id, title: "E-Mail", open: openBlock == .mail) {
                MailSection(state: mail, values: mailForm, testRecipient: testRecipient)
            }
            if let notifications {
                FoldableBlock(id: SystemBlock.notifications.id, title: "Benachrichtigungen", open: openBlock == .notifications) { notifications }
            }
            if let oidc {
                FoldableBlock(id: SystemBlock.oidc.id, title: "Anmeldung über OIDC (SSO)", open: openBlock == .oidc) { oidc }
            }
        }
    }
}

/// Result of the last update check: a newer release with update instructions, „neueste Version“ (up to date), an
/// installation newer than the found release, or no comparison for a development build; „Noch nicht geprüft“ (not
/// checked yet) before the first check.
struct UpdateResult: HTML {
    /// The running version.
    let current: AppVersion
    /// Stored result of the update check.
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
                            p(.class("muted")) {
                                "Mit docker run: siehe "
                                DocsLink(page: "operations.md#updating", label: "Anleitung zum Aktualisieren")
                                ". Vorher ein Backup machen schadet nicht."
                            }
                        }
                    case false? where isNewerVersion(current.version, than: latest) == true:
                        // Updated since the last check, or GitHub has no release for this version yet: say only what
                        // is always true.
                        p(.class("muted")) {
                            "Diese Installation ist neuer als das bei der letzten Prüfung gefundene Release (v\(latest))."
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

    /// A blank form.
    /// - Parameter baseURL: Suggested address of WatchSwifty for links in mails.
    init(baseURL: String) {
        self.baseURL = baseURL
    }

    /// The stored settings (the password is left out).
    /// - Parameter settings: The decrypted mail settings.
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

    /// The admin's input that was rejected, shown again.
    /// - Parameter input: The submitted form (the password is left out).
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
    /// State of the stored settings.
    let state: MailSettingsState
    /// Values shown in the form.
    let values: MailFormValues
    /// Prefilled test mail recipient: the address just used, else the admin's own address.
    let testRecipient: String?

    /// A password is stored: the field's placeholder says leaving it empty keeps it.
    private var hasPassword: Bool { state.settings?.password != nil }

    var body: some HTML {
        section(.class("mail-settings")) {
            p(.class("muted")) {
                "Optional: Damit verschickt WatchSwifty Einladungen, Links für „Passwort vergessen“ und Hinweise auf neu "
                "verbundene Geräte. Die Einstellungen "
                "werden verschlüsselt gespeichert (Schlüssel TOKEN_KEY). Beispiel für SwiftyRelay und andere Anbieter: "
                DocsLink(page: "email.md", label: "Anleitung zur E-Mail")
                "."
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

/// Values of the SSO form (stored settings, or what was entered when saving failed). Never the secret.
struct OIDCFormValues: Sendable {
    var displayName = ""
    var issuer = ""
    var clientID = ""
    var baseURL = ""
    /// A client secret is stored: the field's placeholder says leaving it empty keeps it.
    var hasSecret = false

    /// A blank form.
    /// - Parameter baseURL: Suggested address of WatchSwifty (base of the callback URL).
    init(baseURL: String) {
        self.baseURL = baseURL
    }

    /// The stored settings (the secret is left out).
    /// - Parameter settings: The decrypted OIDC settings.
    init(_ settings: OIDCSettings) {
        displayName = settings.displayName
        issuer = settings.issuer
        clientID = settings.clientID
        baseURL = settings.baseURL
        hasSecret = true
    }

    /// The admin's input that was rejected, shown again.
    /// - Parameter input: The submitted form (the secret is left out).
    init(_ input: OIDCSettingsInput) {
        displayName = input.displayName ?? ""
        issuer = input.issuer
        clientID = input.clientID
        baseURL = input.baseURL
    }
}

/// System → Anmeldung über OIDC (SSO): provider settings, connection test, password-login switch, delete.
struct OIDCSection: HTML, Sendable {
    /// State of the stored OIDC settings.
    let state: OIDCSettingsState
    /// Values shown in the form.
    let values: OIDCFormValues
    /// The password login is currently on.
    let passwordLogin: Bool
    /// `PASSWORD_LOGIN=true` forces the password login on, whatever is stored.
    let passwordLoginForced: Bool

    /// Display name of the provider, „SSO“ while none is stored.
    private var name: String { state.settings?.displayName ?? "SSO" }
    /// Callback URL to register at the provider, built from the entered address; nil when that is not a valid base URL.
    private var redirectURL: String? {
        MailSettingsService.baseURL(values.baseURL).map { $0 + "/auth/oidc/callback" }
    }

    var body: some HTML {
        section(.class("mail-settings")) {
            p(.class("muted")) {
                "Optional: Anmelden über einen eigenen Identity-Provider (Pocket ID, Authentik, Keycloak, Authelia …). "
                "Die Einstellungen werden verschlüsselt gespeichert (Schlüssel TOKEN_KEY). "
                DocsLink(page: "sso.md", label: "Anleitung zu SSO")
                "."
            }
            switch state {
            case .notConfigured: p { "Nicht eingerichtet." }
            case .unreadable: p(.class("error")) { "Anmelde-Einstellungen nicht lesbar – bitte neu eintragen (der Server-Schlüssel hat sich geändert)." }
            case .configured: p(.class("notice")) { "Eingerichtet – auf der Anmeldeseite erscheint „Mit \(name) anmelden“." }
            }
            if let redirectURL {
                p { "Rücksprung-URL für den Provider: "; code { redirectURL } }
            }
            form(.method(.post), .action("/admin/system/oidc")) {
                label {
                    "Anzeigename (leer = SSO)"
                    input(.type(.text), .name("displayName"), .value(values.displayName), .custom(name: "maxlength", value: "40"),
                          .custom(name: "placeholder", value: "z. B. Pocket ID"))
                }
                label {
                    "Issuer"
                    input(.type(.url), .name("issuer"), .value(values.issuer), .required, .custom(name: "autocomplete", value: "off"),
                          .custom(name: "placeholder", value: "https://auth.example.de/application/o/watchswifty/"))
                }
                label {
                    "Client-ID"
                    input(.type(.text), .name("clientID"), .value(values.clientID), .required, .custom(name: "autocomplete", value: "off"))
                }
                label {
                    "Client-Secret"
                    input(.type(.password), .name("clientSecret"), .custom(name: "autocomplete", value: "new-password"),
                          .custom(name: "placeholder", value: values.hasSecret ? "gespeichert – leer lassen zum Behalten" : ""))
                }
                p(.class("muted")) { "Ändern sich Issuer oder Client-ID, muss das Secret neu eingegeben werden." }
                label {
                    "Adresse von WatchSwifty (Rücksprung-URL = Adresse + /auth/oidc/callback)"
                    input(.type(.url), .name("baseURL"), .value(values.baseURL), .required,
                          .custom(name: "placeholder", value: "https://watch.example.lan"))
                }
                button(.type(.submit), .class("primary")) { "Speichern" }
            }
            if state.settings != nil {
                div(.class("mail-tool")) {
                    h3 { "Verbindung testen" }
                    p(.class("muted")) { "Lädt die Discovery und die Schlüssel des Providers neu." }
                    form(.method(.post), .action("/admin/system/oidc/test"), .class("inline-form")) {
                        button(.type(.submit)) { "Verbindung testen" }
                    }
                }
                div(.class("mail-tool")) {
                    h3 { "Passwort-Login" }
                    if passwordLoginForced {
                        p(.class("notice")) { "Per PASSWORD_LOGIN=true erzwungen – der Passwort-Login bleibt an, bis die Variable entfernt ist." }
                        if state.settings?.passwordLogin == false {
                            p { "Gespeichert: aus – gilt wieder, sobald die Variable entfernt ist." }
                            form(.method(.post), .action("/admin/system/password-login"), .class("inline-form")) {
                                input(.type(.hidden), .name("enabled"), .value("true"))
                                button(.type(.submit)) { "Passwort-Login dauerhaft einschalten" }
                            }
                        }
                    } else if passwordLogin {
                        p(.class("muted")) {
                            "Erst abschalten, wenn alle Konten verknüpft sind (Benutzer-Seite) – dein eigenes muss verknüpft sein. "
                            "Notfall: PASSWORD_LOGIN=true setzen und neu starten."
                        }
                        form(.method(.post), .action("/admin/system/password-login"), .class("inline-form")) {
                            input(.type(.hidden), .name("enabled"), .value("false"))
                            button(.type(.submit), .class("danger")) { "Passwort-Login abschalten" }
                        }
                    } else {
                        p { "Passwort-Login ist aus – Anmeldung nur über \(name)." }
                        form(.method(.post), .action("/admin/system/password-login"), .class("inline-form")) {
                            input(.type(.hidden), .name("enabled"), .value("true"))
                            button(.type(.submit)) { "Passwort-Login einschalten" }
                        }
                    }
                }
            }
            if state != .notConfigured {
                div(.class("mail-tool")) {
                    h3 { "Einstellungen löschen" }
                    p(.class("muted")) { "Danach gibt es nur noch den Passwort-Login; Verknüpfungen bleiben gespeichert." }
                    form(.method(.post), .action("/admin/system/oidc/delete"), .class("inline-form")) {
                        button(.type(.submit), .class("danger")) { "Anmelde-Einstellungen löschen" }
                    }
                }
            }
        }
    }
}

/// System → Benachrichtigungen: time of the daily pass and the KNot webhook address.
struct NotificationsSection: HTML, Sendable {
    /// Stored daily-run time, last run and webhook address.
    let settings: NotificationSettings
    /// Identifier of the server's time zone.
    let timeZone: String
    /// When the next daily pass runs.
    let nextRun: Date
    /// Rejected input shown again (time, address).
    var entered: (time: String, url: String)? = nil

    /// The server runs in UTC: shows the hint to set `TZ` in the container.
    private var isUTC: Bool { ["UTC", "GMT", "Etc/UTC", "Etc/GMT"].contains(timeZone) }

    var body: some HTML {
        section(.class("mail-settings notification-settings")) {
            p(.class("muted")) {
                "Wer Serien beobachtet, kann sich unter „Konto → Benachrichtigungen“ über neue Folgen informieren lassen – "
                "per E-Mail oder über einen Webhook. Geprüft wird einmal am Tag; dabei gleicht WatchSwifty auch die Serien mit TMDB ab. "
                DocsLink(page: "notifications.md", label: "Anleitung zu Benachrichtigungen")
                "."
            }
            form(.method(.post), .action("/admin/system/notifications")) {
                label {
                    "Täglicher Abgleich um"
                    input(.type(.time), .name("dailyRunTime"), .value(entered?.time ?? settings.dailyRunTime), .required)
                }
                p(.class("muted")) { "Zeitzone des Servers: \(timeZone)" }
                if isUTC {
                    p(.class("muted")) { "Der Server läuft in UTC – im Container TZ setzen, z. B. TZ=Europe/Berlin." }
                }
                p(.class("muted")) {
                    "Letzter Durchgang: \(settings.lastRunAt.map { formatDateTime($0) + " Uhr" } ?? "noch keiner") · "
                    "Nächster: \(formatDateTime(nextRun)) Uhr"
                }
                label {
                    "Webhook-Adresse (KNot, optional)"
                    input(.type(.url), .name("webhookURL"), .value(entered?.url ?? settings.webhookURL ?? ""),
                          .custom(name: "placeholder", value: "https://knot.example.lan/hook"))
                }
                p(.class("muted")) {
                    a(.href("https://github.com/nexus421/KNot"), .target(.blank), .custom(name: "rel", value: "noopener noreferrer")) { "KNot" }
                    " leitet Webhooks als Mail weiter. Lege dort für jede Person ein eigenes Ziel mit ihrer Mail-Adresse an, "
                    "erzeuge den Schlüssel mit „java -jar knot.jar key“ und gib ihn weiter – sie trägt ihn unter "
                    "„Konto → Benachrichtigungen“ ein. Leer lassen schaltet den Webhook ab."
                }
                button(.type(.submit), .class("primary")) { "Speichern" }
            }
            if settings.webhookURL != nil {
                form(.method(.post), .action("/admin/system/notifications/webhook/delete"), .class("inline-form")) {
                    button(.type(.submit)) { "Webhook entfernen" }
                }
            }
        }
    }
}
