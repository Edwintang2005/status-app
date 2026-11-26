import CoreGraphics
import Foundation

/// Exactly what the widgets draw, moderated once when the timeline entry is
/// built (invariant 20): a view reads its properties many times per render, and
/// each read of the store is a file read and a decode. Nothing a widget doesn't
/// draw belongs here: `SharedStore.mutate` reloads the widgets when this moves
/// (invariant 6), so an extra field costs reloads and a missing one, a stale tile.
struct WidgetContent: Hashable {
    /// A status as a tile draws it.
    struct Status: Hashable {
        var emoji: String
        var message: String
    }

    /// The photo widget's picture: which file, and the words drawn over it.
    struct Photo: Hashable {
        var id: String
        var kind: Moment.Kind
        var caption: String
        var senderName: String

        var noun: String { kind.noun }
    }

    var isPaired: Bool
    /// The store can't be read yet (before first unlock): neither paired nor unlinked.
    var isLocked = false
    var mine: Status?
    /// Reported → no words; a message the filter hides → a stand-in that fits a tile.
    var partner: Status?
    /// Only once they've published one — "Partner" reads cold as a heading.
    var partnerName: String?
    /// The latest photo or doodle; a caption or name the filter hides is empty.
    var photo: Photo?
    var unheardMemos: Int
    var lastNudgeSentAt: Date?
    var lastNudgeFailedAt: Date?
    var lastNudgeIssuedAt: Date?
    /// The countdown widget's date.
    var anniversary: Anniversary?

    init(snapshot: Snapshot, reportedAt: Date?, filterEnabled: Bool) {
        isPaired = snapshot.isPaired
        mine = snapshot.mine.map { Status(emoji: $0.emoji, message: $0.message) }
        let theirs = snapshot.theirs?.moderated(reportedAt: reportedAt,
                                                sealed: snapshot.partnerStatusSealed,
                                                filteredText: String(localized: "Hidden"),
                                                filterEnabled: filterEnabled)
        partner = theirs.map { Status(emoji: $0.emoji, message: $0.message) }
        let name = theirs.map { ContentFilter.displayName($0.displayName, fallback: "", enabled: filterEnabled) }
        partnerName = name?.isEmpty == false ? name : nil
        photo = snapshot.latestPartnerVisualMoment.map { moment in
            Photo(id: moment.id, kind: moment.kind,
                  caption: moment.displayCaption(filterEnabled: filterEnabled) ?? "",
                  senderName: moment.displaySenderName(fallback: "", filterEnabled: filterEnabled))
        }
        unheardMemos = snapshot.unheardVoiceMemoCount
        lastNudgeSentAt = snapshot.lastNudgeSentAt
        lastNudgeFailedAt = snapshot.lastNudgeFailedAt
        lastNudgeIssuedAt = snapshot.lastNudgeIssuedAt
        anniversary = snapshot.anniversary
    }

    /// What `mutate` compares, before and after. The word filter is left out:
    /// it only ever hides what's here, and its switch reloads on its own. A
    /// report isn't — re-picking the reported words lifts it by date alone.
    init(drawing snapshot: Snapshot, reportedAt: Date? = nil) {
        self.init(snapshot: snapshot, reportedAt: reportedAt, filterEnabled: false)
    }

    /// What the store holds now; locked, the empty snapshot's look is never the unlinked one.
    init(store: SharedStore) {
        self.init(snapshot: store.snapshot, reportedAt: store.hiddenPartnerStatusAt,
                  filterEnabled: store.contentFilterEnabled)
        isLocked = store.isLockedOut
        if isLocked { isPaired = false }
    }

    /// The gallery's sample: our own fixed text, so no store read and no filter.
    private init(sample snapshot: Snapshot) {
        self.init(drawing: snapshot)
    }

    static let preview = WidgetContent(sample: .preview)
    static let previewWaiting = WidgetContent(sample: .previewWaiting)
}

/// Which picture the photo widget shows: the partner's newest one this phone
/// hasn't hidden from it. A hide lasts until a newer picture arrives — only the
/// run of hidden ones above the shown picture keeps its marks. Local only.
enum WidgetPicture {
    /// `pictures`: the partner's photos and drawings, newest first.
    static func choose(_ pictures: [Moment], hidden: [String]) -> (shown: Moment?, stillHidden: [String]) {
        let marks = Set(hidden)
        let run = pictures.prefix { marks.contains($0.id) }
        return (pictures.dropFirst(run.count).first, run.map(\.id))
    }
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
