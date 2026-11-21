import Elementary
import Vapor

/// Error message for htmx actions: retargets the swap to the page's `#flash` area.
struct FlashMessage: HTML {
    /// German error text, rendered with `role="alert"` so screen readers announce it.
    let message: String
    var body: some HTML {
        p(.class("error"), .custom(name: "role", value: "alert")) { message }
    }
}

/// Builds an htmx error response that shows `message` in the page's `#flash` area instead of the original target.
///
/// Sets `HX-Retarget: #flash` and `HX-Reswap: innerHTML`, plus `HX-Push-Url: false` so a failed boosted navigation
/// leaves the address bar unchanged.
/// - Parameters:
///   - message: German error text shown to the user.
///   - status: HTTP status of the response; defaults to `422 Unprocessable Entity`.
/// - Returns: An `HTMLResponse` wrapping a ``FlashMessage``.
func flashError(_ message: String, status: HTTPStatus = .unprocessableEntity) -> HTMLResponse {
    // HX-Push-Url: a failed boosted navigation must not change the address bar.
    HTMLResponse(status: status, headers: ["HX-Retarget": "#flash", "HX-Reswap": "innerHTML", "HX-Push-Url": "false"],
                 FlashMessage(message: message))
}
