import Elementary

/// Error / notice lines shown above forms.
struct Messages: HTML {
    /// Error text, shown with `role="alert"`; `nil` shows nothing.
    let error: String?
    /// Notice text, shown with `role="status"`; `nil` shows nothing.
    let notice: String?

    var body: some HTML {
        if let error {
            p(.class("error"), .custom(name: "role", value: "alert")) { error }
        }
        if let notice {
            p(.class("notice"), .custom(name: "role", value: "status")) { notice }
        }
    }
}
