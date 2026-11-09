import Foundation

enum MailEncryption: String, Codable, CaseIterable, Sendable {
    case starttls, ssl, plain

    var label: String {
        switch self {
        case .starttls: "STARTTLS"
        case .ssl: "SSL/TLS"
        case .plain: "keine"
        }
    }

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

    var effectivePort: Int { port ?? encryption.defaultPort }

    func link(token: String) -> String {
        "\(baseURL)/reset-password?token=\(token)"
    }
}

enum MailSettingsState: Equatable, Sendable {
    case notConfigured
    /// Stored, but the server key cannot decrypt it (TOKEN_KEY changed).
    case unreadable
    case configured(MailSettings)

    var settings: MailSettings? {
        if case .configured(let settings) = self { return settings }
        return nil
    }
}
