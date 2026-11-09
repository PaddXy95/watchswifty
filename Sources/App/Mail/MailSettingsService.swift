import Fluent
import Foundation
import Vapor

/// The System page's mail form (and the API's `MailSettingsUpdate`, mapped to it). An empty password keeps the stored one.
struct MailSettingsInput: Content {
    var host: String
    var port: String?
    var encryption: String
    var username: String?
    var password: String?
    var fromAddress: String
    var fromName: String?
    var caFile: String?
    var baseURL: String
}

/// Reads and writes the mail settings, sealed with the server key like the TMDB tokens.
struct MailSettingsService {
    static let hostMessage = "Bitte einen Server angeben."
    static let portMessage = "Port muss zwischen 1 und 65535 liegen."
    static let encryptionMessage = "Bitte eine Verschlüsselung wählen."
    static let baseURLMessage = "Adresse von WatchSwifty: z. B. https://watch.example.lan (ohne Pfad)."
    static let passwordReentryMessage = "Bitte das Passwort neu eingeben – Server, Port, Verschlüsselung oder Benutzer wurden geändert."
    static let passwordMissingMessage = "Bitte ein Passwort angeben."

    let db: any Database
    let cipher: TokenCipher

    func state() async throws -> MailSettingsState {
        guard let sealed = try await AppSettings.query(on: db).first()?.mailConfig, !sealed.isEmpty else { return .notConfigured }
        guard let json = cipher.open(sealed),
              let settings = try? JSONDecoder().decode(MailSettings.self, from: Data(json.utf8)) else { return .unreadable }
        return .configured(settings)
    }

    @discardableResult
    func save(_ input: MailSettingsInput) async throws -> MailSettings {
        let settings = try validated(input, stored: try await state().settings)
        let json = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
        let row = try await AppSettings.query(on: db).first() ?? AppSettings()
        row.mailConfig = try cipher.seal(json)
        try await row.save(on: db)
        return settings
    }

    func delete() async throws {
        guard let row = try await AppSettings.query(on: db).first() else { return }
        row.mailConfig = nil
        try await row.save(on: db)
    }

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
        }
        return settings
    }

    /// The stored password survives only while the connection (server, port, encryption, user) stays the same, so a
    /// hijacked admin session cannot redirect it to a server of its own.
    private static func password(_ entered: String?, new: MailSettings, stored: MailSettings?) throws -> String {
        if let entered, !entered.isEmpty { return entered }
        guard let stored, let password = stored.password else { throw APIError.validation(passwordMissingMessage) }
        let sameConnection = stored.host == new.host && stored.effectivePort == new.effectivePort
            && stored.encryption == new.encryption && stored.username == new.username
        guard sameConnection else { throw APIError.validation(passwordReentryMessage) }
        return password
    }

    private static func port(_ raw: String?) throws -> Int? {
        guard let text = optional(raw) else { return nil }
        guard let port = Int(text), (1...65535).contains(port) else { throw APIError.validation(portMessage) }
        return port
    }

    /// `scheme://host[:port]` (http/https, lowercased, no trailing slash); nil with a path, query, fragment or user info.
    static func baseURL(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.path.isEmpty, url.query == nil, url.fragment == nil,
              url.user == nil, url.password == nil, !text.contains("#"), !text.contains("?") else { return nil }
        return text.lowercased()
    }

    private static func optional(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

extension Request {
    var mailSettings: MailSettingsService { MailSettingsService(db: db, cipher: application.tokenCipher) }
}
