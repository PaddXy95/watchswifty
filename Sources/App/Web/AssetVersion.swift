import Crypto
import Foundation
import Vapor

/// Cache busting for the stylesheet and htmx. The files are served without `Cache-Control`, so browsers keep them
/// for a while on their own; after an update they would style new markup with the old stylesheet. The links carry a
/// fingerprint of the file content instead (`/css/app.css?v=…`), which changes exactly when the file changes.
enum AssetVersion {
    static let css = fingerprint(file: "css/app.css")
    static let htmx = fingerprint(file: "js/htmx.min.js")

    /// `path?v=version`, or the bare path when the file could not be read.
    static func url(_ path: String, _ version: String?) -> String {
        version.map { "\(path)?v=\($0)" } ?? path
    }

    /// First 10 hex digits of the content's SHA-256.
    static func fingerprint(_ data: Data) -> String {
        String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(10))
    }

    /// Fingerprint of a file in `Public/`; nil when it cannot be read.
    static func fingerprint(file: String, publicDirectory: String = DirectoryConfiguration.detect().publicDirectory) -> String? {
        FileManager.default.contents(atPath: publicDirectory + file).map(fingerprint)
    }
}
