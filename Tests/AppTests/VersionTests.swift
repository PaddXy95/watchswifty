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

    @Test func buildPassesVersion() throws {
        let dockerfile = try String(contentsOfFile: "Dockerfile", encoding: .utf8)
        #expect(dockerfile.contains("ARG APP_VERSION=dev"))
        #expect(dockerfile.contains("ENV APP_VERSION=$APP_VERSION"))
        let workflow = try String(contentsOfFile: ".github/workflows/docker.yml", encoding: .utf8)
        #expect(workflow.contains("APP_VERSION=${{ steps.version.outputs.version }}"))
        #expect(workflow.contains("needs: test"))
        #expect(workflow.contains("github.ref == 'refs/heads/main'"))
        #expect(workflow.contains("gh release create"))
        #expect(!workflow.contains("tags: [\"v*\"]"))
        #expect(workflow.contains("GIT_COMMIT=${{ github.sha }}"))
    }
}
