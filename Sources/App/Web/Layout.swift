import Elementary
import ElementaryHTMX2

enum NavItem: Sendable, Equatable {
    case continueWatching, history, library, stats, search, importing, account, admin, system
}

struct NavContext: Sendable {
    let username: String
    let isAdmin: Bool
    let active: NavItem
    /// Newer release found by the update check (only set for admins).
    var updateVersion: String? = nil
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

    var title: String { "\(pageTitle) · WatchSwifty" }
    var lang: String { "de" }
    /// The login page (no navigation) is laid out centered.
    var bodyAttributes: [HTMLAttribute<HTMLTag.body>] {
        // Every htmx request (incl. boosted links) shows the loading bar.
        (nav == nil ? [.class("auth")] : []) + [.custom(name: "hx-indicator", value: "#page-loader")]
    }

    var head: some HTML {
        meta(.name(.viewport), .content("width=device-width, initial-scale=1"))
        // Error responses are swapped too: they carry German messages (usually retargeted to #flash).
        meta(.name("htmx-config"), .content(#"{"responseHandling":[{"code":"204","swap":false},{"code":"[23]..","swap":true},{"code":"[45]..","swap":true,"error":true}]}"#))
        link(.rel(.stylesheet), .href("/css/app.css"))
        script(.src("/js/htmx.min.js")) {}
    }

    var body: some HTML {
        div(.id("page-loader"), .class("page-loader htmx-indicator"), .custom(name: "aria-hidden", value: "true")) {}
        if let nav {
            SiteNav(context: nav)
        }
        main(.class("page")) {
            div(.id("flash"), .custom(name: "aria-live", value: "polite")) {}
            content
        }
        SiteFooter(updateVersion: nav?.updateVersion)
    }
}

struct SiteNav: HTML {
    let context: NavContext

    private var items: [(NavItem, String, String)] {
        var items: [(NavItem, String, String)] = [
            (.continueWatching, "Weiterschauen", "/"),
            (.history, "Verlauf", "/history"),
            (.library, "Bibliothek", "/library"),
            (.stats, "Statistik", "/stats"),
            (.search, "Suche", "/search"),
            (.importing, "Import", "/import"),
            (.account, "Konto", "/account"),
        ]
        if context.isAdmin {
            items.append((.admin, "Benutzer", "/admin/users"))
            items.append((.system, "System", "/admin/system"))
        }
        return items
    }

    var body: some HTML {
        header(.class("site-header")) {
            a(.class("brand"), .href("/"), .hx.boost(true)) { "WatchSwifty" }
            // Burger menu on phones: a CSS-only checkbox toggle (no JavaScript).
            input(.type(.checkbox), .id("nav-toggle"), .class("nav-toggle"), .custom(name: "aria-label", value: "Menü öffnen"))
            label(.class("nav-toggle-label"), .for("nav-toggle"), .custom(name: "aria-label", value: "Menü")) { "☰" }
            // Boosted: menu clicks load via htmx, so the loading bar shows.
            nav(.class("site-nav"), .hx.boost(true)) {
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
