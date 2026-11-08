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

    @Test func everyPageLinksTheAppIcon() {
        for nav in [NavContext(username: "pat", isAdmin: false, active: .history), nil] {
            let html = PageLayout(title: "X", nav: nav) { p { "x" } }.render()
            #expect(html.contains(#"<link rel="icon" href="/favicon.ico" sizes="32x32">"#))
            #expect(html.contains(#"<link rel="icon" href="/favicon.svg" type="image/svg+xml">"#))
            #expect(html.contains(#"<link rel="apple-touch-icon" href="/apple-touch-icon.png">"#))
            #expect(html.contains(#"<link rel="manifest" href="/manifest.json">"#))
            #expect(html.contains(##"<meta name="theme-color" content="#0f1218">"##))
        }
    }

    @Test func brandShowsTheIcon() {
        let html = PageLayout(title: "X", nav: .init(username: "pat", isAdmin: false, active: .history)) { p { "x" } }.render()
        #expect(html.contains(#"<img class="brand-icon" src="/favicon.svg" alt="" width="28" height="28">WatchSwifty</a>"#))
    }

    @Test func iconFilesServed() async throws {
        try await withTestApp { app in
            for path in ["/favicon.svg", "/favicon.ico", "/apple-touch-icon.png", "/img/icon-192.png", "/img/icon-512.png"] {
                try await app.testing().test(.GET, path) { res async in
                    #expect(res.status == .ok, "\(path)")
                }
            }
            try await app.testing().test(.GET, "/manifest.json") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains(#""name": "WatchSwifty""#))
                #expect(res.body.string.contains(#""src": "/img/icon-512.png""#))
            }
        }
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
                                remaining: 3, lastWatchedOn: "2026-11-01", lastService: .netflix, watchService: .netflix)
        let html = ContinueCardView(card: card).render()
        #expect(html.contains(#"hx-boost="true""#))
        let link = try? #require(html.range(of: #"<a class="button""#).map { String(html[$0.lowerBound...].prefix(260)) })
        #expect(link?.contains(#"target="_blank""#) == true)
        #expect(link?.contains(#"rel="noopener noreferrer""#) == true)
        #expect(link?.contains(#"hx-boost="false""#) == true)
    }
}

@Suite("ExternalLinks")
struct ExternalLinksTests {
    func title(_ kind: TitleKind, tmdbID: Int, name: String, imdb: String?) -> Title {
        let t = Title(tmdbID: tmdbID, kind: kind, name: name)
        t.imdbID = imdb
        return t
    }

    @Test func externalLinksSeries() {
        let html = ExternalLinks(title: title(.tv, tmdbID: 1399, name: "Game of Thrones", imdb: "tt0944947")).render()
        #expect(html.contains(#"href="https://www.themoviedb.org/tv/1399""#))
        #expect(html.contains(#"href="https://www.imdb.com/title/tt0944947/""#))
        #expect(html.contains(#"href="https://www.rottentomatoes.com/search?search=Game%20of%20Thrones""#))
        #expect(html.contains(#"href="https://seriesgraph.com/show/1399""#))
        #expect(html.contains(#"target="_blank""#))
    }

    @Test func externalLinksMovieHasNoSeriesGraph() {
        let html = ExternalLinks(title: title(.movie, tmdbID: 603, name: "Matrix", imdb: "tt0133093")).render()
        #expect(html.contains(#"href="https://www.themoviedb.org/movie/603""#))
        #expect(!html.contains("seriesgraph"))
    }

    @Test func imdbFallbackSearch() {
        let html = ExternalLinks(title: title(.tv, tmdbID: 5, name: "Dark", imdb: "")).render()
        #expect(html.contains(#"href="https://www.imdb.com/find/?q=Dark""#))
    }

    @Test func detailPageShowsLinks() async throws {
        try await withTestApp(tmdb: TitlePagesTests.fake()) { app in
            try await createUser(app, "pat")
            let headers = try await login(app, "pat")
            try await app.testing().test(.GET, "/tv/1399", headers: headers) { res async in
                #expect(res.body.string.contains("seriesgraph.com/show/1399"))
                #expect(res.body.string.contains("Rotten Tomatoes"))
            }
        }
    }
}

@Suite("MobileMenuLayout")
struct MobileMenuLayoutTests {
    @Test func openMenuTakesFullWidthBelowHeader() throws {
        let css = try String(contentsOfFile: "Public/css/app.css", encoding: .utf8)
        let mobile = try #require(css.range(of: "@media (max-width: 700px)")).upperBound
        let block = String(css[mobile...])
        // The desktop rule gives .site-nav `flex: 1`, which would keep it beside the logo.
        #expect(block.contains(".site-nav, .logout { display: none; flex: 0 0 100%;"))
    }
}

@Suite("TileLoading")
struct TileLoadingTests {
    @Test func tilesIndicateLoading() {
        let search = SearchResults(results: [SearchResultModel(
            result: TMDBSearchResult(id: 1, kind: .tv, name: "Dark", originalName: nil, year: 2017, posterPath: nil), status: nil, rating: nil)],
            hasToken: true).render()
        #expect(search.contains(##"hx-indicator="closest .search-result, #page-loader""##))
        let title = Title(tmdbID: 1, kind: .tv, name: "Dark")
        let library = LibraryPage(navContext: .init(username: "pat", isAdmin: false, active: .library),
                                  items: [LibraryItem(title: title, rating: nil, hidden: false)], filter: "all", sort: "recent").render()
        #expect(library.contains(##"hx-indicator="closest .library-item, #page-loader""##))
        let card = ContinueCard(titleID: UUID(), tmdbID: 1, name: "Dark", posterPath: nil, rating: nil,
                                next: EpisodeInfo(id: UUID(), season: 1, number: 2, name: "Lügen", airDate: "2017-12-01"),
                                remaining: 1, lastWatchedOn: nil, lastService: nil, watchService: nil)
        #expect(ContinueCardView(card: card).render().contains(##"hx-indicator="closest .card, #page-loader""##))
    }

    @Test func tileSpinnerCSS() throws {
        let css = try String(contentsOfFile: "Public/css/app.css", encoding: .utf8)
        #expect(css.contains(".search-result.htmx-request::after"))
        #expect(css.contains("@keyframes tile-spin"))
    }
}

@Suite("ReviewFixesUI")
struct ReviewFixesUITests {
    @Test func errorPageStacksVertically() throws {
        let css = try String(contentsOfFile: "Public/css/app.css", encoding: .utf8)
        #expect(css.contains(".auth .page { display: flex; flex-direction: column; align-items: center; justify-content: center; }"))
    }

    @Test func loginHeadingUsesBrand() {
        #expect(LoginPage(error: nil, username: "").render().contains("<h1>WatchSwifty</h1>"))
    }

    @Test func composeVolumeHasFixedName() throws {
        let compose = try String(contentsOfFile: "docker-compose.yml", encoding: .utf8)
        #expect(compose.contains("name: watchswifty-data"))
    }

    @Test func commentTextSurvivesSectionSwaps() {
        let html = CommentBox(id: "season-comment-2", action: "/x", caption: "Kommentar zur Staffel", comment: nil).render()
        #expect(html.contains(#"id="season-comment-2-text""#))
        #expect(html.contains(#"hx-preserve="true""#))
    }
}

@Suite("MenuBoost")
struct MenuBoostTests {
    @Test func menuLinksAreBoosted() {
        let html = SiteNav(context: .init(username: "pat", isAdmin: true, active: .history)).render()
        #expect(html.contains(#"<a class="brand" href="/" hx-boost="true""#))
        #expect(html.contains(#"<nav class="site-nav" hx-boost="true""#))
        #expect(!html.contains(#"<form class="logout" method="post" action="/logout" hx-boost"#))
    }
}
