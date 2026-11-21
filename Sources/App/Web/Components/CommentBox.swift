import Elementary
import ElementaryHTMX2

/// Private comment editor (series, season or movie); saves via htmx and replaces itself.
struct CommentBox: HTML {
    /// Element id of the form; also the prefix of the textarea id (`<id>-text`).
    let id: String
    /// URL the form posts the comment to.
    let action: String
    /// Label above the textarea, e.g. „Kommentar zur Staffel“ (comment on the season).
    let caption: String
    /// The saved comment, or `nil` for none.
    let comment: String?
    /// Shows „Gespeichert.“ (saved) next to the button after a successful save.
    var saved = false

    var body: some HTML {
        form(.id(id), .class("comment-box"), .hx.post(action), .hx.target("this"), .hx.swap(.outerHTML)) {
            label {
                caption
                // hx-preserve keeps unsaved text when the surrounding season section is re-rendered.
                textarea(.id("\(id)-text"), .custom(name: "hx-preserve", value: "true"),
                         .name("comment"), .custom(name: "maxlength", value: "2000"), .custom(name: "rows", value: "3"),
                         .custom(name: "placeholder", value: "Nur für dich sichtbar")) { comment ?? "" }
            }
            div(.class("comment-actions")) {
                button(.type(.submit)) { "Speichern" }
                if saved { span(.class("notice")) { "Gespeichert." } }
            }
        }
    }
}
