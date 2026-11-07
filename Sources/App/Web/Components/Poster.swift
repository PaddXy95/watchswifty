import Elementary

/// TMDB poster (hot-linked) or a neutral placeholder with initials.
struct Poster: HTML {
    let path: String?
    let alt: String

    init(path: String?, alt: String) {
        self.path = path
        self.alt = alt
    }

    private var initials: String {
        String(alt.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }

    var body: some HTML {
        if let path {
            img(.class("poster"), .src("https://image.tmdb.org/t/p/w342\(path)"), .alt(alt), .custom(name: "loading", value: "lazy"))
        } else {
            div(.class("poster poster-placeholder"), .custom(name: "aria-hidden", value: "true")) { initials }
        }
    }
}
