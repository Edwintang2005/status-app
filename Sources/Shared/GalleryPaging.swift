import Foundation

/// Where the gallery goes when the page on screen is removed (reported, deleted,
/// cleared): the next page still there, else the one before; none left closes it.
enum GalleryPaging {
    /// - Parameters:
    ///   - selection: the page on screen.
    ///   - order: every page the gallery opened with, in order.
    ///   - remaining: the pages still there.
    /// - Returns: the page to show, `selection` itself while it remains, or `nil` to close.
    static func settle(_ selection: String, order: [String], remaining: [String]) -> String? {
        let still = Set(remaining)
        guard !still.contains(selection) else { return selection }
        let gone = order.firstIndex(of: selection) ?? 0
        return order[gone...].first(where: still.contains) ?? order[..<gone].last(where: still.contains)
    }
}
