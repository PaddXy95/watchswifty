import Fluent
import Foundation
import Vapor

/// The System page's mail form (and the API's `MailSettingsUpdate`, mapped to it). An empty password keeps the stored one.
struct MailSettingsInput: Content {
    var host: String
    /// Port as entered; empty means the encryption's default port.
    var port: String?
    /// Raw value of `MailEncryption` (`starttls`, `ssl`, `plain`).
    var encryption: String
    var username: String?
    var password: String?
    var fromAddress: String
    var fromName: String?
    /// Path of a PEM file with CAs to trust instead of the system store.
    var caFile: String?
    /// „Adresse von WatchSwifty“ (WatchSwifty's address) used for links in mails.
    var baseURL: String
}

/// Reads and writes the mail settings, sealed with the server key like the TMDB tokens.
struct MailSettingsService {
    /// German error text for a missing or malformed server name.
    static let hostMessage = "Bitte einen Server angeben."
    /// German error text for a port outside 1…65535.
    static let portMessage = "Port muss zwischen 1 und 65535 liegen."
    /// German error text for an unknown encryption.
    static let encryptionMessage = "Bitte eine Verschlüsselung wählen."
    /// German error text for an invalid WatchSwifty address.
    static let baseURLMessage = "Adresse von WatchSwifty: z. B. https://watch.example.lan (ohne Pfad)."
    /// German error text when the stored password may not be kept because the connection changed.
    static let passwordReentryMessage = "Bitte das Passwort neu eingeben – Server, Port, Verschlüsselung oder Benutzer wurden geändert."
    /// German error text when a user is set but no password is entered or stored.
    static let passwordMissingMessage = "Bitte ein Passwort angeben."
    /// German error text for a password entered without a user.
    static let passwordWithoutUserMessage = "Ein Passwort gilt nur mit Benutzer – bitte den Benutzer eintragen oder das Passwort leer lassen."

    let db: any Database
    /// Cipher sealing the settings JSON (`TokenCipher`, server key).
    let cipher: TokenCipher

    /// Loads and decrypts the stored mail settings.
    /// - Returns: `.notConfigured` without stored settings, `.unreadable` when they cannot be decrypted or decoded,
    ///   otherwise `.configured`.
    /// - Throws: Database errors.
    func state() async throws -> MailSettingsState {
        guard let sealed = try await AppSettings.query(on: db).first()?.mailConfig, !sealed.isEmpty else { return .notConfigured }
        guard let json = cipher.open(sealed),
              let settings = try? JSONDecoder().decode(MailSettings.self, from: Data(json.utf8)) else { return .unreadable }
        return .configured(settings)
    }

    /// Validates the form input and stores it sealed in `app_settings.mail_config`.
    /// - Parameter input: The submitted form values; an empty password keeps the stored one if the connection is unchanged.
    /// - Returns: The validated settings.
    /// - Throws: `APIError.validation` with a German message for invalid input; encryption and database errors.
    @discardableResult
    func save(_ input: MailSettingsInput) async throws -> MailSettings {
        let settings = try validated(input, stored: try await state().settings)
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        let row = try await AppSettings.query(on: db).first() ?? AppSettings()
        row.mailConfig = try cipher.seal(json)
        try await row.save(on: db)
        return settings
    }

    /// Removes the stored mail settings (mail is then not set up).
    /// - Throws: Database errors.
    func delete() async throws {
        guard let row = try await AppSettings.query(on: db).first() else { return }
        row.mailConfig = nil
        try await row.save(on: db)
    }

    /// Checks and normalizes the form input.
    /// - Parameters:
    ///   - input: The submitted form values.
    ///   - stored: The currently stored settings, to keep their password.
    /// - Returns: The normalized settings (default sender name „WatchSwifty“, line breaks removed from it).
    /// - Throws: `APIError.validation` with a German message for any invalid field.
    private func validated(_ input: MailSettingsInput, stored: MailSettings?) throws -> MailSettings {
        let host = input.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace || $0 == "/" }) else { throw APIError.validation(Self.hostMessage) }
        let port = try Self.port(input.port)
        guard let encryption = MailEncryption(rawValue: input.encryption) else { throw APIError.validation(Self.encryptionMessage) }
        guard let fromAddress = EmailAddress.normalize(input.fromAddress) else { throw APIError.validation(EmailAddress.invalidMessage) }
        guard let baseURL = Self.baseURL(input.baseURL) else { throw APIError.validation(Self.baseURLMessage) }
        let username = Self.optional(input.username)
        let fromName = (Self.optional(input.fromName) ?? "WatchSwifty").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")

        var settings = MailSettings(host: host, port: port, encryption: encryption, username: username, password: nil,
                                    fromAddress: fromAddress, fromName: fromName, caFile: Self.optional(input.caFile), baseURL: baseURL)
        if username != nil {
            settings.password = try Self.password(input.password, new: settings, stored: stored)
        } else if Self.optional(input.password) != nil {
            // Never drop an entered password silently: the mails would go out without login.
            throw APIError.validation(Self.passwordWithoutUserMessage)
        }
        return settings
    }

    /// The stored password survives only while the connection (server, port, encryption, user) stays the same, so a
    /// hijacked admin session cannot redirect it to a server of its own.
    /// - Parameters:
    ///   - entered: The password from the form, empty to keep the stored one.
    ///   - new: The new settings (connection to compare).
    ///   - stored: The currently stored settings.
    /// - Returns: The password to store.
    /// - Throws: `APIError.validation` with `passwordMissingMessage` when there is none to keep, or
    ///   `passwordReentryMessage` when the connection changed.
    private static func password(_ entered: String?, new: MailSettings, stored: MailSettings?) throws -> String {
        if let entered, !entered.isEmpty { return entered }
        guard let stored, let password = stored.password else { throw APIError.validation(passwordMissingMessage) }
        let sameConnection = stored.host == new.host && stored.effectivePort == new.effectivePort
            && stored.encryption == new.encryption && stored.username == new.username
        guard sameConnection else { throw APIError.validation(passwordReentryMessage) }
        return password
    }

    /// Parses the optional port.
    /// - Parameter raw: The port as entered.
    /// - Returns: The port, or nil when empty.
    /// - Throws: `APIError.validation` with `portMessage` when not a number in 1…65535.
    private static func port(_ raw: String?) throws -> Int? {
        guard let text = optional(raw) else { return nil }
        guard let port = Int(text), (1...65535).contains(port) else { throw APIError.validation(portMessage) }
        return port
    }

    /// `scheme://host[:port]` (http/https, lowercased, no trailing slash); nil with a path, query, fragment or user info.
    /// - Parameter raw: The address as entered.
    /// - Returns: The normalized address, or nil when invalid.
    static func baseURL(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.path.isEmpty, url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil, !text.contains("#"), !text.contains("?") else { return nil }
        return text.lowercased()
    }

    /// Trims a form value and treats an empty one as missing.
    /// - Parameter raw: The value as entered.
    /// - Returns: The trimmed value, or nil when empty.
    private static func optional(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

extension Request {
    /// A mail settings service for this request.
    var mailSettings: MailSettingsService { MailSettingsService(db: db, cipher: application.tokenCipher) }
}
