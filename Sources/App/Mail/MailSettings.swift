import Foundation

/// How the SMTP connection is secured.
enum MailEncryption: String, Codable, CaseIterable, Sendable {
    /// `starttls`: upgrade a plain connection; `ssl`: TLS from the start; `plain`: unencrypted.
    case starttls, ssl, plain

    /// Label shown in the mail form (**keine** means none).
    var label: String {
        switch self {
        case .starttls: "STARTTLS"
        case .ssl: "SSL/TLS"
        case .plain: "keine"
        }
    }

    /// Standard port for the encryption (587, 465 or 25).
    var defaultPort: Int {
        switch self {
        case .starttls: 587
        case .ssl: 465
        case .plain: 25
        }
    }
}

/// SMTP settings from System → E-Mail; stored as one sealed JSON block (secret: contains the SMTP password).
struct MailSettings: Codable, Sendable, Equatable {
    var host: String
    var port: Int?
    var encryption: MailEncryption
    var username: String?
    var password: String?
    var fromAddress: String
    var fromName: String
    /// PEM file with the CAs to trust instead of the system store, e.g. SwiftyRelay's `ca-bundle.pem`.
    var caFile: String?
    /// „Adresse von WatchSwifty“ (`https://host[:port]`, no trailing slash) – the only source for links in mails.
    var baseURL: String

    /// The configured port, or the encryption's default port.
    var effectivePort: Int { port ?? encryption.defaultPort }

    /// Password reset or invitation link for a token.
    /// - Parameter token: The password token.
    /// - Returns: `<baseURL>/reset-password?token=…`.
    func link(token: String) -> String {
        "\(baseURL)/reset-password?token=\(token)"
    }

    /// Konto page, where devices can be signed out.
    var accountLink: String { "\(baseURL)/account" }
}

/// Whether mail settings are stored and readable.
enum MailSettingsState: Equatable, Sendable {
    /// No settings stored.
    case notConfigured
    /// Stored, but the server key cannot decrypt it (TOKEN_KEY changed).
    case unreadable
    /// Stored and readable.
    case configured(MailSettings)

    /// The settings when configured, else nil.
    var settings: MailSettings? {
        if case .configured(let settings) = self { return settings }
        return nil
    }
}
