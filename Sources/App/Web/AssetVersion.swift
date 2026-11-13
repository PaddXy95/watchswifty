import Crypto
import Foundation
import Logging
import NIOConcurrencyHelpers
import Vapor

/// Cache busting for the stylesheet and htmx. The files are served without `Cache-Control`, so browsers keep them
/// for a while on their own; after an update they would style new markup with the old stylesheet. The links carry a
/// fingerprint of the file content instead (`/css/app.css?v=…`), which changes exactly when the file changes.
enum AssetVersion {
    typealias Fingerprints = (css: String?, htmx: String?)

    /// Set by `configure` from the directory `FileMiddleware` serves; until then (pages rendered without an app, e.g.
    /// in unit tests) the working directory's `Public/` is used.
    private static let configured = NIOLockedValueBox<Fingerprints?>(nil)
    private static let detected = fingerprints(publicDirectory: DirectoryConfiguration.detect().publicDirectory)

    static var css: String? { (configured.withLockedValue { $0 } ?? detected).css }
    static var htmx: String? { (configured.withLockedValue { $0 } ?? detected).htmx }

    /// Fingerprints the files the app actually serves; a missing file is logged (its link then goes without `?v=`).
    static func configure(publicDirectory: String, logger: Logger) {
        let found = fingerprints(publicDirectory: publicDirectory)
        if found.css == nil || found.htmx == nil {
            logger.warning("Asset-Versionen: css/app.css oder js/htmx.min.js fehlt in \(publicDirectory) – Links ohne ?v=")
        }
        configured.withLockedValue { $0 = found }
    }

    static func fingerprints(publicDirectory: String) -> Fingerprints {
        (fingerprint(file: "css/app.css", publicDirectory: publicDirectory),
         fingerprint(file: "js/htmx.min.js", publicDirectory: publicDirectory))
    }

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
