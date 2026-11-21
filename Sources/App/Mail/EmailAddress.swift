import Foundation

/// Checks and masks e-mail addresses. Only plain ASCII addresses are accepted (the SMTP client has no SMTPUTF8), and
/// nothing that could break out of a mail header.
enum EmailAddress {
    /// German error text for an invalid address.
    static let invalidMessage = "Bitte eine gültige E-Mail-Adresse eingeben."

    /// Characters rejected in addresses because they could break a mail header.
    private static let forbidden = Set("<>,;\"()")

    /// The address trimmed, with the domain lowercased; nil when it is not a plain `local@domain.tld` address.
    /// - Parameter raw: The address as entered.
    /// - Returns: The normalized address, or nil when invalid.
    static func normalize(_ raw: String) -> String? {
        let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, address.utf8.count <= 254,
              address.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) && !forbidden.contains(Character($0)) })
        else { return nil }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        let domain = parts[1].lowercased()
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..") else { return nil }
        return "\(parts[0])@\(domain)"
    }

    /// `p•••@idesia.de`: first character of the local part, then the domain.
    /// - Parameter address: A (normalized) address.
    /// - Returns: The masked address, or `•••` when it has no `@` or no local part.
    static func mask(_ address: String) -> String {
        guard let at = address.lastIndex(of: "@"), at > address.startIndex else { return "•••" }
        return "\(address[address.startIndex])•••\(address[at...])"
    }

    /// Masks every address inside a text, e.g. a mail server's reply.
    /// - Parameter text: Any text.
    /// - Returns: The text with each address replaced by its `mask(_:)`.
    static func maskAll(in text: String) -> String {
        text.replacing(#/[A-Za-z0-9._%+!#$&'*\/=?^`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/#) { match in
            mask(String(match.output))
        }
    }
}
