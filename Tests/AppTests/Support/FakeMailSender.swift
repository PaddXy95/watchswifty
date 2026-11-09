@testable import App
import Fluent
import Foundation
import NIOConcurrencyHelpers
import VaporTesting

/// SMTP stand-in: records every message, or fails with `failure`, optionally after `delay`.
final class FakeMailSender: MailSender, @unchecked Sendable {
    struct Sent: Sendable {
        let from: String
        let to: String
        let message: String

        /// Header value, e.g. `header("Subject")` (encoded words decoded).
        func header(_ name: String) -> String? {
            splitMessage(Data(message.utf8)).headers.first { $0.hasPrefix("\(name): ") }
                .map { decodeEncodedWord(String($0.dropFirst(name.count + 2))) }
        }

        /// Decoded body text.
        var body: String { decodeQuotedPrintable(splitMessage(Data(message.utf8)).body) }
    }

    private struct State {
        var sent: [Sent] = []
        var failure: MailError?
        var delay: Duration?
    }

    private let state = NIOLockedValueBox(State())

    var sent: [Sent] { state.withLockedValue { $0.sent } }
    var failure: MailError? {
        get { state.withLockedValue { $0.failure } }
        set { state.withLockedValue { $0.failure = newValue } }
    }
    var delay: Duration? {
        get { state.withLockedValue { $0.delay } }
        set { state.withLockedValue { $0.delay = newValue } }
    }

    func send(_ message: Data, from: String, to: String, settings: MailSettings) async throws {
        if let delay { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        state.withLockedValue { $0.sent.append(Sent(from: from, to: to, message: String(decoding: message, as: UTF8.self))) }
    }
}

/// Stores working mail settings (relay.test, STARTTLS, no login, from noreply@example.org).
func configureMail(_ app: Application, baseURL: String = "https://watch.example.lan") async throws {
    try await MailSettingsService(db: app.db, cipher: app.tokenCipher).save(MailSettingsInput(
        host: "relay.test", port: nil, encryption: "starttls", username: nil, password: nil,
        fromAddress: "noreply@example.org", fromName: nil, caFile: nil, baseURL: baseURL))
}
