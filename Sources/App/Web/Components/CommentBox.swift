import Elementary
import ElementaryHTMX2

/// Private comment editor (series, season or movie); saves via htmx and replaces itself.
struct CommentBox: HTML {
    let id: String
    let action: String
    let caption: String
    let comment: String?
    var saved = false

    var body: some HTML {
        form(.id(id), .class("comment-box"), .hx.post(action), .hx.target("this"), .hx.swap(.outerHTML)) {
            label {
                caption
                textarea(.name("comment"), .custom(name: "maxlength", value: "2000"), .custom(name: "rows", value: "3"),
                         .custom(name: "placeholder", value: "Nur für dich sichtbar")) { comment ?? "" }
            }
            div(.class("comment-actions")) {
                button(.type(.submit)) { "Speichern" }
                if saved { span(.class("notice")) { "Gespeichert." } }
            }
        }
    }
}
