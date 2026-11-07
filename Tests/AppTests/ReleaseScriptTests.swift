import Foundation
import Testing

/// Runs the release scripts in a throwaway git repository.
@Suite("ReleaseScripts", .serialized)
struct ReleaseScriptTests {
    static let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    @discardableResult
    func run(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = dir
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func repo(version: String, tags: [String], changelog: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ws-release-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "\(version)\n".write(to: dir.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        if let changelog { try changelog.write(to: dir.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8) }
        try run(["git", "init", "-q"], in: dir)
        try run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"], in: dir)
        for tag in tags { try run(["git", "tag", tag], in: dir) }
        return dir
    }

    func nextVersion(_ dir: URL) throws -> String {
        try run(["bash", Self.root.appendingPathComponent("scripts/next-version.sh").path], in: dir)
    }

    @Test func firstReleaseUsesVersionFile() throws {
        #expect(try nextVersion(repo(version: "0.1.0", tags: [])) == "0.1.0")
    }

    @Test func nextPatchAfterExistingTag() throws {
        #expect(try nextVersion(repo(version: "0.1.0", tags: ["v0.1.0"])) == "0.1.1")
        #expect(try nextVersion(repo(version: "0.1.0", tags: ["v0.1.0", "v0.1.1", "v0.1.9", "v0.1.10"])) == "0.1.11")
    }

    @Test func bumpedVersionFileWins() throws {
        #expect(try nextVersion(repo(version: "0.2.0", tags: ["v0.1.0", "v0.1.1"])) == "0.2.0")
    }

    @Test func bumpedVersionAlreadyReleasedGetsPatch() throws {
        #expect(try nextVersion(repo(version: "0.2.0", tags: ["v0.1.4", "v0.2.0"])) == "0.2.1")
    }

    @Test func releaseNotesFromChangelog() throws {
        let changelog = "# Changelog\n\n## [0.2.0] – 2026-12-01\n\n- Neu: X\n\n## [0.1.0] – 2026-11-07\n\n- Erste Version\n"
        let dir = try repo(version: "0.2.0", tags: [], changelog: changelog)
        let notes = try run(["bash", Self.root.appendingPathComponent("scripts/release-notes.sh").path, "0.2.0"], in: dir)
        #expect(notes == "- Neu: X")
        let none = try run(["bash", Self.root.appendingPathComponent("scripts/release-notes.sh").path, "0.3.0"], in: dir)
        #expect(none.isEmpty)
    }
}
