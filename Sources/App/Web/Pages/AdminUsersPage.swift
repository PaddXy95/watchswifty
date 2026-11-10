import Elementary
import ElementaryHTMX2
import Foundation

struct AdminUsersPage: HTML {
    let nav: NavContext
    let users: [AdminUserRow]
    var mailConfigured = false
    let currentUserID: UUID
    let error: String?
    let notice: String?

    var body: some HTML {
        PageLayout(title: "Benutzer", nav: nav) {
            h1 { "Benutzer" }
            Messages(error: error, notice: notice)
            table {
                thead { tr { th { "Benutzername" }; th { "Rolle" }; th { "E-Mail" }; th { "Angelegt" }; th { "Aktionen" } } }
                tbody {
                    for row in users {
                        UserRow(row: row, isSelf: row.user.id == currentUserID)
                    }
                }
            }
            h2 { "Konto anlegen" }
            if mailConfigured {
                p(.class("muted")) { "Mit E-Mail-Adresse und ohne Startpasswort bekommt die Person eine Einladung und legt ihr Passwort selbst fest." }
            } else {
                p(.class("muted")) { "Einladungen per Mail gehen erst, wenn der Mail-Versand unter System eingerichtet ist." }
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
                label {
                    mailConfigured ? "Startpasswort (mindestens 8 Zeichen; leer lassen für eine Einladung)" : "Startpasswort (mindestens 8 Zeichen)"
                    input(.type(.password), .name("password"), .custom(name: "autocomplete", value: "new-password"))
                        .attributes(.required, when: !mailConfigured)
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

struct UserRow: HTML {
    let row: AdminUserRow
    let isSelf: Bool

    private var user: User { row.user }

    private var created: String {
        user.createdAt.map { CalendarDay.display(CalendarDay.today(now: $0)) } ?? ""
    }

    var body: some HTML {
        tr {
            td { user.username; if isSelf { " (du)" } }
            td {
                if user.isAdmin { span(.class("badge")) { "Admin" } } else { "Benutzer" }
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
                if !user.hasPassword {
                    form(.method(.post), .action("/admin/users/\(id)/invite"), .class("inline-form")) {
                        button(.type(.submit)) { "Einladung erneut senden" }
                    }
                }
                form(.method(.post), .action("/admin/users/\(id)/password"), .class("inline-form")) {
                    input(.type(.password), .name("password"), .required, .custom(name: "placeholder", value: "Neues Passwort"),
                          .custom(name: "autocomplete", value: "new-password"))
                    button(.type(.submit)) { "Passwort setzen" }
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
