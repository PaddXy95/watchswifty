import Elementary
import ElementaryHTMX2

/// Tabs at the top of pages that share one menu entry (Bibliothek: Titel/Verlauf, Konto: Einstellungen/Import,
/// Admin: System/Benutzer); the pages keep their own addresses.
///
/// The `<nav>` is htmx-boosted; the active tab gets the `active` class and `aria-current="page"`.
struct SectionTabs: HTML {
    /// Identifies a tab, so the current page's tab can be marked active.
    enum Tab: String { case titles, history, settings, importing, system, users }

    /// The tabs in order, as (tab, German label, link target).
    let tabs: [(Tab, String, String)]
    /// The tab of the current page.
    let active: Tab

    /// Tabs of the library: „Titel“ (titles, `/library`) and „Verlauf“ (history, `/history`).
    /// - Parameter active: The tab of the current page.
    /// - Returns: The tab bar.
    static func library(_ active: Tab) -> SectionTabs {
        SectionTabs(tabs: [(.titles, "Titel", "/library"), (.history, "Verlauf", "/history")], active: active)
    }

    /// Tabs of the account: „Einstellungen“ (settings, `/account`) and „Import“ (`/import`).
    /// - Parameter active: The tab of the current page.
    /// - Returns: The tab bar.
    static func account(_ active: Tab) -> SectionTabs {
        SectionTabs(tabs: [(.settings, "Einstellungen", "/account"), (.importing, "Import", "/import")], active: active)
    }

    /// Tabs of the admin area: „System“ (`/admin/system`) and „Benutzer“ (users, `/admin/users`).
    /// - Parameter active: The tab of the current page.
    /// - Returns: The tab bar.
    static func admin(_ active: Tab) -> SectionTabs {
        SectionTabs(tabs: [(.system, "System", "/admin/system"), (.users, "Benutzer", "/admin/users")], active: active)
    }

    var body: some HTML {
        nav(.class("section-tabs"), .custom(name: "aria-label", value: "Bereiche"), .hx.boost(true)) {
            for (tab, label, href) in tabs {
                a(.href(href)) { label }
                    .attributes(.class("active"), .custom(name: "aria-current", value: "page"), when: tab == active)
            }
        }
    }
}
