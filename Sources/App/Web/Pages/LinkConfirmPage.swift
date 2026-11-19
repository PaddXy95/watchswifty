import Elementary

/// Confirmation before a link token binds a provider account to a WatchSwifty account: names both sides, so nobody
/// links their provider account to someone else's account by accident (security audit F17).
struct LinkConfirmPage: HTML {
    let ssoName: String
    let username: String
    let identity: OIDCIdentity

    /// How the provider account is shown: name and e-mail (or the provider's user name), else its ID.
    var providerAccount: String {
        let contact = identity.email ?? identity.preferredUsername
        switch (identity.name, contact) {
        case let (name?, contact?): return "\(name) (\(contact))"
        case let (name?, nil): return name
        case let (nil, contact?): return contact
        case (nil, nil): return identity.subject
        }
    }

    var body: some HTML {
        PageLayout(title: "SSO verknüpfen", nav: nil) {
            section(.class("login")) {
                h1 { "WatchSwifty" }
                p { "Dein \(ssoName)-Konto „\(providerAccount)“ wird mit dem WatchSwifty-Konto „\(username)“ verknüpft." }
                p(.class("notice")) {
                    "Danach meldest du dich über \(ssoName) als „\(username)“ an. Ist das nicht dein Konto, brich hier ab."
                }
                form(.method(.post), .action("/auth/oidc/link")) {
                    button(.type(.submit), .class("primary")) { "Verknüpfen" }
                }
                p { a(.href("/auth/oidc/cancel")) { "Abbrechen" } }
            }
        }
    }
}
