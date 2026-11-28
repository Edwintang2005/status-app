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

        init(id: String, kind: Moment.Kind, caption: String, senderName: String) {
            self.id = id
            self.kind = kind
            self.caption = caption
            self.senderName = senderName
        }

        init(_ moment: Moment, filterEnabled: Bool) {
            self.init(id: moment.id, kind: moment.kind,
                      caption: moment.displayCaption(filterEnabled: filterEnabled) ?? "",
                      senderName: moment.displaySenderName(fallback: "", filterEnabled: filterEnabled))
        }
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
    /// The latest from them isn't opened yet: Favourites shows it first.
    var photoUnseen = false
    /// Starred pictures, for the Favourites setting (`picture(favourites:on:calendar:)`).
    var favourites: [Photo] = []
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
        photo = snapshot.latestPartnerVisualMoment.map { Photo($0, filterEnabled: filterEnabled) }
        // Only with favourites to step aside for: otherwise opening a picture would reload every widget.
        photoUnseen = !snapshot.widgetFavourites.isEmpty && snapshot.latestPartnerVisualMoment.map { !$0.seen } == true
        favourites = snapshot.widgetFavourites.map { Photo($0, filterEnabled: filterEnabled) }
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

    /// The photo widget's picture on `date`: the latest, or with Favourites on, a
    /// starred one a day — after a new picture from them you haven't opened, and
    /// the latest while nothing's starred.
    func picture(favourites: Bool, on date: Date, calendar: Calendar = .current) -> Photo? {
        guard favourites, !photoUnseen,
              let index = WidgetFavourites.pick(count: self.favourites.count, on: date, calendar: calendar)
        else { return photo }
        return self.favourites[index]
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

/// The photo widget's Favourites: which pictures, and which one today.
enum WidgetFavourites {
    /// Enough for months of different days, small enough for every widget reload.
    static let limit = 100

    /// Starred photos and drawings from either side, oldest star first; none
    /// this phone took off the widget.
    static func derive(from all: [Moment], hidden: [String]) -> [Moment] {
        let hidden = Set(hidden)
        let starred = all.filter { $0.isPicture && $0.isFavourite && !hidden.contains($0.id) }
            .sorted { ($0.favouritedAt ?? .distantPast, $0.id) < ($1.favouritedAt ?? .distantPast, $1.id) }
        return Array(starred.suffix(limit))
    }

    /// Today's index into `count` favourites: every one shown once before any
    /// repeats, in an order seeded by the cycle, and never the same two days running.
    static func pick(count: Int, on date: Date, calendar: Calendar) -> Int? {
        guard count > 0 else { return nil }
        let day = calendar.dateComponents([.day], from: Date(timeIntervalSince1970: 0),
                                          to: calendar.startOfDay(for: date)).day ?? 0
        guard count > 2 else { return day.floorModulo(count) }
        let cycle = day.floorDivided(by: count)
        var order = shuffled(count, seed: cycle)
        // A cycle never opens on the picture the last one ended on (its last place
        // is past the swap, so this needs no look further back).
        if order[0] == shuffled(count, seed: cycle - 1)[count - 1] { order.swapAt(0, 1) }
        return order[day - cycle * count]
    }

    private static func shuffled(_ count: Int, seed: Int) -> [Int] {
        var generator = SeededGenerator(seed: UInt64(bitPattern: Int64(seed)))
        return Array(0..<count).shuffled(using: &generator)
    }
}

private extension Int {
    /// Floor division and its remainder, so days before 1970 land in a cycle too.
    func floorDivided(by divisor: Int) -> Int { (self >= 0 ? self : self - divisor + 1) / divisor }
    func floorModulo(_ divisor: Int) -> Int { self - floorDivided(by: divisor) * divisor }
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
