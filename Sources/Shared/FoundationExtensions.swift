import Foundation

extension Date {
    /// Truncated to the second: App Group JSON stores ISO-8601, which drops
    /// fractions, so only a whole-second date equals its own stored copy (invariant 14).
    var wholeSeconds: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }

    /// Seconds since 1970, or `nil` for a date no `Int` holds.
    var wholeSecondsSince1970: Int? {
        Int(exactly: timeIntervalSince1970.rounded(.down))
    }
}

extension Array {
    /// Consecutive slices of at most `size` elements — CloudKit caps a batch.
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
