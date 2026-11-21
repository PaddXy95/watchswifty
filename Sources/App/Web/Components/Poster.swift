import Elementary

/// TMDB poster (hot-linked) or a neutral placeholder with initials. Loads lazily, decodes off the main thread and
/// picks the smallest TMDB size for the displayed width (plus a 2× source for sharp displays).
struct Poster: HTML {
    /// TMDB poster path (e.g. `/abc.jpg`), or `nil` for the placeholder.
    let path: String?
    /// Alternative text; also the source of the placeholder's initials.
    let alt: String
    /// CSS width the poster is shown at (largest breakpoint).
    let displayWidth: Int

    /// Poster widths TMDB serves (`/t/p/w{n}`).
    static let tmdbWidths = [92, 154, 185, 342, 500, 780]

    /// Creates a poster.
    /// - Parameters:
    ///   - path: TMDB poster path, or `nil` to render the initials placeholder.
    ///   - alt: Alternative text, usually the title name.
    ///   - displayWidth: CSS width in pixels at the largest breakpoint; defaults to 92.
    init(path: String?, alt: String, displayWidth: Int = 92) {
        self.path = path
        self.alt = alt
        self.displayWidth = displayWidth
    }

    /// Up to two uppercase initials from the first two words of `alt`, shown by the placeholder.
    private var initials: String {
        String(alt.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }

    /// The smallest TMDB poster width of at least `pixels`, or the largest one TMDB serves.
    /// - Parameter pixels: Required width in pixels.
    /// - Returns: One of ``tmdbWidths``.
    static func tmdbWidth(atLeast pixels: Int) -> Int {
        tmdbWidths.first { $0 >= pixels } ?? tmdbWidths.last!
    }

    var body: some HTML {
        if let path {
            let base = "https://image.tmdb.org/t/p/"
            let small = "\(base)w\(Self.tmdbWidth(atLeast: displayWidth))\(path)"
            let sharp = "\(base)w\(Self.tmdbWidth(atLeast: displayWidth * 2))\(path)"
            img(.class("poster"), .src(small), .custom(name: "srcset", value: "\(small) 1x, \(sharp) 2x"), .alt(alt),
                .custom(name: "width", value: "\(displayWidth)"), .custom(name: "height", value: "\(displayWidth * 3 / 2)"),
                .custom(name: "loading", value: "lazy"), .custom(name: "decoding", value: "async"))
        } else {
            div(.class("poster poster-placeholder"), .custom(name: "aria-hidden", value: "true")) { initials }
        }
    }
}
