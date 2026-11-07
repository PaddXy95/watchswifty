import Elementary
import ElementaryHTMX2

struct RatingControl: HTML {
    let kind: TitleKind
    let tmdbID: Int
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
