import Elementary

/// Link to a page of the documentation in the repository (`docs/`), opened in a new tab.
struct DocsLink: HTML {
    static let baseURL = "https://github.com/PaddXy95/watchswifty/blob/main/docs/"

    /// File name in `docs/`, optionally with an anchor, e.g. `operations.md#updating`.
    let page: String
    let label: String

    var body: some HTML {
        a(.href(Self.baseURL + page), .target(.blank), .custom(name: "rel", value: "noopener noreferrer")) { label }
    }
}
