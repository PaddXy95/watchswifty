import Elementary
import ElementaryHTMX2

/// „Bewertung“ (rating) select on the series and movie page: 1 to 10, or „–“ for none.
///
/// The form (`#rating`) posts to `/<kind>/<id>/rating` on every change and replaces itself with the response, which
/// shows the saved rating as „★ n“.
struct RatingControl: HTML {
    /// Series or movie; selects the route prefix (`tv` / `movie`).
    let kind: TitleKind
    /// TMDB ID of the title.
    let tmdbID: Int
    /// The user's current rating (1–10), or `nil` if unrated.
    let rating: Int?

    var body: some HTML {
        form(.id("rating"), .class("rating-control"), .hx.post("/\(kind.rawValue)/\(tmdbID)/rating"),
             .hx.trigger(.event(.change)), .hx.swap(.outerHTML)) {
            label {
                "Bewertung "
                select(.name("rating")) {
                    option(.value("")) { "–" }.attributes(.selected, when: rating == nil)
                    for value in 1...10 {
                        option(.value("\(value)")) { "\(value)" }.attributes(.selected, when: rating == value)
                    }
                }
            }
            if let rating {
                span(.class("rating")) { " ★ \(rating)" }
            }
        }
    }
}
