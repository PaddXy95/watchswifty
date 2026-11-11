import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1

/// A notification without recipient: KNot (or the mail path) decides where it goes.
struct NotificationMessage: Sendable, Equatable {
    var subject: String
    var body: String
}

/// A failed webhook call, with a German message (never contains the key).
struct WebhookError: Error, Equatable, Sendable {
    let message: String

    static let notConfigured = WebhookError(message: "Der Webhook ist nicht eingerichtet.")
    static let timeout = WebhookError(message: "Der Webhook hat nicht rechtzeitig geantwortet.")

    static func connect(_ detail: String) -> WebhookError {
        WebhookError(message: "Webhook nicht erreichbar (\(detail)).")
    }

    /// KNot's answers (see its docs/usage.md) in words; redirects are errors because the client never follows them.
    static func status(_ code: Int) -> WebhookError {
        let message = switch code {
        case 400: "KNot hat die Nachricht abgelehnt (400)."
        case 401: "KNot kennt den Webhook-Schlüssel nicht (401) – Schlüssel unter Konto prüfen."
        case 413: "Die Nachricht ist für KNot zu groß (413)."
        case 429: "Zu viele Nachrichten an dieses KNot-Ziel (429) – später erneut versuchen."
        case 502: "KNot konnte die Mail nicht zustellen (502) – Log von KNot prüfen."
        case 300..<400: "Der Webhook leitet weiter (\(code)) – bitte die Adresse unter System prüfen."
        default: "Der Webhook hat mit Status \(code) geantwortet."
        }
        return WebhookError(message: message)
    }
}

/// Posts a notification to a webhook in KNot's format.
protocol WebhookSender: Sendable {
    /// Throws `WebhookError`.
    func send(_ message: NotificationMessage, url: String, key: String) async throws
}

/// `POST url` with `X-API-Key` and `{"subject","body"}`. KNot delivers synchronously and needs up to ~50 s when its
/// mail server is down, so the deadline is 60 s (a shorter one would report a delivered mail as failed and send it
/// twice). Redirects are not followed, so the key only ever goes to the address the admin entered.
struct LiveWebhookSender: WebhookSender {
    let userAgent: String
    var deadline: TimeAmount = .seconds(60)
    var connectTimeout: TimeAmount = .seconds(10)

    func send(_ message: NotificationMessage, url: String, key: String) async throws {
        var configuration = HTTPClient.Configuration()
        configuration.redirectConfiguration = .disallow
        configuration.timeout = .init(connect: connectTimeout, read: deadline)
        let client = HTTPClient(eventLoopGroup: HTTPClient.defaultEventLoopGroup, configuration: configuration)
        do {
            try await post(message, url: url, key: key, client: client)
        } catch {
            try? await client.shutdown()
            throw error
        }
        try? await client.shutdown()
    }

    private func post(_ message: NotificationMessage, url: String, key: String, client: HTTPClient) async throws {
        var request = HTTPClientRequest(url: url)
        request.method = .POST
        request.headers.add(name: "X-API-Key", value: key)
        request.headers.add(name: "Content-Type", value: "application/json")
        request.headers.add(name: "User-Agent", value: userAgent)
        let body = try JSONEncoder().encode(["subject": message.subject, "body": message.body])
        request.body = .bytes(ByteBuffer(bytes: body))
        let response: HTTPClientResponse
        do {
            response = try await client.execute(request, timeout: deadline)
        } catch let error as HTTPClientError where [.deadlineExceeded, .readTimeout, .connectTimeout].contains(error) {
            throw WebhookError.timeout
        } catch {
            throw WebhookError.connect(String(describing: error))
        }
        _ = try? await response.body.collect(upTo: 64 * 1024)
        guard (200..<300).contains(Int(response.status.code)) else { throw WebhookError.status(Int(response.status.code)) }
    }
}
