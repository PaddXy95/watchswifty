import Elementary

/// Confirmation before an app gets a device token for the signed-in account.
struct AuthorizePage: HTML {
    let params: APIAuthorizeController.Params

    var body: some HTML {
        PageLayout(title: "App verbinden", nav: nil) {
            section(.class("login")) {
                h1 { "App verbinden" }
                p { "Die WatchSwifty-App auf „\(params.device_name)“ mit deinem Konto verbinden?" }
                p(.class("muted")) { "Das Gerät bleibt 90 Tage angemeldet. Unter Konto → Geräte kannst du es jederzeit abmelden." }
                form(.method(.post), .action("/api/auth/authorize")) {
                    input(.type(.hidden), .name("redirect_uri"), .value(params.redirect_uri))
                    input(.type(.hidden), .name("state"), .value(params.state))
                    input(.type(.hidden), .name("code_challenge"), .value(params.code_challenge))
                    input(.type(.hidden), .name("code_challenge_method"), .value(params.code_challenge_method))
                    input(.type(.hidden), .name("device_name"), .value(params.device_name))
                    button(.type(.submit), .name("decision"), .custom(name: "value", value: "connect"), .class("primary")) { "Verbinden" }
                    " "
                    button(.type(.submit), .name("decision"), .custom(name: "value", value: "cancel")) { "Abbrechen" }
                }
            }
        }
    }
}
