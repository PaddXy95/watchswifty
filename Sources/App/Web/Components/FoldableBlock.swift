import Elementary

/// A foldable page block (System, Konto): the title is the summary, the content follows. Pages open the block of the
/// last action (or `?open=`) so its message and form stay in view.
struct FoldableBlock<Content: HTML>: HTML {
    let id: String
    let title: String
    let open: Bool
    let content: Content

    init(id: String, title: String, open: Bool, @HTMLBuilder content: () -> Content) {
        self.id = id
        self.title = title
        self.open = open
        self.content = content()
    }

    var body: some HTML {
        details(.class("fold-block"), .id(id)) {
            summary { h2 { title } }
            content
        }
        .attributes(.custom(name: "open", value: ""), when: open)
    }
}
