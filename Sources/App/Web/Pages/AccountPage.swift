import Elementary

struct AccountPage: HTML {
    let nav: NavContext
    let error: String?
    let notice: String?

    var body: some HTML {
        PageLayout(title: "Konto", nav: nav) {
            h1 { "Konto" }
            p(.class("muted")) { "Angemeldet als \(nav.username)" }
            h2 { "Passwort ändern" }
            Messages(error: error, notice: notice)
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
