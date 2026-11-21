import Elementary

/// Ask for a reset link by username. The answer after sending is the same for every username.
struct ForgotPasswordPage: HTML {
    /// Answer after a request, the same for every username so it does not reveal which accounts exist.
    static let answer = "Falls es das Konto gibt und eine Mail-Adresse hinterlegt ist, ist eine Mail unterwegs. Der Link gilt eine Stunde."
    /// Shown instead of the form while mail is not set up.
    static let mailOff = "Der Mail-Versand ist nicht eingerichtet. Bitte wende dich an deinen Admin."

    /// Mail is set up; without it only `mailOff` is shown.
    let mailEnabled: Bool
    /// A request was just submitted: shows `answer` instead of the form.
    var sent = false

    var body: some HTML {
        PageLayout(title: "Passwort vergessen", nav: nil) {
            section(.class("login")) {
                h1 { "Passwort vergessen" }
                if !mailEnabled {
                    p { Self.mailOff }
                } else if sent {
                    p(.class("notice"), .custom(name: "role", value: "status")) { Self.answer }
                } else {
                    p(.class("muted")) { "Gib deinen Benutzernamen ein. Ist für das Konto eine Mail-Adresse hinterlegt, bekommst du einen Link zum Zurücksetzen." }
                    form(.method(.post), .action("/forgot-password")) {
                        label {
                            "Benutzername"
                            input(.type(.text), .name("username"), .required, .autofocus, .custom(name: "autocomplete", value: "username"))
                        }
                        button(.type(.submit), .class("primary")) { "Link anfordern" }
                    }
                }
                p { a(.href("/login")) { "Zur Anmeldung" } }
            }
        }
    }
}
