import Foundation

/// What a tap on a picture — the photo widget, a banner — opens in Home's carousel.
enum CarouselPlan {
    /// - Parameters:
    ///   - found: the picture tapped, if this phone has it filed.
    ///   - unseen: the partner's unseen pictures, in carousel order.
    ///   - arrivals: what "new moments" opens (`AppModel.carouselMoments`).
    /// - Returns: where it starts (`nil`: the first) and what it pages through.
    ///   The tapped picture among the unseen pages through them all; seen, it opens
    ///   alone; not filed (an unreadable index), the new arrivals stand in.
    static func opening(_ found: Moment?, unseen: [Moment], arrivals: [Moment]) -> (start: Moment?, queue: [Moment]) {
        guard let found else { return (nil, arrivals) }
        return (found, unseen.contains { $0.id == found.id } ? unseen : [found])
    }
}
