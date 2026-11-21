import Foundation
import NIOConcurrencyHelpers

/// Work the response does not wait for (the „Passwort vergessen“ and „Neues Gerät“ mails). Tests wait for it with `drain()`.
final class BackgroundTasks: Sendable {
    /// The tasks still running, keyed by a random ID; each removes itself when done.
    private let running = NIOLockedValueBox<[UUID: Task<Void, Never>]>([:])

    /// Starts `operation` in a new unstructured task that the caller does not await.
    /// - Parameter operation: The work to run.
    func run(_ operation: @escaping @Sendable () async -> Void) {
        let id = UUID()
        running.withLockedValue { tasks in
            tasks[id] = Task { [running] in
                await operation()
                running.withLockedValue { _ = $0.removeValue(forKey: id) }
            }
        }
    }

    /// Waits until every started task (including ones started meanwhile) has finished.
    func drain() async {
        while let tasks = running.withLockedValue({ $0.isEmpty ? nil : Array($0.values) }) {
            for task in tasks { await task.value }
        }
    }
}
