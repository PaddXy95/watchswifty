import Elementary

/// A foldable page block (System, Konto): the title is the summary, the content follows. Pages open the block of the
/// last action (or `?open=`) so its message and form stay in view.
struct FoldableBlock<Content: HTML>: HTML {
    /// Element id of the `<details>` element.
    let id: String
    /// Heading shown in the `<summary>`.
    let title: String
    /// Renders the block expanded.
    let open: Bool
    /// The block's content, shown below the summary.
    let content: Content

    /// Creates a foldable block.
    /// - Parameters:
    ///   - id: Element id of the `<details>` element.
    ///   - title: Heading shown in the summary.
    ///   - open: Whether the block starts expanded.
    ///   - content: Builder for the block's content.
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
