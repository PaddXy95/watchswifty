import Foundation

/// A plain-text mail to one recipient.
struct OutgoingMail: Sendable, Equatable {
    var to: String
    var subject: String
    var body: String
}

/// Builds the RFC 5322 message the SMTP client sends: plain text, UTF-8, quoted-printable, 7-bit safe, CRLF.
enum MailMessage {
    static func render(_ mail: OutgoingMail, fromAddress: String, fromName: String, date: Date, messageID: String) -> Data {
        let headers = [
            "From: \(displayName(fromName)) <\(fromAddress)>",
            "To: \(mail.to)",
            "Subject: \(encodedWords(mail.subject))",
            "Date: \(rfc5322Date(date))",
            "Message-ID: \(messageID)",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: quoted-printable",
        ]
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + quotedPrintable(mail.body)).utf8)
    }

    private static let atext = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-/=?^_`{|}~ ")

    /// Plain when it is only atoms, a quoted string for other ASCII, encoded words for anything else.
    private static func displayName(_ name: String) -> String {
        if name.allSatisfy(atext.contains) { return name }
        if name.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) {
            return "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return encodedWords(name)
    }

    /// RFC 2047 `=?UTF-8?B?…?=` for non-ASCII header text, split into words of at most 75 characters.
    private static func encodedWords(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { !(0x20...0x7E).contains($0.value) }) else { return text }
        var words: [String] = []
        var chunk = ""
        for character in text {
            if (chunk + String(character)).utf8.count > 45 {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(character)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }

    private static func rfc5322Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// Quoted-printable (RFC 2045) with CRLF line ends and soft breaks keeping lines at 76 characters.
    private static func quotedPrintable(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return lines.map(encodeLine).joined(separator: "\r\n")
    }

    private static func encodeLine(_ line: String) -> String {
        let bytes = Array(line.utf8)
        var tokens: [String] = []
        for (index, byte) in bytes.enumerated() {
            let isLast = index == bytes.count - 1
            let literal = (0x21...0x7E).contains(byte) && byte != 0x3D
            let innerSpace = (byte == 0x20 || byte == 0x09) && !isLast
            if literal || innerSpace {
                tokens.append(String(UnicodeScalar(byte)))
            } else {
                let hex = String(byte, radix: 16, uppercase: true)
                tokens.append("=" + (hex.count == 1 ? "0" + hex : hex))
            }
        }
        var output: [String] = []
        var current = ""
        for token in tokens {
            if current.count + token.count > 75 {
                output.append(current + "=")
                current = ""
            }
            current += token
        }
        output.append(current)
        return output.joined(separator: "\r\n")
    }
}
