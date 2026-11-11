@testable import App
import Foundation
import NIOConcurrencyHelpers
import Testing
import Vapor

/// Runs `LiveWebhookSender` against a throwaway local server that plays KNot.
@Suite("WebhookSender")
struct WebhookSenderTests {
    struct Received: Sendable {
        var path: String
        var key: String?
        var contentType: String?
        var json: [String: String]?
    }

    final class Recorder: Sendable {
        private let box = NIOLockedValueBox<[Received]>([])
        var all: [Received] { box.withLockedValue { $0 } }
        func add(_ item: Received) { box.withLockedValue { $0.append(item) } }
    }

    func withKNot(_ test: (_ base: String, _ recorder: Recorder) async throws -> Void) async throws {
        let server = try await Application.make(.testing)
        let recorder = Recorder()
        let record: @Sendable (Request) -> Void = { req in
            let json = req.body.data.flatMap { try? JSONSerialization.jsonObject(with: Data($0.readableBytesView)) as? [String: String] }
            recorder.add(Received(path: req.url.path, key: req.headers.first(name: "X-API-Key"),
                                  contentType: req.headers.first(name: .contentType), json: json))
        }
        server.post("hook") { req -> HTTPStatus in record(req); return .ok }
        server.post("fail") { req -> HTTPStatus in record(req); return .badGateway }
        server.post("moved") { req -> Response in
            record(req)
            let res = Response(status: .found)
            res.headers.replaceOrAdd(name: .location, value: "/hook")
            return res
        }
        do {
            try await server.server.start(address: .hostname("127.0.0.1", port: 0))
            let port = try #require(server.http.server.shared.localAddress?.port)
            try await test("http://127.0.0.1:\(port)", recorder)
        } catch {
            await server.server.shutdown()
            try await server.asyncShutdown()
            throw error
        }
        await server.server.shutdown()
        try await server.asyncShutdown()
    }

    let sender = LiveWebhookSender(userAgent: "WatchSwifty/test")

    @Test func liveSenderPostsKNotFormat() async throws {
        try await withKNot { base, recorder in
            try await sender.send(NotificationMessage(subject: "Betreff ä", body: "Zeile 1\nZeile 2"), url: "\(base)/hook",
                                  key: "k-1234567890abcdef")
            let received = try #require(recorder.all.first)
            #expect(recorder.all.count == 1)
            #expect(received.key == "k-1234567890abcdef")
            #expect(received.contentType?.hasPrefix("application/json") == true)
            #expect(received.json == ["subject": "Betreff ä", "body": "Zeile 1\nZeile 2"])
        }
    }

    @Test func liveSenderMapsStatus() async throws {
        try await withKNot { base, _ in
            await #expect(throws: WebhookError.status(502)) {
                try await sender.send(NotificationMessage(subject: "s", body: "b"), url: "\(base)/fail", key: "k-1234567890abcdef")
            }
        }
    }

    @Test func liveSenderDoesNotFollowRedirect() async throws {
        try await withKNot { base, recorder in
            await #expect(throws: WebhookError.status(302)) {
                try await sender.send(NotificationMessage(subject: "s", body: "b"), url: "\(base)/moved", key: "k-1234567890abcdef")
            }
            #expect(recorder.all.map(\.path) == ["/moved"])
        }
    }

    @Test func liveSenderUnreachable() async throws {
        let sender = LiveWebhookSender(userAgent: "WatchSwifty/test", connectTimeout: .milliseconds(300))
        do {
            try await sender.send(NotificationMessage(subject: "s", body: "b"), url: "http://127.0.0.1:1/hook", key: "k-1234567890abcdef")
            Issue.record("expected an error")
        } catch let error as WebhookError {
            #expect(error.message.hasPrefix("Webhook nicht erreichbar"))
            #expect(!error.message.contains("k-1234567890abcdef"))
        }
    }

    @Test func errorMessages() {
        #expect(WebhookError.status(401).message == "KNot kennt den Webhook-Schlüssel nicht (401) – Schlüssel unter Konto prüfen.")
        #expect(WebhookError.status(429).message == "Zu viele Nachrichten an dieses KNot-Ziel (429) – später erneut versuchen.")
        #expect(WebhookError.status(413).message == "Die Nachricht ist für KNot zu groß (413).")
        #expect(WebhookError.status(400).message == "KNot hat die Nachricht abgelehnt (400).")
        #expect(WebhookError.status(502).message == "KNot konnte die Mail nicht zustellen (502) – Log von KNot prüfen.")
        #expect(WebhookError.status(307).message == "Der Webhook leitet weiter (307) – bitte die Adresse unter System prüfen.")
        #expect(WebhookError.status(418).message == "Der Webhook hat mit Status 418 geantwortet.")
        #expect(WebhookError.timeout.message == "Der Webhook hat nicht rechtzeitig geantwortet.")
        #expect(WebhookError.notConfigured.message == "Der Webhook ist nicht eingerichtet.")
    }
}
