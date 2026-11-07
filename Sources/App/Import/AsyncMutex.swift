/// FIFO async mutex. Callers pair `lock()` / `unlock()` (also on error paths).
actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Runs `body` while holding the lock (released on success and on error).
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

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
