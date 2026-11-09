@testable import App
import Foundation
import Testing

/// Decodes a quoted-printable body (soft breaks `=\r\n`, `=XX` bytes) back to text.
func decodeQuotedPrintable(_ encoded: String) -> String {
    var bytes: [UInt8] = []
    let input = Array(encoded.replacingOccurrences(of: "=\r\n", with: "").utf8)
    var index = 0
    while index < input.count {
        if input[index] == UInt8(ascii: "="), index + 2 < input.count,
           let byte = UInt8(String(decoding: input[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
            bytes.append(byte)
            index += 3
        } else {
            bytes.append(input[index])
            index += 1
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// Decodes `=?UTF-8?B?…?=` encoded words; returns other values unchanged.
func decodeEncodedWord(_ value: String) -> String {
    guard value.hasPrefix("=?UTF-8?B?"), value.hasSuffix("?=") else { return value }
    let base64 = String(value.dropFirst("=?UTF-8?B?".count).dropLast(2))
    return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) } ?? value
}

/// Splits a rendered message into header lines and the (still encoded) body.
func splitMessage(_ data: Data) -> (headers: [String], body: String) {
    let text = String(decoding: data, as: UTF8.self)
    let parts = text.components(separatedBy: "\r\n\r\n")
    return (parts[0].components(separatedBy: "\r\n"), parts.dropFirst().joined(separator: "\r\n\r\n"))
}

@Suite("MailMessage")
struct MailMessageTests {
    static let longURL = "https://watch.example.lan/reset-password?token=" + String(repeating: "A", count: 75)
    let mail = OutgoingMail(to: "p@x.de", subject: "WatchSwifty: Passwort zurücksetzen",
                            body: "Grüße\n.\nFrom here\n" + MailMessageTests.longURL)

    func render(fromName: String = "WatchSwifty Ä") -> Data {
        MailMessage.render(mail, fromAddress: "noreply@example.org", fromName: fromName,
                           date: Date(timeIntervalSince1970: 1_794_000_000), messageID: "<id@example.org>")
    }

    @Test func emailNormalization() {
        #expect(EmailAddress.normalize(" Pat@IDESIA.de ") == "Pat@idesia.de")
        #expect(EmailAddress.normalize("p.meindl+tv@idesia.de") == "p.meindl+tv@idesia.de")
        for invalid in ["Pat <p@x.de>", "p@x", "pä@x.de", "a b@x.de", "p@@x.de", "@x.de", "p@",
                        "p@x.de\r\nBcc: y@z.de", String(repeating: "a", count: 250) + "@x.de", ""] {
            #expect(EmailAddress.normalize(invalid) == nil, "\(invalid) should be invalid")
        }
        #expect(EmailAddress.invalidMessage == "Bitte eine gültige E-Mail-Adresse eingeben.")
    }

    @Test func maskFormat() {
        #expect(EmailAddress.mask("patrick@idesia.de") == "p•••@idesia.de")
        #expect(EmailAddress.mask("a@b.de") == "a•••@b.de")
        #expect(EmailAddress.maskAll(in: "550 5.1.1 <alice@example.org>: unknown") == "550 5.1.1 <a•••@example.org>: unknown")
        #expect(EmailAddress.maskAll(in: "kein Treffer") == "kein Treffer")
    }

    @Test func messageIsSevenBitCRLF() {
        let bytes = [UInt8](render())
        #expect(bytes.allSatisfy { $0 < 128 })
        for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
            #expect(index > 0 && bytes[index - 1] == UInt8(ascii: "\r"))
        }
    }

    @Test func messageHeaders() {
        let (headers, _) = splitMessage(render())
        #expect(headers.contains("To: p@x.de"))
        #expect(headers.contains { $0.hasPrefix("Subject: =?UTF-8?B?") })
        #expect(headers.contains { $0.hasPrefix("From: =?UTF-8?B?") && $0.hasSuffix(" <noreply@example.org>") })
        #expect(headers.contains { $0.hasPrefix("Date: ") && $0.hasSuffix("+0000") })
        #expect(headers.contains("Message-ID: <id@example.org>"))
        #expect(headers.contains("MIME-Version: 1.0"))
        #expect(headers.contains("Content-Type: text/plain; charset=utf-8"))
        #expect(headers.contains("Content-Transfer-Encoding: quoted-printable"))
        let (plain, _) = splitMessage(render(fromName: "WatchSwifty"))
        #expect(plain.contains("From: WatchSwifty <noreply@example.org>"))
    }

    @Test func bodyRoundTrips() {
        let (headers, body) = splitMessage(render())
        #expect(decodeQuotedPrintable(body) == "Grüße\r\n.\r\nFrom here\r\n" + Self.longURL)
        let subject = headers.first { $0.hasPrefix("Subject: ") }.map { String($0.dropFirst("Subject: ".count)) } ?? ""
        #expect(decodeEncodedWord(subject) == "WatchSwifty: Passwort zurücksetzen")
        let from = headers.first { $0.hasPrefix("From: ") }?.dropFirst("From: ".count).components(separatedBy: " <").first ?? ""
        #expect(decodeEncodedWord(from) == "WatchSwifty Ä")
        for line in body.components(separatedBy: "\r\n") {
            #expect(line.count <= 76, "line too long: \(line)")
        }
    }
}
