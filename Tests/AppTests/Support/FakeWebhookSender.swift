@testable import App
import Foundation
import NIOConcurrencyHelpers

/// Collects webhook calls instead of sending them; `failure` makes every call throw.
final class FakeWebhookSender: WebhookSender, @unchecked Sendable {
    struct Sent: Sendable {
        let url: String
        let key: String
        let message: NotificationMessage
    }

    private struct State {
        var sent: [Sent] = []
        var failure: WebhookError?
    }

    private let state = NIOLockedValueBox(State())

    var sent: [Sent] { state.withLockedValue { $0.sent } }
    var failure: WebhookError? {
        get { state.withLockedValue { $0.failure } }
        set { state.withLockedValue { $0.failure = newValue } }
    }

    func send(_ message: NotificationMessage, url: String, key: String) async throws {
        if let failure { throw failure }
        state.withLockedValue { $0.sent.append(Sent(url: url, key: key, message: message)) }
    }
}
