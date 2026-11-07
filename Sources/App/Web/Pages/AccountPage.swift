import Elementary

struct AccountPage: HTML {
    let nav: NavContext
    let tokenSuffix: String?
    let error: String?
    let notice: String?

    var body: some HTML {
        PageLayout(title: "Konto", nav: nav) {
            h1 { "Konto" }
            p(.class("muted")) { "Angemeldet als \(nav.username)" }
            Messages(error: error, notice: notice)

            h2 { "TMDB-Token" }
            p(.class("muted")) {
                "Für Suche, Poster und den Netflix-Import brauchst du einen eigenen kostenlosen Read Access Token von "
                a(.href("https://www.themoviedb.org/settings/api"), .target(.blank), .custom(name: "rel", value: "noopener noreferrer")) { "themoviedb.org" }
                "."
            }
            if let tokenSuffix {
                p { "Hinterlegt: \(tokenSuffix)" }
            } else {
                p { "Kein TMDB-Token hinterlegt." }
            }
            form(.method(.post), .action("/account/tmdb-token"), .class("inline-form")) {
                input(.type(.password), .name("token"), .required, .custom(name: "autocomplete", value: "off"),
                      .custom(name: "placeholder", value: "Read Access Token"), .custom(name: "aria-label", value: "TMDB-Token"))
                button(.type(.submit), .class("primary")) { tokenSuffix == nil ? "Speichern" : "Ersetzen" }
            }
            if tokenSuffix != nil {
                form(.method(.post), .action("/account/tmdb-token/remove"), .class("inline-form")) {
                    button(.type(.submit)) { "Entfernen" }
                }
            }

            h2 { "Passwort ändern" }
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
