import Elementary
import ElementaryHTMX2
import Vapor

extension HTMLAttributeValue.HTMX.ModifiedSwapTarget {
    /// outerHTML with a 500 ms settle phase; together with the `.htmx-added` CSS rule the freshly
    /// swapped controls ignore the second click of a double-click.
    static var outerHTMLGuarded: Self { .init(rawValue: "outerHTML settle:500ms") }
}

extension Request {
    /// True when the request was issued by htmx (`HX-Request: true`).
    var isHTMX: Bool { headers.first(name: "HX-Request") == "true" }
}
