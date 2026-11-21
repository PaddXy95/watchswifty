/// FIFO async mutex. Callers pair `lock()` / `unlock()` (also on error paths).
actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Acquires the lock, suspending until earlier waiters have had their turn.
    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Runs `body` while holding the lock (released on success and on error).
    ///
    /// - Parameter body: The work to run under the lock.
    /// - Returns: The value returned by `body`.
    /// - Throws: Whatever `body` throws.
    nonisolated func withLock<T>(_ body: () async throws -> T) async throws -> T {
        await lock()
        do {
            let result = try await body()
            await unlock()
            return result
        } catch {
            await unlock()
            throw error
        }
    }

    /// Releases the lock, handing it directly to the longest-waiting caller if there is one.
    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
