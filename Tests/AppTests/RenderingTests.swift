@testable import App
import Elementary
import Testing
import VaporTesting

@Suite("Rendering")
struct RenderingTests {
    @Test func layoutContainsAssetsAndNav() {
        let html = PageLayout(title: "Verlauf", nav: .init(username: "pat", isAdmin: false, active: .history)) {
            p { "x" }
        }.render()
        #expect(html.contains(#"<script src="/js/htmx.min.js""#))
        #expect(html.contains(#"href="/css/app.css""#))
        #expect(html.contains("Verlauf · watchswifty"))
        #expect(html.contains("Weiterschauen"))
        #expect(html.contains("Abmelden"))
        #expect(!html.contains("Benutzer"))
    }

    @Test func adminSeesUserNav() {
        let html = PageLayout(title: "X", nav: .init(username: "pat", isAdmin: true, active: .admin)) { p { "x" } }.render()
        #expect(html.contains("Benutzer"))
    }

    @Test func loginLayoutHasNoNav() {
        let html = PageLayout(title: "Anmelden", nav: nil) { p { "x" } }.render()
        #expect(!html.contains("Weiterschauen"))
        #expect(!html.contains("Abmelden"))
    }

    @Test func textIsEscaped() {
        #expect(p { "<b>&" }.render().contains("&lt;b&gt;&amp;"))
    }

    @Test func htmlResponseSetsContentType() async throws {
        try await withTestApp { app in
            let req = Request(application: app, on: app.eventLoopGroup.next())
            let res = try await HTMLResponse(p { "hi" }).encodeResponse(for: req)
            #expect(res.headers.first(name: .contentType) == "text/html; charset=utf-8")
            #expect(res.body.string == "<p>hi</p>")
        }
    }

    @Test func staticCSSServed() async throws {
        try await withTestApp { app in
            try await app.testing().test(.GET, "/css/app.css") { res async in
                #expect(res.status == .ok)
            }
        }
    }
}
