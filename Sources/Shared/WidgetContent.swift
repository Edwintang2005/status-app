import CoreGraphics
import Foundation

/// What the widgets draw, moderated once when the timeline entry is built
/// (invariant 20): a view reads its properties many times per render, and each
/// read of the store is a file read and a decode.
struct WidgetContent: Hashable {
    var isPaired: Bool
    var mine: StatusPayload?
    /// Reported → no words; a message the filter hides → a stand-in that fits a tile.
    var partner: StatusPayload?
    /// Only once they've published one — "Partner" reads cold as a heading.
    var partnerName: String?
    /// The latest photo or doodle; a caption or name the filter hides is empty.
    var photo: Moment?
    var unheardMemos: Int
    var lastNudgeSentAt: Date?
    var lastNudgeFailedAt: Date?

    init(snapshot: Snapshot, reportedAt: Date?, filterEnabled: Bool) {
        isPaired = snapshot.isPaired
        mine = snapshot.mine
        partner = snapshot.theirs?.moderated(reportedAt: reportedAt,
                                             filteredText: String(localized: "Hidden"),
                                             filterEnabled: filterEnabled)
        let name = partner.map { ContentFilter.displayName($0.displayName, fallback: "", enabled: filterEnabled) }
        partnerName = name?.isEmpty == false ? name : nil
        photo = snapshot.latestPartnerVisualMoment.map { moment in
            var shown = moment
            shown.caption = moment.displayCaption ?? ""
            shown.senderName = moment.displaySenderName(fallback: "")
            return shown
        }
        unheardMemos = snapshot.unheardVoiceMemoCount
        lastNudgeSentAt = snapshot.lastNudgeSentAt
        lastNudgeFailedAt = snapshot.lastNudgeFailedAt
    }

    /// The gallery's sample: our own fixed text, so no store read and no filter.
    private init(sample snapshot: Snapshot) {
        isPaired = snapshot.isPaired
        mine = snapshot.mine
        partner = snapshot.theirs
        partnerName = snapshot.theirs?.displayName
        photo = snapshot.latestPartnerVisualMoment
        unheardMemos = snapshot.unheardVoiceMemoCount
        lastNudgeSentAt = snapshot.lastNudgeSentAt
        lastNudgeFailedAt = snapshot.lastNudgeFailedAt
    }

    static let preview = WidgetContent(sample: .preview)
    static let previewWaiting = WidgetContent(sample: .previewWaiting)
}

/// How large to decode the photo widget's picture: enough to fill the tile at
/// its pixel size (`scaledToFill`), never more than the file holds or twice the
/// tile's long side — an extreme aspect would otherwise decode past the
/// extension's memory ceiling for pixels the crop throws away.
enum WidgetPhotoSize {
    static func maxPixel(image: CGSize, filling target: CGSize) -> CGFloat? {
        guard image.width > 0, image.height > 0, target.width > 0, target.height > 0 else { return nil }
        let scale = min(1, max(target.width / image.width, target.height / image.height))
        let longSide = (max(image.width, image.height) * scale).rounded(.up)
        return min(longSide, 2 * max(target.width, target.height))
    }
}
