import Elementary

struct LoginPage: HTML {
    let error: String?
    let username: String
    /// Where to continue after signing in (only the app login, see `isSafeReturnTo`).
    var returnTo: String? = nil
    /// Mail is set up, so „Passwort vergessen?“ can help.
    var forgotPasswordLink = false
    /// SSO display name when OIDC is configured: shows „Mit … anmelden“.
    var ssoName: String? = nil
    /// Password login switch (System): without it only the OIDC button is shown.
    var passwordLogin = true

    private var ssoHref: String {
        "/auth/oidc/start" + (returnTo.map { "?returnTo=" + formEncode($0) } ?? "")
    }

    var body: some HTML {
        PageLayout(title: "Anmelden", nav: nil) {
            section(.class("login")) {
                h1 { "WatchSwifty" }
                if let error {
                    p(.class("error"), .custom(name: "role", value: "alert")) { error }
                }
                if let ssoName {
                    a(.href(ssoHref), .class("button primary sso")) { "Mit \(ssoName) anmelden" }
                }
                if passwordLogin {
                form(.method(.post), .action("/login")) {
                    if let returnTo { input(.type(.hidden), .name("returnTo"), .value(returnTo)) }
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
                    button(.type(.submit), .class(ssoName == nil ? "primary" : "")) { "Anmelden" }
                }
                if forgotPasswordLink {
                    p { a(.href("/forgot-password")) { "Passwort vergessen?" } }
                }
                }
            }
        }
    }
}
