import Elementary
import ElementaryHTMX2

/// The pages that can be active in the navigation; `SiteNav` highlights the menu entry of the current one.
enum NavItem: Sendable, Equatable {
    case continueWatching, history, library, watchLater, stats, search, importing, account, admin, system

    /// The menu entry a page belongs to: Verlauf is a tab of Bibliothek, Import of Konto, System and Benutzer of Admin.
    var menuEntry: NavItem {
        switch self {
        case .history: .library
        case .importing: .account
        case .system: .admin
        default: self
        }
    }
}

/// What the page shell needs to know about the signed-in user and the current page (built per request by `req.nav(_:)`).
struct NavContext: Sendable {
    /// Shown next to „Abmelden“ (log out).
    let username: String
    /// Adds the „Admin“ menu entry.
    let isAdmin: Bool
    /// The page being rendered; its `menuEntry` is highlighted.
    let active: NavItem
    /// Newer release found by the update check (only set for admins).
    var updateVersion: String? = nil
}

/// The HTML document shell of every web page: head, loading bar, optional navigation, `main` and footer.
///
/// `main` starts with the empty `#flash` region (`aria-live="polite"`) into which error and flash messages are swapped.
/// Every htmx request shows the `#page-loader` bar. Without navigation (sign-in and other pages for anonymous visitors,
/// error pages) the body gets the class `auth` (centered layout) and the footer shows no version.
struct PageLayout<Content: HTML>: HTMLDocument {
    /// Page-specific part of the `<title>`; „ · WatchSwifty“ is appended.
    let pageTitle: String
    /// Navigation context; nil renders the page without header and menu.
    let nav: NavContext?
    /// The page content, placed in `main` below `#flash`.
    let content: Content

    /// Creates the shell around a page's content.
    /// - Parameters:
    ///   - title: Page-specific part of the document title.
    ///   - nav: Navigation context, or nil for a page without navigation.
    ///   - content: The page content.
    init(title: String, nav: NavContext?, @ContentBuilder content: () -> Content) {
        self.pageTitle = title
        self.nav = nav
        self.content = content()
    }

    /// Document title: the page title plus „ · WatchSwifty“.
    var title: String { "\(pageTitle) · WatchSwifty" }
    /// The UI is German.
    var lang: String { "de" }
    /// The login page (no navigation) is laid out centered.
    var bodyAttributes: [HTMLAttribute<HTMLTag.body>] {
        // Every htmx request (incl. boosted links) shows the loading bar.
        (nav == nil ? [.class("auth")] : []) + [.custom(name: "hx-indicator", value: "#page-loader")]
    }

    /// Viewport, htmx config (error responses are swapped too, a 204 is not), theme color, app icons, the web manifest, and
    /// the stylesheet and htmx script with their content fingerprints (`AssetVersion`).
    var head: some HTML {
        meta(.name(.viewport), .content("width=device-width, initial-scale=1"))
        // Error responses are swapped too: they carry German messages (usually retargeted to #flash).
        meta(.name("htmx-config"), .content(#"{"responseHandling":[{"code":"204","swap":false},{"code":"[23]..","swap":true},{"code":"[45]..","swap":true,"error":true}]}"#))
        meta(.name("theme-color"), .content("#0f1218"))
        // App icon: "WS" with a swift taking off (the 16 px favicon drops the bird).
        link(.rel(.icon), .href("/favicon.ico"), .custom(name: "sizes", value: "32x32"))
        link(.rel(.icon), .href("/favicon.svg"), .custom(name: "type", value: "image/svg+xml"))
        link(.rel("apple-touch-icon"), .href("/apple-touch-icon.png"))
        link(.rel("manifest"), .href("/manifest.json"))
        link(.rel(.stylesheet), .href(AssetVersion.url("/css/app.css", AssetVersion.css)))
        script(.src(AssetVersion.url("/js/htmx.min.js", AssetVersion.htmx))) {}
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
        SiteFooter(updateVersion: nav?.updateVersion, showVersion: nav != nil)
    }
}

/// The site header: brand link, a CSS-only burger toggle for phones, the main menu and the logout form.
///
/// Brand and menu links are boosted (`hx-boost`), so navigating shows the loading bar; the entry of the current page
/// gets `class="active"` and `aria-current="page"`.
struct SiteNav: HTML {
    /// User and current page.
    let context: NavContext

    /// Menu entries as (item, German label, path); „Admin“ (linking to `/admin/system`) only for admins.
    private var items: [(NavItem, String, String)] {
        var items: [(NavItem, String, String)] = [
            (.continueWatching, "Weiterschauen", "/"),
            (.watchLater, "Später ansehen", "/watch-later"),
            (.library, "Bibliothek", "/library"),
            (.stats, "Statistik", "/stats"),
            (.search, "Suche", "/search"),
            (.account, "Konto", "/account"),
        ]
        if context.isAdmin {
            items.append((.admin, "Admin", "/admin/system"))
        }
        return items
    }

    var body: some HTML {
        header(.class("site-header")) {
            a(.class("brand"), .href("/"), .hx.boost(true)) {
                img(.class("brand-icon"), .src("/favicon.svg"), .alt(""), .width(32), .height(32))
                "WatchSwifty"
            }
            // Burger menu on phones: a CSS-only checkbox toggle (no JavaScript).
            input(.type(.checkbox), .id("nav-toggle"), .class("nav-toggle"), .custom(name: "aria-label", value: "Menü öffnen"))
            label(.class("nav-toggle-label"), .for("nav-toggle"), .custom(name: "aria-label", value: "Menü")) { "☰" }
            // Boosted: menu clicks load via htmx, so the loading bar shows.
            nav(.class("site-nav"), .hx.boost(true)) {
                for (item, label, href) in items {
                    a(.href(href)) { label }
                        .attributes(.class("active"), .custom(name: "aria-current", value: "page"), when: item == context.active.menuEntry)
                }
            }
            form(.class("logout"), .method(.post), .action("/logout")) {
                span(.class("username")) { context.username }
                button(.type(.submit), .class("link-button")) { "Abmelden" }
            }
        }
    }
}
