extension Array {
    /// Slices of at most `size` elements. IN lists built from stored data go through this so a statement never
    /// grows past SQLite's bind limit (250,000 in the bundled build), which would fail the whole pass for every
    /// user (security audit F04/F15).
    func chunked(_ size: Int = 500) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
