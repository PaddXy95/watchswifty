import Elementary

struct LoginPage: HTML {
    let error: String?
    let username: String

    var body: some HTML {
        PageLayout(title: "Anmelden", nav: nil) {
            section(.class("login")) {
                h1 { "WatchSwifty" }
                if let error {
                    p(.class("error"), .custom(name: "role", value: "alert")) { error }
                }
                form(.method(.post), .action("/login")) {
                    label {
                        "Benutzername"
                        input(.type(.text), .name("username"), .value(username), .required, .autofocus,
                              .custom(name: "autocomplete", value: "username"))
                    }
                    label {
                        "Passwort"
                        input(.type(.password), .name("password"), .required,
                              .custom(name: "autocomplete", value: "current-password"))
                    }
                    button(.type(.submit), .class("primary")) { "Anmelden" }
                }
            }
        }
    }
}
