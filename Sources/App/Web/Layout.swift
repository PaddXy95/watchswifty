import Elementary

enum NavItem: Sendable, Equatable {
    case continueWatching, history, library, search, importing, account, admin
}

struct NavContext: Sendable {
    let username: String
    let isAdmin: Bool
    let active: NavItem
}

struct PageLayout<Content: HTML>: HTMLDocument {
    let pageTitle: String
    let nav: NavContext?
    let content: Content

    init(title: String, nav: NavContext?, @ContentBuilder content: () -> Content) {
        self.pageTitle = title
        self.nav = nav
        self.content = content()
    }

    var title: String { "\(pageTitle) · watchswifty" }
    var lang: String { "de" }

    var head: some HTML {
        meta(.name(.viewport), .content("width=device-width, initial-scale=1"))
        link(.rel(.stylesheet), .href("/css/app.css"))
        script(.src("/js/htmx.min.js")) {}
    }

    var body: some HTML {
        if let nav {
            SiteNav(context: nav)
        }
        main(.class("page")) {
            content
        }
    }
}

struct SiteNav: HTML {
    let context: NavContext

    private var items: [(NavItem, String, String)] {
        var items: [(NavItem, String, String)] = [
            (.continueWatching, "Weiterschauen", "/"),
            (.history, "Verlauf", "/history"),
            (.library, "Bibliothek", "/library"),
            (.search, "Suche", "/search"),
            (.importing, "Import", "/import"),
            (.account, "Konto", "/account"),
        ]
        if context.isAdmin { items.append((.admin, "Benutzer", "/admin/users")) }
        return items
    }

    var body: some HTML {
        header(.class("site-header")) {
            a(.class("brand"), .href("/")) { "watchswifty" }
            nav(.class("site-nav")) {
                for (item, label, href) in items {
                    a(.href(href)) { label }
                        .attributes(.class("active"), .custom(name: "aria-current", value: "page"), when: item == context.active)
                }
            }
            form(.class("logout"), .method(.post), .action("/logout")) {
                span(.class("username")) { context.username }
                button(.type(.submit), .class("link-button")) { "Abmelden" }
            }
        }
    }
}
