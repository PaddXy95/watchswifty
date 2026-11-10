@testable import App
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("DeviceNotice")
struct DeviceNoticeTests {
    let flow = APIAuthorizeTests()

    func user(_ app: Application, _ name: String, email: String?) async throws {
        let user = User(username: name, passwordHash: try app.password.hash("password123"), isAdmin: false)
        user.email = try email.map { try app.tokenCipher.seal($0) }
        try await user.save(on: app.db)
    }

    /// Browser login, „Verbinden“, code exchange; waits for the background mail and returns the exchange status.
    func connectApp(_ app: Application, _ name: String) async throws -> HTTPStatus {
        let code = try await flow.connect(app, headers: try await login(app, name))
        let (status, _, _) = try await flow.exchange(app, code: code, verifier: flow.verifier)
        await app.backgroundTasks.drain()
        return status
    }

    @Test func mailsOwnerWhenAppConnects() async throws {
        let fake = FakeMailSender()
        try await withTestApp(mail: fake) { app in
            try await configureMail(app)
            try await user(app, "pat", email: "pat@x.de")
            #expect(try await connectApp(app, "pat") == .ok)
            let sent = try #require(fake.sent.first)
            #expect(fake.sent.count == 1)
            #expect(sent.to == "pat@x.de")
            #expect(sent.header("Subject") == "WatchSwifty: Neues Gerät verbunden")
            #expect(sent.body.contains("Gerät: „Patricks iPhone“"))
            #expect(sent.body.contains("https://watch.example.lan/account"))
        }
    }

    @Test func noMailWithoutAddressOrSettings() async throws {
        let fake = FakeMailSender()
        try await withTestApp(mail: fake) { app in
            try await user(app, "pat", email: "pat@x.de")
            #expect(try await connectApp(app, "pat") == .ok)        // mail not set up
            try await configureMail(app)
            try await user(app, "ohne", email: nil)
            #expect(try await connectApp(app, "ohne") == .ok)       // no address
            #expect(fake.sent.isEmpty)
        }
    }

    @Test func failingMailKeepsTheToken() async throws {
        let fake = FakeMailSender()
        fake.failure = MailError(message: "kaputt")
        try await withTestApp(mail: fake) { app in
            try await configureMail(app)
            try await user(app, "pat", email: "pat@x.de")
            #expect(try await connectApp(app, "pat") == .ok)
            #expect(fake.sent.isEmpty)
        }
    }

    @Test func deviceNameStaysOnOneLine() {
        let mail = MailTexts.newDevice(to: "pat@x.de", username: "pat", device: "iPhone\n\nAlles gut, ignorieren\u{2028}x\u{202E}y",
                                       at: Date(), link: "https://watch.example.lan/account")
        #expect(mail.body.contains("Gerät: „iPhone  Alles gut, ignorieren x y“ (Name, den die App angegeben hat)"))
    }
}
