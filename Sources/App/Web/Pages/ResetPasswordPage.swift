import Elementary

/// Set a password from a one-time link (reset or invitation), or explain why the link no longer works.
struct ResetPasswordPage: HTML {
    /// nil when the link cannot be used (`problem` says why).
    let token: String?
    let purpose: PasswordTokenPurpose
    let problem: String?
    let error: String?
    /// SSO display name: invitations can also be accepted through the provider.
    var ssoName: String? = nil
    var passwordLogin = true

    private var ssoInvite: String? { purpose == .invite ? ssoName : nil }

    private var heading: String { purpose == .invite ? "Willkommen bei WatchSwifty" : "Neues Passwort" }

    var body: some HTML {
        PageLayout(title: heading, nav: nil) {
            section(.class("login")) {
                h1 { heading }
                if let token {
                    p(.class("muted")) {
                        switch (purpose, ssoInvite, passwordLogin) {
                        case (.invite, let name?, true): "Lege dein Passwort fest oder verknüpfe dein Konto mit \(name), danach bist du angemeldet."
                        case (.invite, let name?, false): "Melde dich über \(name) an, um die Einladung anzunehmen."
                        case (.invite, _, _): "Lege dein Passwort fest, danach bist du angemeldet."
                        default: "Wähle ein neues Passwort."
                        }
                    }
                    Messages(error: error, notice: nil)
                    if let name = ssoInvite {
                        a(.href("/auth/oidc/start?invite=" + formEncode(token)), .class("button primary sso")) { "Mit \(name) verknüpfen" }
                    }
                    if passwordLogin {
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
                        button(.type(.submit), .class(ssoInvite == nil ? "primary" : "")) { "Passwort speichern" }
                    }
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
