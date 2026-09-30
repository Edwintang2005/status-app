import Foundation

/// Which media each process pulls down after a refresh: newly filed moments,
/// plus the index's newest for the app. Pure so the split is tested; `CloudSync.prefetchMedia` runs it
/// after the change token is persisted — no record depends on an asset, so
/// a kill mid-download loses nothing.
enum MediaPrefetchPlan {
    enum Process: Equatable {
        case app
        case widget
        case notificationService
    }

    /// `.full` is the photo with its thumbnail, or a memo's recording.
    enum Fetch: Equatable {
        case thumbnail
        case full
    }

    struct Item: Equatable {
        var moment: Moment
        var fetch: Fetch
    }

    /// The app keeps the newest few whole, so a reinstall doesn't pull the
    /// whole history at once; the widget only ever draws the newest photo.
    static let appLimit = 10
    static let widgetLimit = 3

    /// Newest first. `recent` is the index's newest (the app passes it): the
    /// notification service usually files a push's moments first, and the app's
    /// own refresh then sees nothing arrive. The notification service takes only
    /// the widget's picture — a backlog of full photos held its banner and the
    /// token past the 30 s window, and after a photo-then-memo burst the banner
    /// attaches the memo, leaving the photo's thumbnail to nobody.
    static func items(for arrived: [Moment],
                      recent: [Moment] = [],
                      in process: Process,
                      hasMedia: (Moment) -> Bool,
                      hasThumbnail: (Moment) -> Bool) -> [Item] {
        var seen = Set<String>()
        let newestFirst = (arrived + recent).filter { seen.insert($0.id).inserted }
            .sorted { $0.sentAt > $1.sentAt }
        // What the widget draws (`latestPartnerVisualMoment`).
        let partnerVisual = newestFirst.filter { !$0.fromMe && !$0.isVoice }
        switch process {
        case .app:
            return newestFirst.prefix(appLimit)
                .filter { !hasMedia($0) }
                .map { Item(moment: $0, fetch: .full) }
        case .widget:
            return partnerVisual.prefix(widgetLimit)
                .filter { !hasThumbnail($0) }
                .map { Item(moment: $0, fetch: .thumbnail) }
        case .notificationService:
            return partnerVisual.prefix(1)
                .filter { !hasThumbnail($0) }
                .map { Item(moment: $0, fetch: .thumbnail) }
        }
    }

    /// What one banner attaches (`MomentStore.temporaryAttachmentCopy`): the
    /// thumbnail for a photo or doodle, the recording for a memo.
    static func attachment(for moment: Moment) -> Fetch {
        moment.isVoice ? .full : .thumbnail
    }
}
