import Elementary
import ElementaryHTMX2
import Foundation

struct AdminUsersPage: HTML {
    let nav: NavContext
    let users: [User]
    let currentUserID: UUID
    let error: String?
    let notice: String?

    var body: some HTML {
        PageLayout(title: "Benutzer", nav: nav) {
            h1 { "Benutzer" }
            Messages(error: error, notice: notice)
            table {
                thead { tr { th { "Benutzername" }; th { "Rolle" }; th { "Angelegt" }; th { "Aktionen" } } }
                tbody {
                    for user in users {
                        UserRow(user: user, isSelf: user.id == currentUserID)
                    }
                }
            }
            h2 { "Konto anlegen" }
            form(.method(.post), .action("/admin/users")) {
                label {
                    "Benutzername"
                    input(.type(.text), .name("username"), .required, .custom(name: "autocomplete", value: "off"))
                }
                label {
                    "Startpasswort (mindestens 8 Zeichen)"
                    input(.type(.password), .name("password"), .required, .custom(name: "autocomplete", value: "new-password"))
                }
                label {
                    input(.type(.checkbox), .name("isAdmin"), .value("true"))
                    " Admin"
                }
                button(.type(.submit), .class("primary")) { "Konto anlegen" }
            }
        }
    }
}

struct UserRow: HTML {
    let user: User
    let isSelf: Bool

    private var created: String {
        user.createdAt.map { CalendarDay.display(CalendarDay.today(now: $0)) } ?? ""
    }

    var body: some HTML {
        tr {
            td { user.username; if isSelf { " (du)" } }
            td { if user.isAdmin { span(.class("badge")) { "Admin" } } else { "Benutzer" } }
            td { created }
            td {
                let id = user.id?.uuidString ?? ""
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
