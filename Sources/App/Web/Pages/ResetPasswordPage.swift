import Elementary

/// Set a password from a one-time link (reset or invitation), or explain why the link no longer works.
struct ResetPasswordPage: HTML {
    /// nil when the link cannot be used (`problem` says why).
    let token: String?
    let purpose: PasswordTokenPurpose
    let problem: String?
    let error: String?

    private var heading: String { purpose == .invite ? "Willkommen bei WatchSwifty" : "Neues Passwort" }

    var body: some HTML {
        PageLayout(title: heading, nav: nil) {
            section(.class("login")) {
                h1 { heading }
                if let token {
                    p(.class("muted")) {
                        purpose == .invite ? "Lege dein Passwort fest, danach bist du angemeldet." : "Wähle ein neues Passwort."
                    }
                    Messages(error: error, notice: nil)
                    form(.method(.post), .action("/reset-password")) {
                        input(.type(.hidden), .name("token"), .value(token))
                        label {
                            "Neues Passwort (mindestens 8 Zeichen)"
                            input(.type(.password), .name("password"), .required, .autofocus, .custom(name: "minlength", value: "8"),
                                  .custom(name: "autocomplete", value: "new-password"))
                        }
                        label {
                            "Passwort wiederholen"
                            input(.type(.password), .name("passwordRepeat"), .required, .custom(name: "minlength", value: "8"),
                                  .custom(name: "autocomplete", value: "new-password"))
                        }
                        button(.type(.submit), .class("primary")) { "Passwort speichern" }
                    }
                } else {
                    p(.class("error"), .custom(name: "role", value: "alert")) { problem ?? "" }
                    p {
                        a(.href("/forgot-password")) { "Passwort vergessen" }
                        " · "
                        a(.href("/login")) { "Zur Anmeldung" }
                    }
                }
            }
        }
    }
}
