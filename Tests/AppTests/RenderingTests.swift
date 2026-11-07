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
        #expect(html.contains("Verlauf · WatchSwifty"))
        #expect(html.contains(">WatchSwifty<"))
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

    @Test func footerOnEveryPage() {
        for nav in [NavContext(username: "pat", isAdmin: false, active: .history), nil] {
            let html = PageLayout(title: "X", nav: nav) { p { "x" } }.render()
            #expect(html.contains("Built with"))
            #expect(html.contains(#"href="https://www.swift.org""#))
            #expect(html.contains(#"href="https://vapor.codes""#))
            #expect(html.contains(#"href="https://github.com/PaddXy95/watchswifty""#))
            #expect(html.contains("❤️"))
        }
    }

    @Test func burgerMenuMarkup() {
        let html = PageLayout(title: "X", nav: .init(username: "pat", isAdmin: true, active: .history)) { p { "x" } }.render()
        #expect(html.contains(#"id="nav-toggle""#))
        #expect(html.contains(#"for="nav-toggle""#))
        #expect(html.contains(#"aria-label="Menü""#))
        #expect(html.contains("Benutzer"))
        #expect(html.contains("Abmelden"))
    }

    @Test func loginPageIsCentered() {
        let html = LoginPage(error: nil, username: "").render()
        #expect(html.contains(#"<body class="auth""#))
    }

    @Test func mobileCSSRules() throws {
        let css = try String(contentsOfFile: "Public/css/app.css", encoding: .utf8)
        #expect(css.contains("@media (max-width: 700px)"))
        #expect(css.contains(".nav-toggle:checked"))
        #expect(css.contains(".history-table"))
    }
}

@Suite("LoadingBar")
struct LoadingBarTests {
    @Test func loadingBarPresent() {
        let html = PageLayout(title: "X", nav: .init(username: "pat", isAdmin: false, active: .search)) { p { "x" } }.render()
        #expect(html.contains(#"id="page-loader""#))
        #expect(html.contains(##"hx-indicator="#page-loader""##))
    }

    @Test func searchResultsAndLibraryAreBoosted() {
        #expect(SearchResults(results: [], hasToken: true).render().contains(#"hx-boost="true""#))
        let library = LibraryPage(navContext: .init(username: "pat", isAdmin: false, active: .library), items: [], filter: "all", sort: "recent").render()
        #expect(library.contains(#"hx-boost="true""#))
    }

    @Test func netflixLinkOpensNewTab() {
        let card = ContinueCard(titleID: UUID(), tmdbID: 1, name: "The Mentalist", posterPath: nil, rating: nil,
                                next: EpisodeInfo(id: UUID(), season: 4, number: 15, name: "X", airDate: "2020-01-01"),
                                remaining: 3, lastWatchedOn: "2026-11-01", lastService: .netflix, hasNetflixData: true)
        let html = ContinueCardView(card: card).render()
        #expect(html.contains(#"hx-boost="true""#))
        let link = try? #require(html.range(of: #"<a class="button""#).map { String(html[$0.lowerBound...].prefix(260)) })
        #expect(link?.contains(#"target="_blank""#) == true)
        #expect(link?.contains(#"rel="noopener noreferrer""#) == true)
        #expect(link?.contains(#"hx-boost="false""#) == true)
    }
}
