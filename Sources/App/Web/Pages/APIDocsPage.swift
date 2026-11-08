import Elementary

/// `/api`: Swagger UI for the App API (assets vendored under `Public/api-docs`, no CDN).
struct APIDocsPage: HTMLDocument {
    var title: String { "WatchSwifty API" }
    var lang: String { "de" }

    var head: some HTML {
        meta(.name(.viewport), .content("width=device-width, initial-scale=1"))
        link(.rel(.stylesheet), .href("/api-docs/swagger-ui.css"))
    }

    var body: some HTML {
        div(.id("swagger-ui")) {}
        script(.src("/api-docs/swagger-ui-bundle.js")) {}
        script(.src("/api-docs/init.js")) {}
    }
}
