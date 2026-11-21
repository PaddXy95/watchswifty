import Elementary
import ElementaryHTMX2

/// Tabs at the top of pages that share one menu entry (Bibliothek: Titel/Verlauf, Konto: Einstellungen/Import,
/// Admin: System/Benutzer); the pages keep their own addresses.
struct SectionTabs: HTML {
    enum Tab: String { case titles, history, settings, importing, system, users }

    let tabs: [(Tab, String, String)]
    let active: Tab

    static func library(_ active: Tab) -> SectionTabs {
        SectionTabs(tabs: [(.titles, "Titel", "/library"), (.history, "Verlauf", "/history")], active: active)
    }

    static func account(_ active: Tab) -> SectionTabs {
        SectionTabs(tabs: [(.settings, "Einstellungen", "/account"), (.importing, "Import", "/import")], active: active)
    }

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
