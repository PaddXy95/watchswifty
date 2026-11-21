import Elementary

/// „Neues Konto anlegen“ after the first sign-in through the provider (spec „Neues Konto anlegen“).
struct NewAccountPage: HTML {
    /// Display name of the provider.
    let ssoName: String
    /// Password login is on: the hint suggests signing in with the password and linking under „Konto“.
    let passwordLogin: Bool
    /// Prefilled username (the provider's suggestion or the last input).
    let username: String
    /// Set when the provider's suggestion is already taken.
    var takenSuggestion: String? = nil
    /// Validation error of the last submit.
    var error: String? = nil

    var body: some HTML {
        PageLayout(title: "Neues Konto", nav: nil) {
            section(.class("login")) {
                h1 { "WatchSwifty" }
                Messages(error: error, notice: nil)
                p { "Mit \(ssoName) ist noch kein WatchSwifty-Konto verknüpft." }
                p(.class("notice")) {
                    if passwordLogin {
                        "Hast du schon ein Konto? Dann hier kein neues anlegen: mit Passwort anmelden und unter „Konto“ mit \(ssoName) verknüpfen. "
                    } else {
                        "Hast du schon ein Konto? Dann hier kein neues anlegen, sondern den Admin um einen Verknüpfungslink bitten. "
                    }
                    "Eingeladen? Den Link aus der Einladungs-Mail benutzen."
                }
                if let takenSuggestion {
                    p(.class("muted")) { "Der Name „\(takenSuggestion)“ ist schon vergeben – bitte einen anderen wählen." }
                }
                form(.method(.post), .action("/auth/oidc/new-account")) {
                    label {
                        "Benutzername"
                        input(.type(.text), .name("username"), .value(username), .required, .autofocus,
                              .custom(name: "autocomplete", value: "username"))
                    }
                    p(.class("muted")) { AccountValidation.usernameMessage }
                    button(.type(.submit), .class("primary")) { "Konto anlegen" }
                }
                p { a(.href("/auth/oidc/cancel")) { "Abbrechen" } }
            }
        }
    }
}
