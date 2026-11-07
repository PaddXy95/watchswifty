import Elementary

/// Error / notice lines shown above forms.
struct Messages: HTML {
    let error: String?
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
