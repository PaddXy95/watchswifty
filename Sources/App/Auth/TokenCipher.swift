import Crypto
import Fluent
import Foundation
import Logging

/// Encrypts the users' TMDB tokens at rest (AES-GCM with a server key). Stored form: `enc:v1:` + Base64(nonce|ciphertext|tag).
struct TokenCipher: Sendable {
    static let prefix = "enc:v1:"
    let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    func seal(_ token: String) throws -> String {
        guard let combined = try AES.GCM.seal(Data(token.utf8), using: key).combined else {
            throw ConfigError.invalid("Token konnte nicht verschlüsselt werden.")
        }
        return Self.prefix + combined.base64EncodedString()
    }

    /// Plain token; nil for no token or one this key cannot decrypt. Values without the prefix are
    /// legacy plaintext (stored before encryption) and are returned as they are.
    func open(_ stored: String?) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        guard stored.hasPrefix(Self.prefix) else { return stored }
        guard let data = Data(base64Encoded: String(stored.dropFirst(Self.prefix.count))),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: plain, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Finds the server key: `TOKEN_KEY` (Base64, 32 bytes), else the file `TOKEN_KEY_FILE`, else `token.key` next to the
/// database (created on first start). In-memory databases (tests) get a random key.
enum TokenKeyLoader {
    static func load(key: String?, file: String?, databasePath: String, logger: Logger) throws -> SymmetricKey {
        if let key {
            return try decode(key, source: "TOKEN_KEY")
        }
        if let file {
            guard let contents = FileManager.default.contents(atPath: file), let text = String(data: contents, encoding: .utf8) else {
                throw ConfigError.invalid("TOKEN_KEY_FILE: Datei \(file) nicht lesbar.")
            }
            return try decode(text, source: "TOKEN_KEY_FILE")
        }
        if databasePath == ":memory:" {
            return SymmetricKey(size: .bits256)
        }
        let path = URL(fileURLWithPath: databasePath).deletingLastPathComponent().appendingPathComponent("token.key").path
        if let contents = FileManager.default.contents(atPath: path), let text = String(data: contents, encoding: .utf8) {
            return try decode(text, source: path)
        }
        let generated = SymmetricKey(size: .bits256)
        let encoded = generated.withUnsafeBytes { Data($0) }.base64EncodedString() + "\n"
        guard FileManager.default.createFile(atPath: path, contents: Data(encoded.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw ConfigError.invalid("Schlüsseldatei \(path) konnte nicht angelegt werden – TOKEN_KEY setzen.")
        }
        logger.notice("TOKEN_KEY nicht gesetzt – Schlüssel für die TMDB-Tokens in \(path) erzeugt. Für besseren Schutz TOKEN_KEY setzen (siehe README).")
        return generated
    }

    private static func decode(_ text: String, source: String) throws -> SymmetricKey {
        guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), data.count == 32 else {
            throw ConfigError.invalid("\(source): erwartet 32 Byte als Base64 (z. B. `openssl rand -base64 32`).")
        }
        return SymmetricKey(data: data)
    }
}

/// Encrypts tokens still stored in plaintext (from before encryption existed); returns how many were converted.
func encryptStoredTokens(db: any Database, cipher: TokenCipher) async throws -> Int {
    let users = try await User.query(on: db).filter(\.$tmdbToken != nil).all()
    var converted = 0
    for user in users {
        guard let token = user.tmdbToken, !token.isEmpty, !token.hasPrefix(TokenCipher.prefix) else { continue }
        user.tmdbToken = try cipher.seal(token)
        try await user.save(on: db)
        converted += 1
    }
    return converted
}
