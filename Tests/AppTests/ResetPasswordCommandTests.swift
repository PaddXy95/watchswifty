@testable import App
import ConsoleKit
import Testing
import VaporTesting

/// Console that answers prompts from a script and records what was printed.
final class ScriptedConsole: Console, @unchecked Sendable {
    private var answers: [String]
    private(set) var secureReads = 0
    private(set) var printed = ""
    var userInfo: [AnySendableHashable: any Sendable] = [:]
    var size: (width: Int, height: Int) { (80, 24) }

    init(answers: [String]) { self.answers = answers }

    func input(isSecure: Bool) -> String {
        if isSecure { secureReads += 1 }
        return answers.isEmpty ? "" : answers.removeFirst()
    }

    func output(_ text: ConsoleText, newLine: Bool) { printed += text.description + (newLine ? "\n" : "") }
    func clear(_ type: ConsoleClear) {}
    func report(error: String, newLine: Bool) { printed += error + (newLine ? "\n" : "") }
}

@Suite("ResetPasswordCommand")
struct ResetPasswordCommandTests {
    /// Runs `App reset-password <arguments>` through the app's registered commands.
    private func run(_ app: Application, _ arguments: [String], answers: [String]) async throws -> ScriptedConsole {
        let console = ScriptedConsole(answers: answers)
        var context = CommandContext(console: console, input: CommandInput(arguments: ["App", "reset-password"] + arguments))
        context.application = app
        try await app.asyncCommands.group().run(using: &context)
        return console
    }

    @Test func setsNewPasswordAskedTwiceHidden() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            let console = try await run(app, ["pat"], answers: ["newpassword1", "newpassword1"])
            #expect(console.secureReads == 2)
            #expect(console.printed.contains("Passwort für pat geändert."))
            _ = try await login(app, "pat", password: "newpassword1")
        }
    }

    @Test func usernameIsNormalized() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            _ = try await run(app, ["  PAT "], answers: ["newpassword1", "newpassword1"])
            _ = try await login(app, "pat", password: "newpassword1")
        }
    }

    @Test func unknownUserFails() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            await #expect(throws: CommandFailure(#"Benutzer „max“ gibt es nicht."#)) {
                _ = try await run(app, ["max"], answers: ["newpassword1", "newpassword1"])
            }
        }
    }

    @Test func mismatchedConfirmationKeepsOldPassword() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            await #expect(throws: CommandFailure("Die Passwörter stimmen nicht überein – nichts geändert.")) {
                _ = try await run(app, ["pat"], answers: ["newpassword1", "newpassword2"])
            }
            _ = try await login(app, "pat")
        }
    }

    @Test func tooShortPasswordKeepsOldPassword() async throws {
        try await withTestApp { app in
            try await createUser(app, "pat")
            await #expect(throws: CommandFailure("Passwort muss mindestens 8 Zeichen haben.")) {
                _ = try await run(app, ["pat"], answers: ["short", "short"])
            }
            _ = try await login(app, "pat")
        }
    }
}

@Suite("BackgroundJobsOnlyWhenServing")
struct BackgroundJobsOnlyWhenServingTests {
    @Test func serveAndDefaultCommandRunJobs() {
        #expect(servesHTTP(arguments: ["App"]))
        #expect(servesHTTP(arguments: ["App", "serve"]))
        #expect(servesHTTP(arguments: ["App", "serve", "--port", "8080"]))
        #expect(servesHTTP(arguments: ["App", "--port", "8080"]))
    }

    @Test func otherCommandsDoNot() {
        #expect(!servesHTTP(arguments: ["App", "reset-password", "pat"]))
        #expect(!servesHTTP(arguments: ["App", "migrate"]))
        #expect(!servesHTTP(arguments: ["App", "routes"]))
    }
}
