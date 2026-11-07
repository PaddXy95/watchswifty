import Elementary

/// Placeholder home page; replaced by the continue-watching shelf in Task 10.
struct ContinuePlaceholderPage: HTML {
    let nav: NavContext

    var body: some HTML {
        PageLayout(title: "Weiterschauen", nav: nav) {
            h1 { "Weiterschauen" }
            p(.class("muted")) { "Noch nichts zum Weiterschauen." }
        }
    }
}
