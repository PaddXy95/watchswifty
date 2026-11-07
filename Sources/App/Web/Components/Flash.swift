import Elementary
import Vapor

/// Error message for htmx actions: retargets the swap to the page's `#flash` area.
struct FlashMessage: HTML {
    let message: String
    var body: some HTML {
        p(.class("error"), .custom(name: "role", value: "alert")) { message }
    }
}

func flashError(_ message: String, status: HTTPStatus = .unprocessableEntity) -> HTMLResponse {
    HTMLResponse(status: status, headers: ["HX-Retarget": "#flash", "HX-Reswap": "innerHTML"], FlashMessage(message: message))
}
