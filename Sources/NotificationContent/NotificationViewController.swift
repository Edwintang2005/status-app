import AVFoundation
import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

/// A moment or status banner, expanded (long-press). The one thing of ours iOS
/// runs when someone looks — nothing runs at unlock — so it refreshes first: a
/// banner a locked phone could only word from plaintext shows the real words
/// and picture here, and `BannerUpkeep` rewords it for later.
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let model = ExpandedBanner()
    private var host: UIHostingController<ExpandedBannerView>?
    /// Our own rewrite of the open banner calls `didReceive` again: one refresh per look.
    private var refreshedRequest: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        model.open = { [weak self] in self?.extensionContext?.performNotificationDefaultAction() }
        // After SwiftUI has drawn the change, so the measure sees it.
        model.changed = { [weak self] in Task { @MainActor in self?.resize() } }
        let host = UIHostingController(rootView: ExpandedBannerView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        self.host = host
    }

    /// Measured at the banner's width: left to itself, the square photo has no
    /// width to be square to and the banner collapses to a strip.
    private func resize() {
        guard let host else { return }
        let width = view.bounds.width
        let fitted = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        preferredContentSize = CGSize(width: width, height: ceil(fitted.height))
    }

    func didReceive(_ notification: UNNotification) {
        // Subject only: a status-category banner without one is about our own
        // status ("Your status was sent…"), never theirs.
        let content = notification.request.content
        model.show(subject: BannerSubject(userInfo: content.userInfo), title: content.title, body: content.body)
        guard refreshedRequest != notification.request.identifier else { return }
        refreshedRequest = notification.request.identifier
        Task { await model.refresh() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.stopPlaying()
    }
}

/// What the expanded banner shows, re-read after its refresh.
@MainActor
@Observable
final class ExpandedBanner {
    enum Shown {
        case moment(Moment, image: UIImage?)
        case status(name: String, emoji: String, body: String)
        /// Nothing readable yet (or gone): the banner's own words.
        case words(title: String, body: String, note: String?)
    }

    private(set) var shown: Shown = .words(title: "", body: "", note: nil)
    private(set) var isPlaying = false
    @ObservationIgnored var open: () -> Void = {}
    @ObservationIgnored var changed: () -> Void = {}
    @ObservationIgnored private var subject: BannerSubject?
    @ObservationIgnored private var title = ""
    @ObservationIgnored private var body = ""
    @ObservationIgnored private var player: AVAudioPlayer?

    func show(subject: BannerSubject?, title: String, body: String) {
        self.subject = subject
        self.title = title
        self.body = body
        reload(final: false)
    }

    /// Bounded like the widget's: the person is looking now. Tidies up first
    /// as well — the view may close, and the process go, before the fetch ends.
    func refresh() async {
        guard SharedStore.shared.pairing != nil else { return reload(final: true) }
        try? await withDeadline(3) { await BannerUpkeep.run() }
        // One widget reload for the pass, which fetches again unless this one got everything.
        let hold = SharedStore.shared.holdWidgetReloads()
        let result = try? await withDeadline(AppConfig.widgetDeadline) { try await CloudSync.shared.refresh() }
        hold.release(widgetNeedsFetch: result?.incomplete ?? true)
        reload(final: false)
        if case .moment(let moment, _) = shown, !Self.hasMedia(moment) {
            try? await withDeadline(AppConfig.widgetDeadline) { try await CloudSync.shared.fetchAttachment(for: moment) }
        }
        reload(final: true)
        try? await withDeadline(3) { await BannerUpkeep.run() }
    }

    private func reload(final: Bool) {
        let store = SharedStore.shared
        let snapshot = store.snapshot
        let waiting = final ? String(localized: "Open \(AppConfig.appName) to see it.") : nil
        switch subject {
        case .moment(let id)?:
            if store.hiddenMomentIDs.contains(id) {
                shown = .words(title: title, body: String(localized: "You reported this moment."), note: nil)
            } else if let moment = MomentIndex.shared.load().first(where: { $0.id == id }) {
                shown = .moment(moment, image: moment.isVoice ? nil : Self.image(for: moment))
            } else {
                shown = .words(title: title, body: body, note: waiting)
            }
        case .status?:
            let held = store.pairing.map { store.unreadableTally.heldNames.contains($0.role.other.statusRecordName) } ?? true
            if let status = snapshot.theirs, !held {
                let shownStatus = status.moderated(reportedAt: store.hiddenPartnerStatusAt)
                shown = .status(name: snapshot.moderatedPartnerName,
                                emoji: snapshot.partnerStatusSealed ? "🎁" : shownStatus.emoji,
                                body: PushBannerPolicy.statusBody(status, reportedAt: store.hiddenPartnerStatusAt,
                                                                  sealed: snapshot.partnerStatusSealed))
            } else {
                shown = .words(title: title, body: body, note: waiting)
            }
        case .hearts?, nil:
            shown = .words(title: title, body: body, note: nil)
        }
        changed()
    }

    private static func hasMedia(_ moment: Moment) -> Bool {
        moment.isVoice ? MomentStore.shared.hasAudio(for: moment.id) : MomentStore.shared.hasThumbnail(for: moment.id)
    }

    private static func image(for moment: Moment) -> UIImage? {
        MomentStore.shared.image(for: moment.id) ?? MomentStore.shared.thumbnail(for: moment.id)
    }

    // MARK: - Voice memos

    func togglePlayback(_ moment: Moment) {
        if isPlaying { return stopPlaying() }
        guard let url = MomentStore.shared.audioURL(for: moment.id),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        self.player = player
        isPlaying = player.play()
        Task { [weak self] in
            while self?.player?.isPlaying == true { try? await Task.sleep(for: .milliseconds(250)) }
            self?.isPlaying = false
        }
    }

    func stopPlaying() {
        player?.stop()
        player = nil
        isPlaying = false
    }
}

struct ExpandedBannerView: View {
    let model: ExpandedBanner

    var body: some View {
        Group {
            switch model.shown {
            case let .moment(moment, image):
                momentView(moment, image: image)
            case let .status(name, emoji, body):
                VStack(spacing: 8) {
                    Text(emoji).font(.system(size: 56)).accessibilityHidden(true)
                    Text(name).font(.headline)
                    Text(body).font(.body).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            case let .words(title, body, note):
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(body).font(.body)
                    if let note {
                        Text(note).font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func momentView(_ moment: Moment, image: UIImage?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if moment.isVoice {
                Button {
                    model.togglePlayback(moment)
                } label: {
                    Label(model.isPlaying ? "Pause" : "Play · \(moment.durationLabel)",
                          systemImage: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.bordered)
                .disabled(!MomentStore.shared.hasAudio(for: moment.id))
            } else if !moment.kind.isSupported {
                Text("Update \(AppConfig.appName) to see this.").font(.body)
            } else if let image {
                // The centred square, as every tile shows; tapping opens it in the app.
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { Image(uiImage: image).resizable().scaledToFill() }
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .contentShape(Rectangle())
                    .onTapGesture { model.open() }
                    .accessibilityLabel(moment.kind == .drawing ? "Drawing" : "Photo")
                    .accessibilityAddTraits(.isButton)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(moment.displaySenderName(fallback: SharedStore.shared.snapshot.moderatedPartnerName))
                    .font(.headline)
                Text(moment.displayCaption ?? moment.arrivalSummary).font(.body)
            }
        }
        .padding(12)
    }
}
