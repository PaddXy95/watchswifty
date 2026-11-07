@testable import App
import Elementary
import Foundation
import Testing
import VaporTesting

@Suite("Version")
struct VersionTests {
    @Test func versionFromEnvironment() {
        #expect(AppVersion.fromEnvironment([:]) == AppVersion(version: "dev", commit: nil))
        #expect(AppVersion.fromEnvironment(["APP_VERSION": "0.1.0", "GIT_COMMIT": "abcdef1234567"]) == AppVersion(version: "0.1.0", commit: "abcdef1234567"))
    }

    @Test func versionLabels() {
        let release = AppVersion(version: "0.1.0", commit: "abcdef1234")
        #expect(release.label == "v0.1.0")
        #expect(release.releaseURL == "https://github.com/PaddXy95/watchswifty/releases/tag/v0.1.0")
        let branch = AppVersion(version: "main", commit: "abcdef1234")
        #expect(branch.label == "main (abcdef1)")
        #expect(branch.releaseURL == nil)
        #expect(AppVersion(version: "dev", commit: nil).label == "dev")
    }

    @Test func versionEndpoint() async throws {
        try await withTestApp { app in
            var body = ""
            try await app.testing().test(.GET, "/version", afterResponse: { (res: TestingHTTPResponse) async in
                #expect(res.status == .ok)
                body = res.body.string
            })
            #expect(body.contains(#""version":"\#(AppVersion.current.version)""#))
        }
    }

    @Test func footerShowsVersion() {
        let html = PageLayout(title: "X", nav: nil) { p { "x" } }.render()
        #expect(html.contains(#"class="version""#))
        #expect(html.contains(AppVersion.current.label))
    }

    /// Node 20 actions are deprecated on GitHub runners; these majors run on Node 24.
    @Test func workflowUsesNode24Actions() throws {
        let workflow = try String(contentsOfFile: ".github/workflows/docker.yml", encoding: .utf8)
        for action in ["actions/checkout@v7", "actions/cache@v6", "docker/setup-buildx-action@v4",
                       "docker/login-action@v4", "docker/build-push-action@v7"] {
            #expect(workflow.contains(action), "\(action) missing")
        }
        #expect(!workflow.contains("@v3"))
    }

    /// Speed: dependencies compile in their own cached layer; the image builds while the tests run.
    @Test func ciCachesDependenciesAndBuildsInParallel() throws {
        let dockerfile = try String(contentsOfFile: "Dockerfile", encoding: .utf8)
        let stub = try #require(dockerfile.range(of: "Sources/App/main.swift"))
        let copyAll = try #require(dockerfile.range(of: "COPY . ."))
        #expect(stub.lowerBound < copyAll.lowerBound)
        let workflow = try String(contentsOfFile: ".github/workflows/docker.yml", encoding: .utf8)
        #expect(workflow.contains("  image:\n"))
        #expect(workflow.contains("push: false"))
        #expect(workflow.contains("cache-from: type=gha"))
    }

    /// Release notes come from the CHANGELOG section of the version in VERSION.
    @Test func changelogHasSectionForVersion() throws {
        let version = try String(contentsOfFile: "VERSION", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let changelog = try String(contentsOfFile: "CHANGELOG.md", encoding: .utf8)
        #expect(changelog.contains("## [\(version)]"))
    }

    @Test func composeTakesSettingsFromEnvFile() throws {
        let compose = try String(contentsOfFile: "docker-compose.yml", encoding: .utf8)
        #expect(compose.contains("TOKEN_KEY: ${TOKEN_KEY:?"))
        #expect(compose.contains("ghcr.io/paddxy95/watchswifty:${WATCHSWIFTY_VERSION:-latest}"))
        let example = try String(contentsOfFile: ".env.example", encoding: .utf8)
        for key in ["WATCHSWIFTY_VERSION=", "TOKEN_KEY=", "ADMIN_PASSWORD=", "TZ=", "PUBLIC_ORIGIN="] {
            #expect(example.contains(key), "\(key) missing")
        }
    }

    @Test func buildPassesVersion() throws {
        let dockerfile = try String(contentsOfFile: "Dockerfile", encoding: .utf8)
        #expect(dockerfile.contains("ARG APP_VERSION=dev"))
        #expect(dockerfile.contains("ENV APP_VERSION=$APP_VERSION"))
        let workflow = try String(contentsOfFile: ".github/workflows/docker.yml", encoding: .utf8)
        #expect(workflow.contains("APP_VERSION=${{ steps.version.outputs.version }}"))
        #expect(workflow.contains("needs: [test, image]"))   // release only after green tests
        #expect(workflow.contains("github.ref == 'refs/heads/main'"))
        #expect(workflow.contains("gh release create"))
        #expect(!workflow.contains("tags: [\"v*\"]"))
        #expect(workflow.contains("GIT_COMMIT=${{ github.sha }}"))
    }
}
