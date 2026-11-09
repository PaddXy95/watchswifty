import Foundation
import NIOCore
import NIOSSL
import SwiftySMTPClient

/// A failed send, with a German message for admins (addresses masked, never credentials).
struct MailError: Error, Equatable, Sendable {
    let message: String

    static let notConfigured = MailError(message: "Der Mail-Versand ist nicht eingerichtet.")
    static let timeout = MailError(message: "Der Mailserver hat nicht rechtzeitig geantwortet.")

    static func caFileUnreadable(_ path: String) -> MailError {
        MailError(message: "CA-Datei \(path) nicht lesbar.")
    }

    static func smtp(_ error: SMTPClientError) -> MailError {
        let message: String
        switch error {
        case .connectFailed(let detail):
            message = "Mailserver nicht erreichbar (\(detail))."
        case .tlsFailed(let detail):
            message = "TLS-Verbindung fehlgeschlagen – Zertifikat prüfen (CA-Datei, Servername): \(detail)"
        case .timeout:
            message = timeout.message
        case .connectionClosed(let stage):
            message = "Der Mailserver hat die Verbindung beendet (\(stage.rawValue))."
        case .malformedReply:
            message = "Unerwartete Antwort vom Mailserver."
        case .rejected(.auth, let reply):
            message = "Anmeldung am Mailserver abgelehnt (\(reply.code)) – Benutzer und Passwort prüfen."
        case .rejected(.rcptTo, let reply):
            message = "Empfänger abgelehnt (\(reply.code)): \(reply.text)"
        case .rejected(.mailFrom, let reply):
            message = "Absender abgelehnt (\(reply.code)): \(reply.text)"
        case .rejected(_, let reply):
            message = "Der Mailserver hat abgelehnt (\(reply.code)): \(reply.text)"
        case .startTLSNotOffered:
            message = "Der Mailserver bietet kein STARTTLS an – Verschlüsselung prüfen."
        case .authNotOffered:
            message = "Der Mailserver bietet keine Anmeldung an – Benutzer leer lassen oder Verschlüsselung prüfen."
        case .eightBitNotSupported:
            message = "Der Mailserver nimmt die Nachricht nicht an (8BITMIME fehlt)."
        case .messageTooLarge:
            message = "Die Nachricht ist für den Mailserver zu groß."
        }
        return MailError(message: EmailAddress.maskAll(in: message))
    }
}

/// Hands a finished message to an SMTP server.
protocol MailSender: Sendable {
    /// Throws `MailError`.
    func send(_ message: Data, from: String, to: String, settings: MailSettings) async throws
}

/// Sends through SwiftySMTPClient, one connection per mail. The CA file is read on every send, so a renewed relay CA
/// is picked up at once.
struct LiveMailSender: MailSender {
    func send(_ message: Data, from: String, to: String, settings: MailSettings) async throws {
        let configuration = SMTPClientConfiguration(
            host: settings.host, port: settings.port, encryption: SMTPEncryption(rawValue: settings.encryption.rawValue) ?? .starttls,
            credentials: credentials(settings), connectTimeout: .seconds(10), replyTimeout: .seconds(30),
            trustRoots: try trustRoots(settings.caFile))
        let client: SMTPClient
        do {
            client = try SMTPClient(configuration: configuration)
        } catch {
            throw MailError(message: "TLS-Einstellungen ungültig – CA-Datei prüfen.")
        }
        do throws(SMTPClientError) {
            try await client.send(from: from, recipients: [to], message: message)
        } catch {
            throw MailError.smtp(error)
        }
    }

    private func credentials(_ settings: MailSettings) -> SMTPCredentials? {
        guard let username = settings.username, let password = settings.password else { return nil }
        return SMTPCredentials(username: username, password: password)
    }

    private func trustRoots(_ caFile: String?) throws -> NIOSSLTrustRoots {
        guard let path = caFile else { return .default }
        guard FileManager.default.isReadableFile(atPath: path),
              let certificates = try? NIOSSLCertificate.fromPEMFile(path), !certificates.isEmpty else {
            throw MailError.caFileUnreadable(path)
        }
        return .certificates(certificates)
    }
}
