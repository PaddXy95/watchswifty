import Foundation
import Vapor

/// Version of the running build (`APP_VERSION` / `GIT_COMMIT`, set in the Docker image by CI).
struct AppVersion: Sendable, Content, Equatable {
    let version: String
    let commit: String?

    /// Reads the version from `APP_VERSION` (default `dev`) and the commit from `GIT_COMMIT`.
    /// - Parameter env: The process environment.
    /// - Returns: The version.
    static func fromEnvironment(_ env: [String: String]) -> AppVersion {
        /// The trimmed value of a variable; nil when unset or blank.
        func value(_ key: String) -> String? {
            guard let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }
        return AppVersion(version: value("APP_VERSION") ?? "dev", commit: value("GIT_COMMIT"))
    }

    /// The version of this process, read once from its environment.
    static let current = AppVersion.fromEnvironment(ProcessInfo.processInfo.environment)

    /// Whether `version` is a plain `X.Y.Z` release number.
    private var isRelease: Bool {
        let parts = version.split(separator: ".")
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// „v0.1.0“ for releases, „main (abc1234)“ for branch builds, „dev“ locally.
    var label: String {
        if isRelease { return "v\(version)" }
        if let commit, !commit.isEmpty { return "\(version) (\(commit.prefix(7)))" }
        return version
    }

    /// The GitHub release page for release builds; nil otherwise.
    var releaseURL: String? {
        isRelease ? "https://github.com/PaddXy95/watchswifty/releases/tag/v\(version)" : nil
    }
}
