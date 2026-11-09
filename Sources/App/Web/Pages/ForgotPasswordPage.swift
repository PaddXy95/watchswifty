import Elementary

/// Ask for a reset link by username. The answer after sending is the same for every username.
struct ForgotPasswordPage: HTML {
    static let answer = "Falls es das Konto gibt und eine Mail-Adresse hinterlegt ist, ist eine Mail unterwegs. Der Link gilt eine Stunde."
    static let mailOff = "Der Mail-Versand ist nicht eingerichtet. Bitte wende dich an deinen Admin."

    let mailEnabled: Bool
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
