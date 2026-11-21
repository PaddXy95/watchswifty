import Foundation

/// Rules and German messages for usernames and passwords, shared by web UI, API and commands.
enum AccountValidation {
    static let usernameMessage = "Benutzername: 3–32 Zeichen, nur a–z, 0–9, . _ -"
    static let passwordMessage = "Passwort muss mindestens 8 Zeichen haben."
    static let duplicateMessage = "Benutzername ist vergeben."
    static let lastAdminMessage = "Der letzte Admin kann nicht entfernt werden."
    static let selfDeleteMessage = "Du kannst dich nicht selbst löschen."
    static let wrongCurrentPasswordMessage = "Aktuelles Passwort ist falsch."

    private static let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")

    /// Validates an already normalized username.
    ///
    /// Allowed: 3 to 32 characters from `a–z`, `0–9`, `.`, `_` and `-`.
    /// - Parameter username: The normalized username.
    /// - Returns: The German error message, or `nil` when the username is valid.
    static func usernameError(_ username: String) -> String? {
        guard (3...32).contains(username.count), username.allSatisfy(allowed.contains) else { return usernameMessage }
        return nil
    }

    /// Checks the minimum password length of 8 characters.
    /// - Parameter password: The password as entered.
    /// - Returns: The German error message, or `nil` when the password is long enough.
    static func passwordError(_ password: String) -> String? {
        password.count >= 8 ? nil : passwordMessage
    }
}
