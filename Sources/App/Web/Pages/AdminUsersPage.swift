import Elementary
import ElementaryHTMX2
import Foundation

/// „Benutzer“ (users) admin page at `/admin/users`: SSO link status, the identity confirmation box, a freshly created
/// link, the table of all accounts and the form to create an account.
///
/// The hints and the create form depend on the setup: invitations need mail, the start password field is only shown
/// while the password login is on.
struct AdminUsersPage: HTML {
    let nav: NavContext
    /// All accounts with their link and invitation state.
    let users: [AdminUserRow]
    /// Mail is set up: an account created without start password gets an invitation.
    var mailConfigured = false
    /// The signed-in admin; their row is marked „(du)“ (you) and cannot be deleted.
    let currentUserID: UUID
    /// Error message of the last action.
    let error: String?
    /// Success message of the last action.
    let notice: String?
    /// SSO display name when OIDC is configured.
    var ssoName: String? = nil
    /// A link just created for passing on (shown only in this response).
    var ssoLink: AdminSSOLink? = nil
    /// How many accounts (and whether an admin) are linked to the provider; shown with `ssoName`.
    var readiness: OIDCReadiness? = nil
    /// Password login is on: shows the password fields.
    var passwordLogin = true
    /// How to confirm before granting admin rights or acting on another admin; nil while a confirmation is fresh.
    var confirm: AdminConfirmBox? = nil

    var body: some HTML {
        PageLayout(title: "Benutzer", nav: nav) {
            SectionTabs.admin(.users)
            h1 { "Benutzer" }
            Messages(error: error, notice: notice)
            if let ssoName, let readiness {
                p(.class("muted")) {
                    "\(readiness.linked) von \(readiness.total) Konten mit \(ssoName) verknüpft · Admin verknüpft: \(readiness.adminLinked ? "ja" : "nein")"
                    if passwordLogin {
                        " – Erst wenn alle verknüpft sind (mindestens ein Admin), den Passwort-Login unter Admin → System abschalten."
                    }
                }
            }
            if let confirm {
                div(.class("admin-confirm")) {
                    p(.class("muted")) {
                        "Admin-Rechte vergeben sowie Passwort oder Verknüpfungslink für andere Admins: erst bestätigen, dass du es bist (gilt 5 Minuten)."
                    }
                    switch confirm {
                    case .password:
                        form(.method(.post), .action("/admin/users/confirm"), .class("inline-form")) {
                            input(.type(.password), .name("password"), .required, .custom(name: "placeholder", value: "Dein Passwort"),
                                  .custom(name: "aria-label", value: "Dein Passwort"), .custom(name: "autocomplete", value: "current-password"))
                            button(.type(.submit)) { "Bestätigen" }
                        }
                    case let .sso(name):
                        form(.method(.post), .action("/admin/users/confirm-sso"), .class("inline-form")) {
                            button(.type(.submit)) { "Über \(name) bestätigen" }
                        }
                    }
                }
            }
            if let ssoLink {
                p(.class("notice")) {
                    "Verknüpfungslink für \(ssoLink.username) (7 Tage gültig, nur jetzt sichtbar – bitte weitergeben): "
                    code { ssoLink.url }
                }
            }
            table {
                thead { tr { th { "Benutzername" }; th { "Rolle" }; th { "E-Mail" }; th { "Angelegt" }; th { "Aktionen" } } }
                tbody {
                    for row in users {
                        UserRow(row: row, isSelf: row.user.id == currentUserID, ssoName: ssoName, passwordLogin: passwordLogin)
                    }
                }
            }
            h2 { "Konto anlegen" }
            if !passwordLogin {
                p(.class("muted")) { "Der Passwort-Login ist abgeschaltet: neue Konten nur per Einladung (Mail) – oder die Person meldet sich einfach über \(ssoName ?? "SSO") an." }
            } else if mailConfigured {
                p(.class("muted")) { "Mit E-Mail-Adresse und ohne Startpasswort bekommt die Person eine Einladung und legt ihr Passwort selbst fest." }
            } else {
                p(.class("muted")) { "Einladungen per Mail gehen erst, wenn der Mail-Versand unter Admin → System eingerichtet ist." }
            }
            form(.method(.post), .action("/admin/users")) {
                label {
                    "Benutzername"
                    input(.type(.text), .name("username"), .required, .custom(name: "autocomplete", value: "off"))
                }
                label {
                    "E-Mail-Adresse (optional)"
                    input(.type(.email), .name("email"), .custom(name: "autocomplete", value: "off"))
                }
                if passwordLogin {
                label {
                    mailConfigured ? "Startpasswort (mindestens 8 Zeichen; leer lassen für eine Einladung)" : "Startpasswort (mindestens 8 Zeichen)"
                    input(.type(.password), .name("password"), .custom(name: "autocomplete", value: "new-password"))
                        .attributes(.required, when: !mailConfigured)
                }
                }
                label(.class("checkbox")) {
                    input(.type(.checkbox), .name("isAdmin"), .value("true"))
                    "Admin"
                }
                button(.type(.submit), .class("primary")) { "Konto anlegen" }
            }
        }
    }
}

/// How the signed-in admin confirms (security audit F10): with their password, or through the provider.
enum AdminConfirmBox: Equatable, Sendable {
    case password
    case sso(String)
}

/// A „Verknüpfungslink“ to show once on the users page.
struct AdminSSOLink: Sendable {
    /// Account the link is for.
    let username: String
    /// The link to pass on.
    let url: String
}

/// Table row of one account on the users page: name, role with SSO and invitation badges, e-mail hint, creation date and
/// the actions.
///
/// Actions: „Verknüpfungslink“ (link token, for other unlinked accounts while SSO is configured), resending the
/// invitation (no password and not linked), setting a password (while the password login is on), toggling admin rights
/// and deleting (not for oneself). Deleting asks for confirmation and swaps `main` with the reloaded page.
struct UserRow: HTML {
    /// The account with its link and invitation state.
    let row: AdminUserRow
    /// The row is the signed-in admin's own account.
    let isSelf: Bool
    /// SSO display name when OIDC is configured.
    var ssoName: String? = nil
    /// Password login is on: shows the „Passwort setzen“ (set password) form.
    var passwordLogin = true

    /// The account of the row.
    private var user: User { row.user }

    /// Creation day for display, empty when unknown.
    private var created: String {
        user.createdAt.map { CalendarDay.display(CalendarDay.today(now: $0)) } ?? ""
    }

    var body: some HTML {
        tr {
            td { user.username; if isSelf { " (du)" } }
            td {
                if user.isAdmin { span(.class("badge")) { "Admin" } } else { "Benutzer" }
                if let ssoName, row.ssoLinked { " "; span(.class("badge")) { ssoName } }
                switch row.invite {
                case .none: ""
                case .pending(let expires): span(.class("muted")) { " · Einladung offen (bis \(CalendarDay.display(CalendarDay.today(now: expires))))" }
                case .expired: span(.class("muted")) { " · Einladung abgelaufen" }
                }
            }
            td { row.emailHint ?? "–" }
            td { created }
            td {
                let id = user.id?.uuidString ?? ""
                if let ssoName, !row.ssoLinked, !isSelf {
                    form(.method(.post), .action("/admin/users/\(id)/sso-link"), .class("inline-form")) {
                        button(.type(.submit)) { "Verknüpfungslink (\(ssoName))" }
                    }
                }
                if !user.hasPassword, !row.ssoLinked {
                    form(.method(.post), .action("/admin/users/\(id)/invite"), .class("inline-form")) {
                        button(.type(.submit)) { "Einladung erneut senden" }
                    }
                }
                if passwordLogin {
                form(.method(.post), .action("/admin/users/\(id)/password"), .class("inline-form")) {
                    input(.type(.password), .name("password"), .required, .custom(name: "placeholder", value: "Neues Passwort"),
                          .custom(name: "autocomplete", value: "new-password"))
                    button(.type(.submit)) { "Passwort setzen" }
                }
                }
                form(.method(.post), .action("/admin/users/\(id)/admin"), .class("inline-form")) {
                    input(.type(.hidden), .name("isAdmin"), .value(user.isAdmin ? "false" : "true"))
                    button(.type(.submit)) { user.isAdmin ? "Admin entziehen" : "Zum Admin machen" }
                }
                if !isSelf {
                    button(.hx.delete("/admin/users/\(id)"),
                           .hx.confirm("Konto „\(user.username)“ und alle zugehörigen Daten löschen?"),
                           .hx.target("main"), .hx.select("main"), .hx.swap(.outerHTML)) { "Löschen" }
                }
            }
        }
    }
}
