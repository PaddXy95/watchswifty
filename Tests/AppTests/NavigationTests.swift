@testable import App
import Elementary
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("Navigation")
struct NavigationTests {
    func links(_ html: String) -> [String] {
        let nav = html.components(separatedBy: #"<nav class="site-nav""#)[1].components(separatedBy: "</nav>")[0]
        return nav.components(separatedBy: "</a>").dropLast().compactMap { $0.components(separatedBy: ">").last }
    }

    @Test func menuHasSevenEntriesInOrder() {
        let admin = SiteNav(context: .init(username: "pat", isAdmin: true, active: .library)).render()
        #expect(links(admin) == ["Weiterschauen", "Später ansehen", "Bibliothek", "Statistik", "Suche", "Konto", "Admin"])
        #expect(admin.contains(#"href="/admin/system""#))
        #expect(!admin.contains(#"href="/history""#) && !admin.contains(#"href="/import""#) && !admin.contains(#"href="/admin/users""#))
        let user = SiteNav(context: .init(username: "pat", isAdmin: false, active: .library)).render()
        #expect(links(user) == ["Weiterschauen", "Später ansehen", "Bibliothek", "Statistik", "Suche", "Konto"])
    }

    @Test(arguments: [(NavItem.history, "Bibliothek"), (.importing, "Konto"), (.system, "Admin"), (.admin, "Admin"), (.library, "Bibliothek")])
    func subpagesHighlightTheirMenuEntry(_ active: NavItem, _ label: String) {
        let html = SiteNav(context: .init(username: "pat", isAdmin: true, active: active)).render()
        #expect(html.contains(#"class="active" aria-current="page">\#(label)</a>"#))
    }

    func page(_ app: Application, _ path: String, _ headers: HTTPHeaders) async throws -> String {
        var body = ""
        try await app.testing().test(.GET, path, headers: headers) { res async in
            #expect(res.status == .ok)
            body = res.body.string
        }
        return body
    }

    @Test func pagesShowTheirTabs() async throws {
        try await withTestApp { app in
            _ = try await createUser(app, "pat", isAdmin: true)
            let headers = try await login(app, "pat")
            let cases: [(String, [String], String)] = [
                ("/library", ["Titel", "Verlauf"], "Titel"),
                ("/history", ["Titel", "Verlauf"], "Verlauf"),
                ("/account", ["Einstellungen", "Import"], "Einstellungen"),
                ("/import", ["Einstellungen", "Import"], "Import"),
                ("/import/standard", ["Einstellungen", "Import"], "Import"),
                ("/admin/system", ["System", "Benutzer"], "System"),
                ("/admin/users", ["System", "Benutzer"], "Benutzer"),
            ]
            for (path, tabs, active) in cases {
                let body = try await page(app, path, headers)
                let bar = try #require(body.components(separatedBy: #"<nav class="section-tabs""#).dropFirst().first, "\(path)")
                    .components(separatedBy: "</nav>")[0]
                #expect(links(#"<nav class="site-nav""# + bar + "</nav>") == tabs, "\(path)")
                #expect(bar.contains(#"aria-current="page">\#(active)</a>"#), "\(path)")
            }
        }
    }

    @Test func hintsPointToAdminSystem() {
        #expect(UserAdminService.inviteNeedsMailMessage.contains("unter Admin → System"))
    }
}
